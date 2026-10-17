import Foundation
import CryptoKit
import Security

/// No URLs, payloads or credentials are interpolated into errors/logs.
enum ChatGPTAuthError: Error, LocalizedError {
    case invalidIdentity, missingPermission, disconnected, cancelled, expiredAttempt, refreshFailed, revoked, usageLimited, noModels, network, persistence
    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return String(localized: "ChatGPT identity signature, account, or authorization callback verification failed")
        case .missingPermission: return ChatGPTConnectionStatus.identityOnly.message
        case .disconnected: return String(localized: "Connect a ChatGPT account first")
        case .cancelled: return String(localized: "ChatGPT sign-in canceled")
        case .expiredAttempt: return String(localized: "This sign-in attempt expired. Start again.")
        case .refreshFailed: return ChatGPTConnectionStatus.refreshFailed.message
        case .revoked: return ChatGPTConnectionStatus.revoked.message
        case .usageLimited: return ChatGPTConnectionStatus.usageLimited.message
        case .noModels: return ChatGPTConnectionStatus.noModels.message
        case .network: return String(localized: "The ChatGPT service request failed. The model request was not replayed automatically.")
        case .persistence: return String(localized: "ChatGPT credentials could not be saved securely. Unlock your device and reconnect.")
        }
    }
}
protocol ChatGPTHTTPClient: Sendable { func data(_ request: URLRequest) async throws -> (Data, Int) }
final class ChatGPTOfficialHTTP: ChatGPTHTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let delegate = NoRedirectDelegate()
    init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 60
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func data(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url, [ChatGPTSubscriptionPolicy.token, ChatGPTIDTokenVerifier.jwksURL, ChatGPTAccountManager.discoveryURL, ChatGPTSubscriptionPolicy.resource.appendingPathComponent("models")].contains(url) || ChatGPTAccountManager.trustedRevocationURL(url) else { throw ChatGPTAuthError.network }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let h = response as? HTTPURLResponse else { throw ChatGPTAuthError.network }
            var data = Data()
            for try await byte in bytes { try Task.checkCancellation(); guard data.count < 8 * 1024 * 1024 else { throw ChatGPTAuthError.network }; data.append(byte) }
            return (data, h.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ChatGPTAuthError.network }
    }
}

