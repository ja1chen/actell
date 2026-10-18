import XCTest
import CryptoKit
import Security
import X509
@testable import PhoneAgent

@MainActor final class RemoteGeneratedIdentityProviderTests: XCTestCase {
    func testIdentityPersistsWithMatchingCertificateAndSigningKey() throws {
        let namespace = "actell.tests.generated-tls." + UUID().uuidString
        let provider = RemoteGeneratedIdentityProvider(namespace: namespace)
        defer { try? provider.remove() }
        XCTAssertNil(try provider.load(host: "actell-test.local"))
        let first = try provider.provision(host: "actell-test.local")
        let second = try RemoteGeneratedIdentityProvider(namespace: namespace).provision(host: "actell-test.local")
        XCTAssertEqual(first.certificateDER, second.certificateDER)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint.count, 64)
        XCTAssertGreaterThan(first.expiresAt, Date())
        XCTAssertNotNil(sec_identity_create(second.identity))
        let parsed = try Certificate(derEncoded: Array(first.certificateDER))
        XCTAssertTrue(parsed.publicKey.isValidSignature(parsed.signature, for: parsed))
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(first.identity, &key), errSecSuccess)
        let privateKey = try XCTUnwrap(key)
        var error: Unmanaged<CFError>?
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256,
                                                           Data("synthetic TLS proof".utf8) as CFData, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256,
                                            Data("synthetic TLS proof".utf8) as CFData, signature, &error))
    }
    func testHostChangeDoesNotSilentlyRotatePairedIdentity() throws {
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.tests.generated-tls." + UUID().uuidString)
        defer { try? provider.remove() }
        let first = try provider.provision(host: "actell-one.local")
        XCTAssertThrowsError(try provider.provision(host: "actell-two.local"))
        XCTAssertEqual(try provider.load(host: "actell-one.local")?.fingerprint, first.fingerprint)
    }
    func testSeparateInstallationsHaveDifferentKeysAndFingerprints() throws {
        let first = RemoteGeneratedIdentityProvider(namespace: "actell.tests.generated-tls." + UUID().uuidString)
        let second = RemoteGeneratedIdentityProvider(namespace: "actell.tests.generated-tls." + UUID().uuidString)
        defer { try? first.remove(); try? second.remove() }
        XCTAssertNotEqual(try first.provision(host: "actell-test.local").fingerprint,
                          try second.provision(host: "actell-test.local").fingerprint)
    }
    func testIPAddressUsesIPSubjectAlternativeName() throws {
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.tests.generated-tls." + UUID().uuidString)
        defer { try? provider.remove() }
        _ = try provider.provision(host: "192.0.2.1")
        XCTAssertNotNil(try provider.load(host: "192.0.2.1"))
        XCTAssertThrowsError(try provider.load(host: "192.0.2.2"))
    }
    func testMissingPrivateKeyDoesNotReplaceStoredCertificate() throws {
        let namespace = "actell.tests.generated-tls." + UUID().uuidString
        let provider = RemoteGeneratedIdentityProvider(namespace: namespace)
        defer { try? provider.remove() }
        let original = try provider.provision(host: "actell-test.local")
        XCTAssertEqual(SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data((namespace + ".private-key").utf8),
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecUseDataProtectionKeychain: true,
        ] as NSDictionary), errSecSuccess)
        XCTAssertThrowsError(try provider.provision(host: "actell-test.local"))
        var stored: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([
            kSecClass: kSecClassCertificate, kSecAttrLabel: namespace + ".certificate",
            kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ] as NSDictionary, &stored), errSecSuccess)
        let certificate = try XCTUnwrap(stored) as! SecCertificate
        XCTAssertEqual(SecCertificateCopyData(certificate) as Data, original.certificateDER)
    }
    func testInvalidHostIsRejectedBeforeProvisioning() throws {
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.tests.generated-tls." + UUID().uuidString)
        defer { try? provider.remove() }
        for host in ["", "https://actell.local", "*.local", "a..local", "a/b", "-bad.local"] {
            XCTAssertThrowsError(try provider.provision(host: host))
        }
    }
}
