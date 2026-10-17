import Foundation
import CryptoKit
import Security

/// Official route policy. No browser, credential registration, token loading or
/// inference happens until an iOS callback/identity-verification flow is validated.
enum ChatGPTSubscriptionPolicy {
    static let resource = URL(string: "https://api.openai.com/v1")!
    static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let mobileLoginNotice = String(localized: "Connect ChatGPT in your browser. Subscription access needs separate authorization. Only authorized models use your plan allowance. The app will not switch to a paid API automatically.")
    static let usageNotice = String(localized: "Subscription access applies only to authorized accounts and models, subject to plan and workspace limits. Requests send local context with store=false and stream=true. previous_response_id is not supported.")
}

/// Offline-testable authorization attempt. Kept in memory, never serialized or logged.
/// This is preparation for the documented loopback flow, not a live iOS login.
struct ChatGPTAuthorizationAttempt: CustomStringConvertible {
    let redirect: URL
    let state: String
    let nonce: String
    let verifier: String
    let clientID: String?
    var description: String { "ChatGPTAuthorizationAttempt(<redacted>)" }

    init(redirect: URL, clientID: String? = nil) throws {
        guard let parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", parts.port.map({ (1...65535).contains($0) }) == true,
              parts.path == "/auth/callback", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              clientID != "dynamic_agent_client" else { throw AppError.invalid(String(localized: "Invalid authorization callback or registration ID")) }
        self.redirect = redirect; self.clientID = clientID
        state = try Self.random(); nonce = try Self.random(); verifier = try Self.random()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError.unavailable(String(localized: "Could not generate secure authorization randomness")) }
        return base64url(Data(bytes))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var challenge: String { Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    func authorizationURL(hostID: UUID) -> URL {
        var parts = URLComponents(url: ChatGPTSubscriptionPolicy.authorize, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "client_id", value: clientID ?? "dynamic_agent_client"),
            .init(name: "ext_agent_host_id", value: "urn:uuid:" + hostID.uuidString.lowercased()),
            .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            .init(name: "resource", value: ChatGPTSubscriptionPolicy.resource.absoluteString),
            .init(name: "state", value: state), .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge)
        ]
        if clientID == nil { parts.queryItems?.append(.init(name: "agent_name_hint", value: "Actell")) }
        return parts.url!
    }
    func validateCallback(_ callback: URL) throws -> (code: String, issuedClientID: String) {
        guard var parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.fragment == nil else { throw AppError.invalid(String(localized: "Invalid authorization callback")) }
        let items = parts.queryItems ?? []; parts.query = nil
        guard parts.url == redirect else { throw AppError.invalid(String(localized: "Authorization callback address mismatch")) }
        guard Set(items.map(\.name)).count == items.count else { throw AppError.invalid(String(localized: "Duplicate authorization callback parameters")) }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw AppError.invalid(String(localized: "Authorization state mismatch")) }
        if values["error"] != nil { throw AppError.unavailable(String(localized: "Authorization was canceled or denied. Credentials were not exchanged.")) }
        guard let code = values["code"], !code.isEmpty else { throw AppError.invalid(String(localized: "Authorization code missing")) }
        let issued = values["client_id"] ?? clientID
        guard let issued, !issued.isEmpty, issued != "dynamic_agent_client", clientID == nil || issued == clientID else {
            throw AppError.invalid(String(localized: "Authorization registration ID mismatch"))
        }
        return (code, issued)
    }
    /// Call only after JWKS signature, issuer, audience and expiry validation.
    func validateVerifiedNonce(_ verifiedNonce: String) throws {
        guard verifiedNonce == nonce else { throw AppError.invalid(String(localized: "Authorization nonce mismatch")) }
    }
}

/// Display-only permission status; never contains credentials or trusts callback scopes.
enum ChatGPTConnectionStatus: Equatable {
    case disconnected, identityOnly, planAuthorized, expired, refreshFailed, revoked, usageLimited, noModels
    static func granted(tokenResponseScopes: Set<String>, expired: Bool) -> Self {
        if expired { return .expired }
        return tokenResponseScopes.isSuperset(of: ["resource.invoke", "chatgpt.tokens.use.direct"]) ? .planAuthorized : .identityOnly
    }
    var message: String {
        switch self {
        case .disconnected: return String(localized: "ChatGPT not connected")
        case .identityOnly: return String(localized: "Identity connected. Subscription access has not been authorized.")
        case .planAuthorized: return String(localized: "Subscription access authorized. Check available models and usage limits.")
        case .expired: return String(localized: "Authorization expired. Sign in again.")
        case .refreshFailed: return String(localized: "Authorization refresh failed. No request was sent or retried.")
        case .revoked: return String(localized: "Authorization revoked. Sign in again.")
        case .usageLimited: return String(localized: "Subscription access is limited or rate-limited for this app. Check ChatGPT usage settings. No credits were purchased and no paid API was used.")
        case .noModels: return String(localized: "No models are available for this account")
        }
    }
}
