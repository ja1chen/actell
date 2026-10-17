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
        guard numeric || dns else { throw RemoteSetupError("请输入证书对应的 IP 地址或域名，不含 https:// 或路径") }
        guard let port = UInt16(port), port != 0 else { throw RemoteSetupError("端口须为 1–65535") }
        let values = sources.split { $0.isWhitespace || $0 == "," }.map(String.init)
        guard !values.isEmpty, values.count <= 64 else { throw RemoteSetupError("请填写 1–64 个允许的客户端来源 IP") }
        var seen = Set<RemoteSourceAddress>()
        for value in values {
            guard let address = RemoteSourceAddress(literal: value), seen.insert(address).inserted else {
                throw RemoteSetupError("来源须为不重复的具体 IP 地址，不支持域名、网段或通配符")
            }
        }
        return (host, port, values)
    }
    var endpoint: String { "https://\(host.contains(":") ? "[\(host)]" : host):\(port)" }
}
struct RemoteSetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RemoteVaultError: LocalizedError {
    let status: OSStatus
    let operation: String
    var errorDescription: String? {
        if status == errSecMissingEntitlement { return "当前 App 安装签名无法完成钥匙串" + operation + "，请检查安装签名后重试" }
        return "钥匙串" + operation + "失败，请解锁设备后重试"
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
        guard status == errSecSuccess, let data = result as? Data else { throw RemoteVaultError(status: status, operation: "读取") }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(account).merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw RemoteVaultError(status: status, operation: "保存") }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteVaultError(status: status, operation: "移除") }
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
            catch { settings = .init(); loadError = "Muse 配置无法读取；请检查后重新保存连接配置" }
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
        guard !data.isEmpty, data.count <= 32 * 1024 else { throw RemoteSetupError("证书文件须小于 32 KiB，且包含服务器证书及私钥") }
        var imported: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess, let items = imported as? [[String: Any]], items.count == 1,
              let value = items.first?[kSecImportItemIdentity as String], CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw RemoteSetupError("无法导入证书，请检查 .p12/.pfx 文件、密码与私钥；原证书保留")
        }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, key != nil,
              let begins = SecCertificateCopyNotValidBeforeDate(certificate),
              let expires = SecCertificateCopyNotValidAfterDate(certificate) else { throw RemoteSetupError("证书或私钥不完整") }
        guard (begins as Date) <= Date(), (expires as Date) > Date() else { throw RemoteSetupError("证书尚未生效或已经过期") }
        let importedChain = items[0][kSecImportItemCertChain as String] as? [SecCertificate] ?? []
        let chain = importedChain.isEmpty ? [certificate] : importedChain
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        let summary = RemoteCertificateSummary(name: SecCertificateCopySubjectSummary(certificate) as String? ?? "服务器证书", fingerprint: fingerprint, expiresAt: expires as Date)
        return (identity, chain, summary)
    }
    private func generatedIdentityProvider() -> RemoteGeneratedIdentityProvider {
        // The persisted random host also isolates this installation's Keychain
        // namespace. A reinstall must not silently reuse another installation's pin.
        RemoteGeneratedIdentityProvider(namespace: "actell.muse.generated-tls.v1." + (settings.generatedHost ?? settings.host))
    }
    func prepareCompanion() throws {
        guard settings.clients.isEmpty || (settings.usesCompanionLAN && settings.identityKind == "generated") else {
            throw RemoteSetupError("切换到独立伴侣连接前，请先撤销开发模式客户端")
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
        next.certificate = .init(name: "执言本机身份", fingerprint: material.fingerprint, expiresAt: material.expiresAt)
        try save(next)
    }
    func importIdentity(data: Data, password: String) throws {
        guard settings.clients.isEmpty else { throw RemoteSetupError("更换服务器身份前，请先撤销现有设备并重新配对") }
        let (_, _, summary) = try Self.unpack(data, password: password)
        // Only the app-owned generic-password entry persists. Security import is memory-only.
        let encoded = try JSONEncoder().encode(IdentityEnvelope(pkcs12: data, password: password))
        try vault.write(encoded, account: Self.identityAccount)
        var next = settings; next.certificate = summary; next.identityKind = "imported"; next.companionMode = false; try save(next)
    }
    func removeIdentity() throws {
        guard settings.clients.isEmpty else { throw RemoteSetupError("移除服务器身份前，请先撤销所有设备") }
        if settings.identityKind == "generated" { try generatedIdentityProvider().remove() }
        else { try vault.remove(Self.identityAccount) }
        var next = settings; next.certificate = nil; next.identityKind = nil; next.companionMode = false; try save(next)
    }
    func loadIdentity() throws -> SecIdentity {
        if settings.identityKind == "generated" {
            guard let material = try generatedIdentityProvider().load(host: settings.host),
                  material.fingerprint == settings.certificate?.fingerprint else {
                throw RemoteSetupError("本机身份记录不一致；连接已关闭，请检查后重新配对")
            }
            return material.identity
        }
        guard let data = try vault.read(Self.identityAccount) else { throw RemoteSetupError("请先导入服务器证书") }
        let envelope = try JSONDecoder().decode(IdentityEnvelope.self, from: data)
        let (identity, chain, summary) = try Self.unpack(envelope.pkcs12, password: envelope.password)
        guard settings.certificate?.fingerprint == summary.fingerprint else { throw RemoteSetupError("证书记录不一致，请重新导入") }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, settings.host as CFString), &trust) == errSecSuccess, let trust,
              SecTrustSetAnchorCertificates(trust, [chain.last!] as CFArray) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { throw RemoteSetupError("证书与连接地址不匹配，或证书链不适合服务器 TLS") }
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
        guard status == errSecSuccess else { throw RemoteSetupError("无法生成客户端密钥，请重试") }
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
        guard settings.certificate != nil else { throw RemoteSetupError("请先准备本机 TLS 身份") }
        let identity = try loadIdentity()
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw RemoteSetupError("服务器证书不可读取")
        }
        let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n" + base64 + "\n-----END CERTIFICATE-----\n"
    }
    func recordHello(clientID: String, name: String) throws {
        guard let index = settings.clients.firstIndex(where: { $0.id == clientID }),
              !name.isEmpty, name.count <= MuseCompanionProtocol.maximumDeviceNameLength else {
            throw RemoteSetupError("未识别的配对请求")
        }
        if settings.clients[index].identityConfirmed { return }
        guard settings.clients[index].lanPairingState == nil else { throw RemoteSetupError("请等待设备完成配对") }
        guard settings.clients[index].bootstrapExpiresAt.map({ $0 > Date() }) == true else {
            throw RemoteSetupError("配对材料已过期，请撤销后重新生成")
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
            throw RemoteSetupError("设备名称须为 1–64 个字符，不能包含换行或控制字符")
        }
        return value
    }
    func setAuthorization(clientID: String, scopes: Set<MuseCompanionScope>, identityConfirmed: Bool,
                          name: String? = nil) throws {
        let displayName = try name.map(Self.normalizedDeviceName)
        guard let index = settings.clients.firstIndex(where: { $0.id == clientID }),
              settings.clients[index].requestedDeviceName != nil,
              identityConfirmed || scopes.isEmpty,
              settings.clients[index].identityConfirmed || settings.clients[index].bootstrapExpiresAt.map({ $0 > Date() }) == true else { throw RemoteSetupError("请先通过可信 USB 配置确认设备身份，并等待设备申请绑定") }
        if settings.clients[index].lanPairingState != nil {
            guard lanHealthy, settings.clients[index].lanPairingState == .active, identityConfirmed,
                  var entry = lanClients[clientID] else { throw RemoteSetupError("配对未完成，请重新添加设备") }
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
        guard !name.isEmpty, name.count <= 64 else { throw RemoteSetupError("客户端名称须为 1–64 个字符") }
        guard settings.clients.count < 16 else { throw RemoteSetupError("最多保存 16 个客户端，请先撤销不再使用的客户端") }
        guard !settings.host.isEmpty, (settings.usesCompanionLAN || !settings.sources.isEmpty) else { throw RemoteSetupError("请先保存连接地址与允许来源") }
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
                guard envelope.version == 1, envelope.clients.count <= 16 else { throw RemoteSetupError("设备记录无法读取") }
                var loaded: [String: LANClient] = [:]
                for entry in envelope.clients {
                    let c = entry.registration
                    guard UUID(uuidString: c.id)?.uuidString.lowercased() == c.id,
                          c.lanRequestID.flatMap(UUID.init(uuidString:)) != nil,
                          entry.secret.count == 32, loaded[c.id] == nil,
                          c.lanPairingState == .active || c.lanPairingState == .pendingAck,
                          c.identityConfirmed == (c.lanPairingState == .active),
                          c.lanPairingState != .pendingAck || c.scopes.isEmpty else { throw RemoteSetupError("设备记录无法读取") }
                    loaded[c.id] = entry
                }
                // No cross-restart claim context exists. Remove every unfinished key before use.
                let active = loaded.filter { $0.value.registration.lanPairingState == .active }
                if active.count != loaded.count { try persistLAN(active) }
                else { lanClients = active }
            } else if settings.clients.contains(where: { $0.lanPairingState != nil }) {
                throw RemoteSetupError("设备凭据已丢失，请移除记录后重新配对")
            }
            settings.clients.removeAll { $0.lanPairingState != nil }
            settings.clients += lanClients.values.map(\.registration).sorted { $0.pairedAt < $1.pairedAt }
        } catch {
            lanHealthy = false; lanClients = [:]
            settings.clients.removeAll { $0.lanPairingState != nil }
            loadError = "设备凭据无法读取或清理，请解锁后重新打开执言"
        }
    }
    private func persistLAN(_ clients: [String: LANClient]) throws {
        guard lanHealthy else { throw RemoteSetupError("设备凭据不可用，请重新打开执言") }
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
        guard lanHealthy, settings.clients.count < 16, !hasLANRequest(requestID), !lanClients.values.contains(where: { $0.registration.lanPairingState == .pendingAck }) else { throw RemoteSetupError("无法添加设备，请移除不再使用的设备后重试") }
        var client = RemoteClientRegistration(id: UUID().uuidString.lowercased(), name: name, pairedAt: Date())
        client.lanPairingState = .pendingAck; client.lanRequestID = requestID
        client.requestedDeviceName = name; client.bootstrapExpiresAt = nil
        let entry = LANClient(registration: client, secret: try secret())
        var clients = lanClients; clients[client.id] = entry
        try persistLAN(clients); try mirrorLAN()
        return client
    }
    func activateLANClient(_ id: String, name: String) throws {
        guard lanHealthy, var entry = lanClients[id], entry.registration.name == name else { throw RemoteSetupError("配对记录无效，请重新添加设备") }
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