struct ChatGPTVerifiedIdentity: Codable, Equatable, Sendable {
    let issuer: String, subject: String
    let email: String?
}
/// Verifies the compact JWS before using any identity claims. Only asymmetric
/// RS256/ES256 signing keys fetched from the fixed official JWKS are accepted.
enum ChatGPTIDTokenVerifier {
    static let issuer = "https://auth.openai.com"
    static let jwksURL = URL(string: issuer + "/.well-known/jwks.json")!
    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw ChatGPTAuthError.invalidIdentity }
        let s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4)) else { throw ChatGPTAuthError.invalidIdentity }
        return data
    }
    static func verify(_ token: String, jwks: Data, clientID: String, nonce: String?, accessToken: String? = nil, now: Date = Date()) throws -> ChatGPTVerifiedIdentity {
        guard token.utf8.count < 64 * 1024, jwks.count < 1024 * 1024, !clientID.isEmpty, clientID != "dynamic_agent_client" else { throw ChatGPTAuthError.invalidIdentity }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3,
              let header = try JSONSerialization.jsonObject(with: decode(pieces[0])) as? [String: Any],
              let alg = header["alg"] as? String, ["RS256", "ES256"].contains(alg),
              let kid = header["kid"] as? String, !kid.isEmpty,
              header["jku"] == nil, header["x5u"] == nil, header["crit"] == nil,
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]] else { throw ChatGPTAuthError.invalidIdentity }
        let matches = keys.filter { $0["kid"] as? String == kid && ($0["use"] == nil || $0["use"] as? String == "sig") && ($0["alg"] == nil || $0["alg"] as? String == alg) }
        guard matches.count == 1 else { throw ChatGPTAuthError.invalidIdentity }
        let key = matches[0], signature = try decode(pieces[2]), signed = Data((pieces[0] + "." + pieces[1]).utf8)
        if let operations = key["key_ops"] as? [String], !operations.contains("verify") { throw ChatGPTAuthError.invalidIdentity }
        if let type = header["typ"] as? String, type != "JWT" { throw ChatGPTAuthError.invalidIdentity }
        if alg == "ES256" {
            guard key["kty"] as? String == "EC", key["crv"] as? String == "P-256", let x = key["x"] as? String, let y = key["y"] as? String else { throw ChatGPTAuthError.invalidIdentity }
            let xd = try decode(x), yd = try decode(y)
            guard xd.count == 32, yd.count == 32, signature.count == 64 else { throw ChatGPTAuthError.invalidIdentity }
            do {
                let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + xd + yd)
                guard publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: signed) else { throw ChatGPTAuthError.invalidIdentity }
            } catch { throw ChatGPTAuthError.invalidIdentity }
        } else {
            guard key["kty"] as? String == "RSA", let n = key["n"] as? String, let e = key["e"] as? String else { throw ChatGPTAuthError.invalidIdentity }
            let modulus = try decode(n), exponent = try decode(e)
            guard modulus.count >= 256, modulus.count <= 1024, !exponent.isEmpty, exponent.count <= 8 else { throw ChatGPTAuthError.invalidIdentity }
            let der = tagged(0x30, integer(modulus) + integer(exponent))
            guard let publicKey = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else { throw ChatGPTAuthError.invalidIdentity }
        }
        guard let claims = try JSONSerialization.jsonObject(with: decode(pieces[1])) as? [String: Any],
              claims["iss"] as? String == issuer, let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = claims["exp"] as? Double, let issued = claims["iat"] as? Double,
              expiry > now.timeIntervalSince1970, issued <= now.timeIntervalSince1970 + 60, expiry > issued,
              (claims["nbf"] as? Double).map({ $0 <= now.timeIntervalSince1970 + 60 }) ?? true else { throw ChatGPTAuthError.invalidIdentity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID,
              (claims["azp"] as? String).map({ $0 == clientID }) ?? true,
              nonce.map({ claims["nonce"] as? String == $0 }) ?? true else { throw ChatGPTAuthError.invalidIdentity }
        if let hash = claims["at_hash"] as? String {
            guard let accessToken else { throw ChatGPTAuthError.invalidIdentity }
            let digest = Data(SHA256.hash(data: Data(accessToken.utf8))).prefix(16)
            guard try decode(hash) == digest else { throw ChatGPTAuthError.invalidIdentity }
        }
        return .init(issuer: issuer, subject: subject, email: claims["email"] as? String)
    }
    private static func integer(_ bytes: Data) -> Data {
        var d = bytes; while d.count > 1 && d.first == 0 { d.removeFirst() }
        if let first = d.first, first & 128 != 0 { d.insert(0, at: 0) }
        return tagged(2, d)
    }
    private static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        let n = body.count
        let length: [UInt8] = n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 255)]
        return Data([tag] + length) + body
    }
}

