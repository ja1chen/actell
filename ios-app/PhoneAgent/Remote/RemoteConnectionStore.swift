import CryptoKit
import Foundation
import Security

enum RemoteLANPairingState: String, Codable { case pendingAck = "pending_ack", active }

struct RemoteClientRegistration: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var pairedAt: Date
    var scopes: Set<MuseCompanionScope> = []
    var identityConfirmed = false
    var requestedDeviceName: String?
    var bootstrapExpiresAt: Date?
    var lanPairingState: RemoteLANPairingState?
    var lanRequestID: String?

    enum CodingKeys: String, CodingKey { case id, name, pairedAt, scopes, identityConfirmed, requestedDeviceName, bootstrapExpiresAt, lanPairingState, lanRequestID }
    init(id: String, name: String, pairedAt: Date) {
        self.id = id; self.name = name; self.pairedAt = pairedAt
        bootstrapExpiresAt = pairedAt.addingTimeInterval(600)
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        pairedAt = try values.decode(Date.self, forKey: .pairedAt)
        scopes = try values.decodeIfPresent(Set<MuseCompanionScope>.self, forKey: .scopes) ?? []
        identityConfirmed = try values.decodeIfPresent(Bool.self, forKey: .identityConfirmed) ?? false
        requestedDeviceName = try values.decodeIfPresent(String.self, forKey: .requestedDeviceName)
        bootstrapExpiresAt = try values.decodeIfPresent(Date.self, forKey: .bootstrapExpiresAt)
        lanPairingState = try values.decodeIfPresent(RemoteLANPairingState.self, forKey: .lanPairingState)
        lanRequestID = try values.decodeIfPresent(String.self, forKey: .lanRequestID)
        // Old unrestricted credentials require fresh physical enrollment.
        if !identityConfirmed && bootstrapExpiresAt == nil { bootstrapExpiresAt = .distantPast }
    }
}
struct RemoteCertificateSummary: Codable, Equatable {
    let name: String
    let fingerprint: String
    let expiresAt: Date
}
struct RemoteConnectionSettings: Codable, Equatable {
    var host = ""
    var port: UInt16 = 8765
    var sources: [String] = []
    var certificate: RemoteCertificateSummary?
    var clients: [RemoteClientRegistration] = []
    var companionMode: Bool?
    var identityKind: String?
    var generatedHost: String?
    var usesCompanionLAN: Bool { companionMode == true }

    static func validate(host: String, port: String, sources: String) throws -> (String, UInt16, [String]) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = RemoteSourceAddress(literal: host) != nil
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let dns = !labels.isEmpty && host.utf8.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
        guard numeric || dns else { throw RemoteSetupError(String(localized: "Enter the certificate’s IP address or domain, without https:// or a path.")) }
        guard let port = UInt16(port), port != 0 else { throw RemoteSetupError(String(localized: "Use a port from 1 to 65535.")) }
        let values = sources.split { $0.isWhitespace || $0 == "," }.map(String.init)
        guard !values.isEmpty, values.count <= 64 else { throw RemoteSetupError(String(localized: "Enter 1–64 allowed client IP addresses.")) }
        var seen = Set<RemoteSourceAddress>()
        for value in values {
            guard let address = RemoteSourceAddress(literal: value), seen.insert(address).inserted else {
                throw RemoteSetupError(String(localized: "Use distinct IP addresses. Domains, subnets, and wildcards are unsupported."))
            }
        }
        return (host, port, values)
    }
    var endpoint: String { "https://\(host.contains(":") ? "[\(host)]" : host):\(port)" }
}
struct RemoteSetupError: LocalizedError, CustomNSError {
    let message: String
    private let underlying: NSError?
    init(_ message: String, underlying: Error? = nil) {
        self.message = message; self.underlying = underlying as NSError?
    }
    static var errorDomain: String { "com.ja1chen.Actell.MuseSetup" }
    var errorCode: Int { underlying?.code ?? 0 }
    var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return info
    }
    var errorDescription: String? { message }
}

