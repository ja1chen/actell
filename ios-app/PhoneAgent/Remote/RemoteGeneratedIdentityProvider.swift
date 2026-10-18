import Foundation
import CryptoKit
import Network
import Security
import X509

/// An app-owned, persistent local TLS identity. No PKCS#12, bundled key, CA service,
/// custom signature implementation, or trust-all callback is involved.
/// Serialize calls on the app actor; never silently replace a paired certificate.
@MainActor final class RemoteGeneratedIdentityProvider {
    struct Material {
        let identity: SecIdentity
        let certificateDER: Data
        let fingerprint: String
        let expiresAt: Date
    }
    private let label: String
    private let keyTag: Data

    /// Tests use a random namespace. Production may include a persisted installation UUID.
    init(namespace: String = "actell.muse.generated-tls.v1") {
        label = namespace + ".certificate"
        keyTag = Data((namespace + ".private-key").utf8)
    }

    func provision(host: String) throws -> Material {
        let host = try Self.validatedHost(host)
        if let material = try load(host: host) { return material }
        // A previous interrupted write may have saved just the private key. Reuse it.
        let key = try loadOrCreateKey()
        // Swift Certificates signs through SecKey; private bytes never leave Keychain APIs.
        let signingKey = try Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("Actell Muse") }
        var serial = [UInt8](repeating: 0, count: 20)
        let randomStatus = serial.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw failure("generate_serial", randomStatus) }
        serial[0] = (serial[0] & 0x7f) | 0x01
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: .init(bytes: serial),
            publicKey: signingKey.publicKey,
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(365 * 24 * 60 * 60),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([Self.subjectAlternativeName(host)])
            }, issuerPrivateKey: signingKey
        )
        let secCertificate = try SecCertificate.makeWithCertificate(certificate)
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCertificate,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ] as NSDictionary, nil)
        guard status == errSecSuccess else { throw failure("save_certificate", status) }
        guard let result = try load(host: host) else {
            throw RemoteSetupError(String(localized: "The connection identity could not be saved completely. Try again. Existing pairing certificates remain unchanged."))
        }
        return result
    }

    /// nil means no certificate yet. A broken, expired, or wrong-host identity fails closed.
    func load(host: String) throws -> Material? {
        let host = try Self.validatedHost(host)
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate, kSecAttrLabel: label,
            kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ] as NSDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecCertificateGetTypeID() else {
            throw failure("read_certificate", status)
        }
        let certificate = item as! SecCertificate
        var identityItem: CFTypeRef?
        // Identity lookup uses certificate attributes, not the key-only application tag.
        let identityStatus = SecItemCopyMatching([
            kSecClass: kSecClassIdentity, kSecAttrLabel: label,
            kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ] as NSDictionary, &identityItem)
        guard identityStatus == errSecSuccess, let identityItem,
              CFGetTypeID(identityItem) == SecIdentityGetTypeID() else {
            throw failure("read_identity", identityStatus)
        }
        let identity = identityItem as! SecIdentity
        let der = SecCertificateCopyData(certificate) as Data
        var identityCertificate: SecCertificate?
        var privateKey: SecKey?
        guard SecIdentityCopyCertificate(identity, &identityCertificate) == errSecSuccess,
              let identityCertificate, (SecCertificateCopyData(identityCertificate) as Data) == der,
              SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, privateKey != nil,
              let expires = SecCertificateCopyNotValidAfterDate(certificate) else {
            throw RemoteSetupError(String(localized: "The connection certificate does not match its key. Reset the connection and pair again."))
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            throw RemoteSetupError(String(localized: "The connection certificate has expired or does not match. Reset the connection and pair again."))
        }
        return Material(identity: identity, certificateDER: der,
                        fingerprint: SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined(),
                        expiresAt: expires as Date)
    }

    private func loadOrCreateKey() throws -> SecKey {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ] as NSDictionary, &item)
        if status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() { return item as! SecKey }
        guard status == errSecItemNotFound else { throw failure("read_key", status) }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseDataProtectionKeychain: true,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true, kSecAttrApplicationTag: keyTag,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ],
        ] as NSDictionary, &error) else {
            throw RemoteSetupError(String(localized: "Connection credentials could not be created. Unlock the phone and try again."))
        }
        return key
    }

    /// Explicit reset only, after the caller invalidates the old pairings.
    func remove() throws {
        let queries: [[CFString: Any]] = [
            [kSecClass: kSecClassCertificate, kSecAttrLabel: label],
            [kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag,
             kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate],
        ]
        for query in queries {
            var scoped = query; scoped[kSecUseDataProtectionKeychain] = true
            let status = SecItemDelete(scoped as NSDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("remove_identity", status) }
        }
    }

    private static func validatedHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return host }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
                  !part.isEmpty && part.utf8.count <= 63 && part.first != "-" && part.last != "-" &&
                  part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw RemoteSetupError(String(localized: "Enter a valid DNS name or IP address for the connection.")) }
        return host
    }
    private static func subjectAlternativeName(_ host: String) -> GeneralName {
        if let ip = IPv4Address(host) { return .ipAddress(.init(contentBytes: Array(ip.rawValue)[...])) }
        if let ip = IPv6Address(host) { return .ipAddress(.init(contentBytes: Array(ip.rawValue)[...])) }
        return .dnsName(host)
    }
    private func failure(_ action: String, _ status: OSStatus) -> RemoteSetupError {
        RemoteSetupError(String(localized: "Connection credentials are unavailable. Unlock the phone and try again."),
                         underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
    }
}