protocol ChatGPTCredentialStorage: Sendable {
    func load() throws -> Data?
    /// Replace the entire vault atomically. Never delete before an update.
    func replace(_ data: Data) throws
}
struct ChatGPTKeychainStorage: ChatGPTCredentialStorage {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.dotprototype.PhoneAgent.chatgpt-oauth-v1", kSecAttrAccount as String: "vault", kSecAttrSynchronizable as String: false] }
    func load() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ChatGPTAuthError.persistence }
        return data
    }
    func replace(_ data: Data) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, b in b } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ChatGPTAuthError.persistence }
    }
}
/// In-process storage for test injection; never selected by a release launch flag.
final class ChatGPTMemoryStorage: ChatGPTCredentialStorage, @unchecked Sendable {
    private let lock = NSLock(); private var value: Data?
    func load() -> Data? { lock.withLock { value } }
    func replace(_ data: Data) { lock.withLock { value = data } }
}
struct ChatGPTAccountSummary: Identifiable, Sendable {
    let id: String, label: String
    let status: ChatGPTConnectionStatus
}
struct ChatGPTAccess: Sendable, CustomStringConvertible {
    let account: String, token: String
    let generation: UUID
    let bindingGeneration: UUID
    var description: String { "ChatGPTAccess(<redacted>)" }
}
private struct ChatGPTCredential: Codable, Sendable {
    let clientID: String, identity: ChatGPTVerifiedIdentity
    var accessToken: String, refreshToken: String?, idToken: String, scopes: Set<String>, expires: Date, earliestRefresh: Date?
    var generation: UUID = UUID()
    var key: String { SHA256.hash(data: Data((clientID + "\n" + identity.issuer + "\n" + identity.subject).utf8)).map { String(format: "%02x", $0) }.joined() }
}
private struct ChatGPTVault: Codable {
    var hostID = UUID()
    var accounts: [String: ChatGPTCredential] = [:]
    var selected: [String: String] = [:]
    var provisional: [String: String] = [:]
}
struct ChatGPTPendingAuthorization: Sendable {
    let id: UUID, profileID: UUID, attempt: ChatGPTAuthorizationAttempt, hostID: UUID, expectedAccount: String?, deadline: Date
}
actor ChatGPTAccountManager {
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static func trustedRevocationURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && url.port == nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && url.path.hasPrefix("/api/accounts/")
    }
    static let shared: ChatGPTAccountManager = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-chatgpt-auth") { return ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: ChatGPTOAuthUIFixture()) }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return ChatGPTAccountManager(storage: ChatGPTMemoryStorage()) }
        #endif
        return ChatGPTAccountManager(storage: ChatGPTKeychainStorage())
    }()
    private let storage: any ChatGPTCredentialStorage, http: any ChatGPTHTTPClient
    private var vault: ChatGPTVault?
    private var pending: [UUID: ChatGPTPendingAuthorization] = [:]
    private var activeAttempts: [UUID: UUID] = [:]
    private var bindingGenerations: [UUID: UUID] = [:]
    private var refreshes: [String: Task<ChatGPTCredential, Error>] = [:]
    private var statuses: [String: ChatGPTConnectionStatus] = [:]
    private var unusable = Set<String>()
    init(storage: any ChatGPTCredentialStorage, http: any ChatGPTHTTPClient = ChatGPTOfficialHTTP()) { self.storage = storage; self.http = http }
    private func load() throws -> ChatGPTVault {
        if let vault { return vault }
        let value: ChatGPTVault
        do { value = try storage.load().map { try JSONDecoder().decode(ChatGPTVault.self, from: $0) } ?? ChatGPTVault() }
        catch { throw ChatGPTAuthError.persistence }
        vault = value; return value
    }
    private func save(_ value: ChatGPTVault) throws {
        do { try storage.replace(JSONEncoder().encode(value)); vault = value } catch { throw ChatGPTAuthError.persistence }
    }
    func summaries() throws -> [ChatGPTAccountSummary] {
        try load().accounts.map { key, c in .init(id: key, label: (c.identity.email ?? String(localized: "ChatGPT account")), status: statuses[key] ?? (c.accessToken.isEmpty ? .disconnected : .granted(tokenResponseScopes: c.scopes, expired: c.expires <= Date()))) }.sorted { $0.id < $1.id }
    }
    func selectedAccount(profileID: UUID) throws -> String? { try load().selected[profileID.uuidString] }
    func select(_ account: String, profileID: UUID) throws {
        var v = try load(); guard v.accounts[account] != nil else { throw ChatGPTAuthError.disconnected }
        invalidatePending(profileID); v.selected[profileID.uuidString] = account; try save(v)
        bindingGenerations[profileID] = UUID()
    }
    private func invalidatePending(_ profileID: UUID) { pending = pending.filter { $0.value.profileID != profileID }; activeAttempts.removeValue(forKey: profileID) }
    func begin(profileID: UUID, redirect: URL, addAccount: Bool = false, now: Date = Date()) throws -> ChatGPTPendingAuthorization {
        var v = try load(); invalidatePending(profileID)
        let key = addAccount ? nil : v.selected[profileID.uuidString]
        if addAccount { v.provisional.removeValue(forKey: profileID.uuidString) }
        let clientID = key.flatMap { v.accounts[$0]?.clientID } ?? v.provisional[profileID.uuidString]
        // Host identity is durable before any browser is opened.
        try save(v)
        let p = ChatGPTPendingAuthorization(id: UUID(), profileID: profileID, attempt: try .init(redirect: redirect, clientID: clientID), hostID: v.hostID, expectedAccount: key, deadline: now.addingTimeInterval(600))
        pending[p.id] = p; activeAttempts[profileID] = p.id; return p
    }
    func cancel(_ id: UUID) { pending.removeValue(forKey: id); activeAttempts = activeAttempts.filter { $0.value != id } }
    func finish(_ id: UUID, callback: URL, now: Date = Date()) async throws {
        // Consume exactly once before any suspension/code exchange.
        guard let p = pending.removeValue(forKey: id), p.deadline > now else { throw ChatGPTAuthError.expiredAttempt }
        defer { if activeAttempts[p.profileID] == id { activeAttempts.removeValue(forKey: p.profileID) } }
        let parsed = try p.attempt.validateCallback(callback)
        var v = try load(); v.provisional[p.profileID.uuidString] = parsed.issuedClientID; try save(v)
        let epoch = v.selected[p.profileID.uuidString]
        let result = try await exchange(["grant_type": "authorization_code", "client_id": parsed.issuedClientID, "code": parsed.code, "code_verifier": p.attempt.verifier, "redirect_uri": p.attempt.redirect.absoluteString, "resource": ChatGPTSubscriptionPolicy.resource.absoluteString], clientID: parsed.issuedClientID, nonce: p.attempt.nonce, previous: nil)
        try Task.checkCancellation()
        v = try load()
        guard activeAttempts[p.profileID] == id, p.deadline > Date(), v.selected[p.profileID.uuidString] == epoch, p.expectedAccount == nil || result.key == p.expectedAccount else { throw ChatGPTAuthError.invalidIdentity }
        v.accounts[result.key] = result; v.selected[p.profileID.uuidString] = result.key; v.provisional.removeValue(forKey: p.profileID.uuidString)
        try save(v); statuses.removeValue(forKey: result.key)
        unusable.remove(result.key)
        bindingGenerations[p.profileID] = UUID()
    }
    private func exchange(_ values: [String: String], clientID: String, nonce: String?, previous: ChatGPTCredential?) async throws -> ChatGPTCredential {
        var request = URLRequest(url: ChatGPTSubscriptionPolicy.token); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))! }
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&").utf8)
        let (data, status) = try await http.data(request)
        guard data.count <= 1024 * 1024, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTAuthError.network }
        if status != 200 {
            if let code = o["error"] as? String, ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code) { throw ChatGPTAuthError.revoked }
            throw ChatGPTAuthError.network
        }
        guard let access = o["access_token"] as? String, !access.isEmpty,
              (o["token_type"] as? String)?.lowercased() == "bearer", let life = o["expires_in"] as? Double, life > 0, life <= 3600,
              let scopesString = o["scope"] as? String else { throw ChatGPTAuthError.invalidIdentity }
        let refresh = o["refresh_token"] as? String
        if previous != nil { guard let refresh, !refresh.isEmpty, refresh != previous?.refreshToken else { throw ChatGPTAuthError.refreshFailed } }
        let idToken = o["id_token"] as? String
        let identity: ChatGPTVerifiedIdentity
        if let idToken {
            let (jwks, status) = try await http.data(URLRequest(url: ChatGPTIDTokenVerifier.jwksURL))
            guard status == 200 else { throw ChatGPTAuthError.invalidIdentity }
            identity = try ChatGPTIDTokenVerifier.verify(idToken, jwks: jwks, clientID: clientID, nonce: nonce, accessToken: access)
        } else if let previous, nonce == nil { identity = previous.identity }
        else { throw ChatGPTAuthError.invalidIdentity }
        if let previous { guard identity.issuer == previous.identity.issuer, identity.subject == previous.identity.subject else { throw ChatGPTAuthError.invalidIdentity } }
        let scopes = Set(scopesString.split(separator: " ").map(String.init))
        if scopes.contains("offline_access") { guard refresh?.isEmpty == false else { throw ChatGPTAuthError.invalidIdentity } }
        let earliest: Date?
        if let stamp = o["earliest_refresh_at"] as? Double { earliest = Date(timeIntervalSince1970: stamp) }
        else if let string = o["earliest_refresh_at"] as? String { earliest = ISO8601DateFormatter().date(from: string) }
        else { earliest = nil }
        return .init(clientID: clientID, identity: identity, accessToken: access, refreshToken: refresh, idToken: idToken ?? previous!.idToken, scopes: scopes, expires: Date().addingTimeInterval(life), earliestRefresh: earliest)
    }
    func access(profileID: UUID, expectedAccount: String? = nil, now: Date = Date()) async throws -> ChatGPTAccess {
        let v = try load()
        guard let key = v.selected[profileID.uuidString], let original = v.accounts[key], expectedAccount == nil || expectedAccount == key else { throw ChatGPTAuthError.disconnected }
        guard !unusable.contains(key) else { throw ChatGPTAuthError.refreshFailed }
        guard !original.accessToken.isEmpty, statuses[key] != .disconnected, statuses[key] != .expired else { throw ChatGPTAuthError.disconnected }
        guard original.scopes.isSuperset(of: ["resource.invoke", "chatgpt.tokens.use.direct"]) else { throw ChatGPTAuthError.missingPermission }
        var credential = original
        if original.expires.timeIntervalSince(now) < 60 {
            guard let refresh = original.refreshToken, original.earliestRefresh.map({ $0 <= now }) ?? true else { throw ChatGPTAuthError.refreshFailed }
            let task: Task<ChatGPTCredential, Error>
            if let existing = refreshes[key] { task = existing }
            else {
                task = Task { try await self.exchange(["grant_type": "refresh_token", "client_id": original.clientID, "refresh_token": refresh, "resource": ChatGPTSubscriptionPolicy.resource.absoluteString], clientID: original.clientID, nonce: nil, previous: original) }
                refreshes[key] = task
            }
            do {
                let renewed = try await task.value
                var current = try load()
                guard current.selected[profileID.uuidString] == key, let saved = current.accounts[key] else { throw ChatGPTAuthError.disconnected }
                if saved.generation == original.generation { current.accounts[key] = renewed; try save(current); credential = renewed }
                else { credential = saved }
                refreshes.removeValue(forKey: key); statuses.removeValue(forKey: key)
            } catch {
                refreshes.removeValue(forKey: key)
                let latest = try load()
                guard latest.accounts[key]?.generation == original.generation, statuses[key] != .disconnected else { throw ChatGPTAuthError.disconnected }
                if case ChatGPTAuthError.persistence = error { unusable.insert(key) }
                if case ChatGPTAuthError.revoked = error { try disconnectAccount(key); throw ChatGPTAuthError.revoked }
                statuses[key] = .refreshFailed; throw ChatGPTAuthError.refreshFailed
            }
        }
        try Task.checkCancellation()
        guard credential.scopes.isSuperset(of: ["resource.invoke", "chatgpt.tokens.use.direct"]) else { throw ChatGPTAuthError.missingPermission }
        let binding = bindingGenerations[profileID] ?? UUID(); bindingGenerations[profileID] = binding
        return .init(account: key, token: credential.accessToken, generation: credential.generation, bindingGeneration: binding)
    }
    func requireCurrent(_ access: ChatGPTAccess, profileID: UUID) throws {
        let v = try load()
        guard v.selected[profileID.uuidString] == access.account, v.accounts[access.account]?.generation == access.generation,
              bindingGenerations[profileID] == access.bindingGeneration, statuses[access.account] != .disconnected, statuses[access.account] != .expired else { throw ChatGPTAuthError.disconnected }
    }
    func report(_ status: ChatGPTConnectionStatus, account: String) throws {
        if status == .revoked { try disconnectAccount(account) } else { statuses[account] = status }
    }
    /// Ends the renewable session when the published discovery document exposes
    /// a trusted endpoint. Local logout always clears tokens; mapping is retained.
    func disconnect(profileID: UUID) async throws -> Bool {
        invalidatePending(profileID)
        bindingGenerations[profileID] = UUID()
        let v = try load()
        guard let key = v.selected[profileID.uuidString], let original = v.accounts[key] else { return false }
        statuses[key] = .disconnected; refreshes.removeValue(forKey: key)?.cancel()
        var confirmed = false
        if let refresh = original.refreshToken {
            do {
                let (document, status) = try await http.data(URLRequest(url: Self.discoveryURL))
                if status == 200, let o = try JSONSerialization.jsonObject(with: document) as? [String: Any],
                   o["issuer"] as? String == ChatGPTIDTokenVerifier.issuer,
                   let endpoint = o["revocation_endpoint"] as? String, let url = URL(string: endpoint), Self.trustedRevocationURL(url) {
                    var r = URLRequest(url: url); r.httpMethod = "POST"
                    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    var form = URLComponents(); form.queryItems = [.init(name: "token", value: refresh), .init(name: "token_type_hint", value: "refresh_token"), .init(name: "client_id", value: original.clientID)]
                    r.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
                    confirmed = try await http.data(r).1 == 200
                }
            } catch { confirmed = false }
        }
        var current = try load()
        if current.accounts[key]?.generation == original.generation {
            clearTokens(key, vault: &current); try save(current)
        }
        return confirmed
    }
    private func clearTokens(_ key: String, vault: inout ChatGPTVault) {
        guard var c = vault.accounts[key] else { return }
        c.accessToken = ""; c.refreshToken = nil; c.idToken = ""; c.scopes = []; c.expires = .distantPast; c.generation = UUID()
        vault.accounts[key] = c
    }
    private func disconnectAccount(_ key: String) throws {
        var v = try load(); clearTokens(key, vault: &v)
        refreshes.removeValue(forKey: key)?.cancel(); statuses[key] = .revoked; try save(v)
    }
    func models(profile: ProviderProfile) async throws -> ModelCatalog {
        let grant = try await access(profileID: profile.id)
        var request = URLRequest(url: ChatGPTSubscriptionPolicy.resource.appendingPathComponent("models"))
        request.setValue("Bearer " + grant.token, forHTTPHeaderField: "Authorization")
        let (data, status) = try await http.data(request)
        try requireCurrent(grant, profileID: profile.id)
        if status == 401 { try report(.expired, account: grant.account); throw ChatGPTAuthError.revoked }
        if status == 429 { try report(.usageLimited, account: grant.account); throw ChatGPTAuthError.usageLimited }
        guard status == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTAuthError.network }
        let rows = try ModelDiscoveryClient.parseList(o, providerKind: .chatGPTSubscription)
        if rows.isEmpty { try report(.noModels, account: grant.account); throw ChatGPTAuthError.noModels }
        return .init(endpoint: try profile.catalogEndpoint(), fetchedAt: Date(), models: rows)
    }
}