struct RemoteVaultError: LocalizedError, CustomNSError {
    let status: OSStatus
    let operation: String
    static var errorDomain: String { NSOSStatusErrorDomain }
    var errorCode: Int { Int(status) }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
    var errorDescription: String? {
        if status == errSecMissingEntitlement { return String(localized: "This installation cannot access device credentials. Check app signing and try again.") }
        return String(localized: "Device credentials are unavailable. Unlock the phone and try again.")
    }
}

@MainActor protocol RemoteCredentialVault {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func remove(_ account: String) throws
}
@MainActor final class RemoteKeychainVault: RemoteCredentialVault {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.ja1chen.Actell.MuseRemote.v1",
         kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> Data? {
        var query = query(account); query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RemoteVaultError(status: status, operation: "read") }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(account).merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw RemoteVaultError(status: status, operation: "write") }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteVaultError(status: status, operation: "remove") }
    }
}
#if DEBUG
@MainActor final class RemoteMemoryVault: RemoteCredentialVault {
    var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { values[account] }
    func write(_ data: Data, account: String) throws { values[account] = data }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}
#endif

struct RemoteClientInvitation: Identifiable {
    let id = UUID()
    let client: RemoteClientRegistration
    let text: String
}

@MainActor final class RemoteConnectionStore {
    static let identityAccount = "server-identity"
    private let vault: any RemoteCredentialVault
    private let defaults: UserDefaults?
    private let defaultsKey = "actell.muse.connection.v1"
    private let serviceEnabledKey = "actell.muse.service-enabled.v1"
    private(set) var serviceEnabled: Bool
    func setServiceEnabled(_ enabled: Bool) {
        serviceEnabled = enabled
        defaults?.set(enabled, forKey: serviceEnabledKey)
    }
    private(set) var settings: RemoteConnectionSettings
    private(set) var loadError: String?
    private struct LANClient: Codable { var registration: RemoteClientRegistration; let secret: Data }
    private struct LANEnvelope: Codable { let version: Int; let clients: [LANClient] }
    private var lanClients: [String: LANClient] = [:]
    private var lanHealthy = true
    private static let lanAccount = "slan-clients-v1"
    private struct IdentityEnvelope: Codable { let pkcs12: Data; let password: String }
    init(vault: any RemoteCredentialVault, defaults: UserDefaults? = .standard) {
        self.vault = vault; self.defaults = defaults
        serviceEnabled = defaults?.bool(forKey: serviceEnabledKey) ?? false
        if let data = defaults?.data(forKey: defaultsKey) {
            do { settings = try JSONDecoder().decode(RemoteConnectionSettings.self, from: data) }
            catch { settings = .init(); loadError = String(localized: "Muse settings could not be read. Check and save the connection settings again.") }
        } else { settings = .init() }
        loadLANClients()
    }
    private func save(_ next: RemoteConnectionSettings) throws {
        let data = try JSONEncoder().encode(next)
        defaults?.set(data, forKey: defaultsKey); settings = next; loadError = nil
    }
    func configure(host: String, port: String, sources: String) throws {
        let (host, port, sources) = try RemoteConnectionSettings.validate(host: host, port: port, sources: sources)
        var next = settings; next.host = host; next.port = port; next.sources = sources; next.companionMode = false; try save(next)
    }
    private static func unpack(_ data: Data, password: String) throws -> (SecIdentity, [SecCertificate], RemoteCertificateSummary) {
        guard !data.isEmpty, data.count <= 32 * 1024 else { throw RemoteSetupError(String(localized: "Choose a file smaller than 32 KiB containing the server certificate and private key.")) }
        var imported: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess, let items = imported as? [[String: Any]], items.count == 1,
              let value = items.first?[kSecImportItemIdentity as String], CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw RemoteSetupError(String(localized: "Certificate import failed. Check the .p12/.pfx file, password, and private key. The previous certificate was kept."))
        }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, key != nil,
              let begins = SecCertificateCopyNotValidBeforeDate(certificate),
              let expires = SecCertificateCopyNotValidAfterDate(certificate) else { throw RemoteSetupError(String(localized: "The certificate or private key is incomplete.")) }
        guard (begins as Date) <= Date(), (expires as Date) > Date() else { throw RemoteSetupError(String(localized: "The certificate is not yet valid or has expired.")) }
        let importedChain = items[0][kSecImportItemCertChain as String] as? [SecCertificate] ?? []
        let chain = importedChain.isEmpty ? [certificate] : importedChain
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        let summary = RemoteCertificateSummary(name: SecCertificateCopySubjectSummary(certificate) as String? ?? String(localized: "Server Certificate"), fingerprint: fingerprint, expiresAt: expires as Date)
        return (identity, chain, summary)
    }
    private func generatedIdentityProvider() -> RemoteGeneratedIdentityProvider {
        // The persisted random host also isolates this installation's Keychain
        // namespace. A reinstall must not silently reuse another installation's pin.
        RemoteGeneratedIdentityProvider(namespace: "actell.muse.generated-tls.v1." + (settings.generatedHost ?? settings.host))
    }
    func prepareCompanion() throws {
        guard settings.clients.isEmpty || (settings.usesCompanionLAN && settings.identityKind == "generated") else {
            throw RemoteSetupError(String(localized: "Revoke development clients before switching to companion pairing."))
        }
        let host = settings.generatedHost ?? "actell-" + UUID().uuidString.lowercased() + ".local"
        // Persist the stable SAN before provisioning so an interrupted operation
        // recovers the same identity rather than silently replacing an OOB pin.
        var next = settings; next.generatedHost = host; try save(next)
        // Once a public pin has been saved, a lost identity must not silently mint a replacement.
        if settings.certificate != nil { _ = try loadIdentity() }
        let material = try generatedIdentityProvider().provision(host: host)
        next = settings; next.host = host; next.port = 8765; next.sources = []
        next.companionMode = true; next.identityKind = "generated"
        next.certificate = .init(name: String(localized: "Actell Device Identity"), fingerprint: material.fingerprint, expiresAt: material.expiresAt)
        try save(next)
    }
    func importIdentity(data: Data, password: String) throws {
        guard settings.clients.isEmpty else { throw RemoteSetupError(String(localized: "Remove existing devices before replacing the server identity, then pair them again.")) }
        let (_, _, summary) = try Self.unpack(data, password: password)
        // Only the app-owned generic-password entry persists. Security import is memory-only.
        let encoded = try JSONEncoder().encode(IdentityEnvelope(pkcs12: data, password: password))
        try vault.write(encoded, account: Self.identityAccount)
        var next = settings; next.certificate = summary; next.identityKind = "imported"; next.companionMode = false; try save(next)
    }
    func removeIdentity() throws {
        guard settings.clients.isEmpty else { throw RemoteSetupError(String(localized: "Remove all devices before removing the server identity.")) }
        if settings.identityKind == "generated" { try generatedIdentityProvider().remove() }
        else { try vault.remove(Self.identityAccount) }
        var next = settings; next.certificate = nil; next.identityKind = nil; next.companionMode = false; try save(next)
    }
    func loadIdentity() throws -> SecIdentity {
        if settings.identityKind == "generated" {
            guard let material = try generatedIdentityProvider().load(host: settings.host),
                  material.fingerprint == settings.certificate?.fingerprint else {
                throw RemoteSetupError(String(localized: "The connection identity is inconsistent. The service stopped. Check it and pair again."))
            }
            return material.identity
        }
        guard let data = try vault.read(Self.identityAccount) else { throw RemoteSetupError(String(localized: "Import a server certificate first.")) }
        let envelope = try JSONDecoder().decode(IdentityEnvelope.self, from: data)
        let (identity, chain, summary) = try Self.unpack(envelope.pkcs12, password: envelope.password)
        guard settings.certificate?.fingerprint == summary.fingerprint else { throw RemoteSetupError(String(localized: "The certificate record is inconsistent. Import it again.")) }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, settings.host as CFString), &trust) == errSecSuccess, let trust,
              SecTrustSetAnchorCertificates(trust, [chain.last!] as CFArray) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { throw RemoteSetupError(String(localized: "The certificate does not match the address or is unsuitable for this server.")) }
        return identity
    }
    func key(for id: String) -> Data? {
        if let client = settings.clients.first(where: { $0.id == id }), client.lanPairingState != nil {
            guard lanHealthy else { return nil }
            return lanClients[id]?.secret
        }
        guard let client = settings.clients.first(where: { $0.id == id }),
              client.identityConfirmed || (client.bootstrapExpiresAt.map { $0 > Date() } ?? false) else { return nil }
        return try? vault.read("client-" + id)
    }
    /// Metadata only: never re-read credentials to explain a failed lookup.
    func credentialDiagnostic(for id: String) -> String {
        guard lanHealthy else { return "storage_unavailable" }
        guard let client = settings.clients.first(where: { $0.id == id }) else { return "unknown_client" }
        if let phase = client.lanPairingState {
            guard lanClients[id]?.secret.count == 32 else { return "credential_missing" }
            return phase == .pendingAck ? "pending_credential_present" : "active_credential_present"
        }
        if !client.identityConfirmed, client.bootstrapExpiresAt.map({ $0 <= Date() }) != false {
            return "bootstrap_expired"
        }
        return "legacy_credential_unavailable"
    }
    private func secret() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw RemoteSetupError(String(localized: "Client credentials could not be created. Try again.")) }
        return data
    }
    private func invitation(client: RemoteClientRegistration, key: Data) throws -> RemoteClientInvitation {
        let info: [String: Any] = ["v": 1, "kind": "actell-muse-connection", "endpoint": settings.endpoint,
            "client_id": client.id, "secret_base64": key.base64EncodedString(),
            "certificate_sha256": settings.certificate?.fingerprint ?? "",
            "tls_verification_required": true, "pairing_required": true,
            "discovery_service": MuseCompanionProtocol.serviceType,
            "bootstrap_expires_at_ms": Int64((client.bootstrapExpiresAt ?? .distantPast).timeIntervalSince1970 * 1000),
            "certificate_pem": try certificatePEM()]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        return RemoteClientInvitation(client: client, text: String(decoding: data, as: UTF8.self))
    }
    private func certificatePEM() throws -> String {
        guard settings.certificate != nil else { throw RemoteSetupError(String(localized: "Prepare the connection identity first.")) }
        let identity = try loadIdentity()
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw RemoteSetupError(String(localized: "The server certificate could not be read."))
        }
        let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n" + base64 + "\n-----END CERTIFICATE-----\n"
    }
    func recordHello(clientID: String, name: String) throws {
        guard let index = settings.clients.firstIndex(where: { $0.id == clientID }),
              !name.isEmpty, name.count <= MuseCompanionProtocol.maximumDeviceNameLength else {
            throw RemoteSetupError(String(localized: "This pairing request is unavailable. Add the device again."))
        }
        if settings.clients[index].identityConfirmed { return }
        guard settings.clients[index].lanPairingState == nil else { throw RemoteSetupError(String(localized: "Wait for the device to finish pairing.")) }
        guard settings.clients[index].bootstrapExpiresAt.map({ $0 > Date() }) == true else {
            throw RemoteSetupError(String(localized: "Pairing details expired. Revoke them and generate new details."))
        }
        // Freeze the first authenticated request; a remote label cannot silently
        // rename an identity while the user reviews its physical provenance.
        if settings.clients[index].requestedDeviceName != nil { return }
        var next = settings; next.clients[index].requestedDeviceName = name; try save(next)
    }
    static func normalizedDeviceName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= MuseCompanionProtocol.maximumDeviceNameLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteSetupError(String(localized: "Use 1–64 characters for the device name, without line breaks or control characters."))
        }
        return value
    }
    func setAuthorization(clientID: String, scopes: Set<MuseCompanionScope>, identityConfirmed: Bool,
                          name: String? = nil) throws {
        let displayName = try name.map(Self.normalizedDeviceName)
        guard let index = settings.clients.firstIndex(where: { $0.id == clientID }),
              settings.clients[index].requestedDeviceName != nil,
              identityConfirmed || scopes.isEmpty,
              settings.clients[index].identityConfirmed || settings.clients[index].bootstrapExpiresAt.map({ $0 > Date() }) == true else { throw RemoteSetupError(String(localized: "Complete trusted USB setup and wait for the device’s pairing request.")) }
        if settings.clients[index].lanPairingState != nil {
            guard lanHealthy, settings.clients[index].lanPairingState == .active, identityConfirmed,
                  var entry = lanClients[clientID] else { throw RemoteSetupError(String(localized: "Pairing is incomplete. Add the device again.")) }
            entry.registration.scopes = scopes
            if let displayName { entry.registration.name = displayName }
            var clients = lanClients; clients[clientID] = entry
            try persistLAN(clients); try mirrorLAN(); return
        }
        var next = settings
        next.clients[index].identityConfirmed = identityConfirmed
        next.clients[index].scopes = scopes
        if let displayName { next.clients[index].name = displayName }
        if identityConfirmed { next.clients[index].bootstrapExpiresAt = nil }
        try save(next)
    }
    func permits(clientID: String, op: String, params: [String: Any]) -> Bool {
        guard let client = settings.clients.first(where: { $0.id == clientID }), client.identityConfirmed,
              client.lanPairingState == nil || (lanHealthy && client.lanPairingState == .active && lanClients[clientID] != nil) else { return false }
        return MuseCompanionAuthorization.permits(op: op, params: params, scopes: client.scopes)
    }
    func addClient(name: String) throws -> RemoteClientInvitation {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { throw RemoteSetupError(String(localized: "Use 1–64 characters for the client name.")) }
        guard settings.clients.count < 16 else { throw RemoteSetupError(String(localized: "Up to 16 clients can be saved. Revoke unused clients first.")) }
        guard !settings.host.isEmpty, (settings.usesCompanionLAN || !settings.sources.isEmpty) else { throw RemoteSetupError(String(localized: "Save the connection address and allowed sources first.")) }
        let client = RemoteClientRegistration(id: UUID().uuidString.lowercased(), name: name, pairedAt: Date())
        let key = try secret(); let invite = try invitation(client: client, key: key)
        try vault.write(key, account: "client-" + client.id)
        var next = settings; next.clients.append(client)
        do { try save(next) } catch { try? vault.remove("client-" + client.id); throw error }
        return invite
    }
    func revokeClient(_ id: String, cancel: (String) -> Void) throws {
        // SLAN secrets and state share one atomic Keychain item. Legacy keys retain their namespace.
        if lanClients[id] != nil {
            var clients = lanClients; clients.removeValue(forKey: id)
            try persistLAN(clients)
        } else { try vault.remove("client-" + id) }
        cancel(id)
        var next = settings; next.clients.removeAll { $0.id == id }; try save(next)
    }
    /// The Keychain envelope is authoritative for SLAN, including scopes and active state.
    /// UserDefaults is only a display cache; it can never resurrect an absent SLAN key.
    private func loadLANClients() {
        do {
            if let data = try vault.read(Self.lanAccount) {
                let envelope = try JSONDecoder().decode(LANEnvelope.self, from: data)
                guard envelope.version == 1, envelope.clients.count <= 16 else { throw RemoteSetupError(String(localized: "The device record could not be read.")) }
                var loaded: [String: LANClient] = [:]
                for entry in envelope.clients {
                    let c = entry.registration
                    guard UUID(uuidString: c.id)?.uuidString.lowercased() == c.id,
                          c.lanRequestID.flatMap(UUID.init(uuidString:)) != nil,
                          entry.secret.count == 32, loaded[c.id] == nil,
                          c.lanPairingState == .active || c.lanPairingState == .pendingAck,
                          c.identityConfirmed == (c.lanPairingState == .active),
                          c.lanPairingState != .pendingAck || c.scopes.isEmpty else { throw RemoteSetupError(String(localized: "The device record could not be read.")) }
                    loaded[c.id] = entry
                }
                // No cross-restart claim context exists. Remove every unfinished key before use.
                let active = loaded.filter { $0.value.registration.lanPairingState == .active }
                if active.count != loaded.count { try persistLAN(active) }
                else { lanClients = active }
            } else if settings.clients.contains(where: { $0.lanPairingState != nil }) {
                throw RemoteSetupError(String(localized: "Device credentials are missing. Remove the device and pair again."))
            }
            settings.clients.removeAll { $0.lanPairingState != nil }
            settings.clients += lanClients.values.map(\.registration).sorted { $0.pairedAt < $1.pairedAt }
        } catch {
            lanHealthy = false; lanClients = [:]
            settings.clients.removeAll { $0.lanPairingState != nil }
            loadError = String(localized: "Device credentials could not be accessed. Unlock the phone and reopen Actell.")
        }
    }
    private func persistLAN(_ clients: [String: LANClient]) throws {
        guard lanHealthy else { throw RemoteSetupError(String(localized: "Device credentials are unavailable. Reopen Actell.")) }
        do {
            let envelope = LANEnvelope(version: 1, clients: clients.values.sorted { $0.registration.id < $1.registration.id })
            try vault.write(JSONEncoder().encode(envelope), account: Self.lanAccount)
            lanClients = clients
        } catch { lanHealthy = false; throw error }
    }
    private func mirrorLAN() throws {
        var next = settings; next.clients.removeAll { $0.lanPairingState != nil }
        next.clients += lanClients.values.map(\.registration).sorted { $0.pairedAt < $1.pairedAt }
        try save(next)
    }
    func hasLANRequest(_ id: String) -> Bool { lanClients.values.contains { $0.registration.lanRequestID == id } }
    func createLANPending(name: String, requestID: String) throws -> RemoteClientRegistration {
        guard lanHealthy, settings.clients.count < 16, !hasLANRequest(requestID), !lanClients.values.contains(where: { $0.registration.lanPairingState == .pendingAck }) else { throw RemoteSetupError(String(localized: "The device could not be added. Remove unused devices and try again.")) }
        var client = RemoteClientRegistration(id: UUID().uuidString.lowercased(), name: name, pairedAt: Date())
        client.lanPairingState = .pendingAck; client.lanRequestID = requestID
        client.requestedDeviceName = name; client.bootstrapExpiresAt = nil
        let entry = LANClient(registration: client, secret: try secret())
        var clients = lanClients; clients[client.id] = entry
        try persistLAN(clients); try mirrorLAN()
        return client
    }
    func activateLANClient(_ id: String, name: String) throws {
        guard lanHealthy, var entry = lanClients[id], entry.registration.name == name else { throw RemoteSetupError(String(localized: "The pairing record is invalid. Add the device again.")) }
        if entry.registration.lanPairingState == .active { return }
        entry.registration.lanPairingState = .active
        // Local Allow authorizes the default capabilities once pairing is authenticated.
        // The active early return above preserves subsequent user permission changes.
        entry.registration.identityConfirmed = true
        entry.registration.scopes = Set(MuseCompanionScope.allCases)
        var clients = lanClients; clients[id] = entry
        try persistLAN(clients); try mirrorLAN()
    }
    func cancelLANPending(cancel: (String) -> Void) throws {
        let ids = lanClients.values.filter { $0.registration.lanPairingState == .pendingAck }.map { $0.registration.id }
        guard !ids.isEmpty else { return }
        var clients = lanClients
        for id in ids { clients.removeValue(forKey: id) }
        try persistLAN(clients) // Removing from this envelope deletes the live secret first.
        for id in ids { cancel(id) }
        try mirrorLAN()
    }

}
