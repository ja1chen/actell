import Foundation

// Deliberately typed receipts. Never serialize screenshots, raw HTTP bodies,
// credentials, or model reasoning into persistent task history.
enum RunPhase: String, Codable { case idle, running, awaitingApproval, stopped, interrupted, completed, blocked }
enum RunMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case demo, live
    var id: String { rawValue }
    var label: String { self == .demo ? String(localized: "Offline demo") : String(localized: "Live model") }
}
struct Receipt: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let message: String
    init(_ message: String) { id = UUID(); date = Date(); self.message = String(message.prefix(500)) }
}
struct TaskRecord: Identifiable, Codable {
    var id = UUID()
    var goal: String
    var mode: RunMode
    var phase: RunPhase = .idle
    var updatedAt = Date()
    var receipts: [Receipt] = []
    var result = ""
    var reportedTokens: Int = 0
    var usageComplete = true
    mutating func log(_ message: String) {
        receipts.append(Receipt(message)); receipts = Array(receipts.suffix(100)); updatedAt = Date()
    }
}
struct FrameImage: Sendable {
    let id: String
    // Retained property name for the original PNG route; CoreDevice video emits JPEG.
    let png: Data
    var mimeType: String { png.starts(with: [0xff, 0xd8, 0xff]) ? "image/jpeg" : "image/png" }
    let width: Int
    let height: Int
    let capturedAt: Date
    let isDemo: Bool
    var capture: CaptureStamp? = nil
    var remoteGeometryToken: String? = nil
}
struct Approval: Identifiable, Sendable {
    let id = UUID()
    let tool: String
    let detail: String
    // Coordinate actions bind a frame; system actions bind a one-use request reference.
    let imageID: String
    var callID: String? = nil
    var parametersDigest = ""
    var version = 1
    // Approval-request timeout, measured from request creation, not capture time.
    var expiresAt = Date().addingTimeInterval(45)
}
enum InputAuthorizationMode: String, Codable, Sendable { case perAction, task }
/// One replaceable decision point for tool effects. Readiness and one-use dispatch
/// records are enforced by the host independently of this decision.
struct ToolAuthorizationPolicy: Sendable {
    enum Decision: Sendable, Equatable { case allow, deny, requireConfirmation }
    let inputGrantMode: InputAuthorizationMode
    let evaluate: @Sendable (Approval) async -> Decision
    init(inputGrantMode: InputAuthorizationMode = .task, evaluate: @escaping @Sendable (Approval) async -> Decision) {
        self.inputGrantMode = inputGrantMode; self.evaluate = evaluate
    }
    static let fullAccess = Self(evaluate: { _ in .allow })
    static let userConfirmation = Self(inputGrantMode: .perAction, evaluate: { _ in .requireConfirmation })
}

struct AgentLimits: Sendable {
    let maxTurns: Int? = nil
    let maxOutputTokens: Int? = nil
}
enum AppError: LocalizedError, Equatable {
    case invalid(String), unavailable(String), protocolViolation(String), stopped, timeout, unknownOutcome
    var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .protocolViolation(let s): return s
        case .stopped: return String(localized: "Stopped")
        case .timeout: return String(localized: "Bridge timed out and disconnected. Actions were not resent automatically.")
        case .unknownOutcome: return String(localized: "Action result unknown. It was not resent automatically.")
        }
    }
}
struct ProviderSettings: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    func validatedURL() throws -> URL {
        guard let u = URL(string: baseURL), u.scheme == "https", u.host != nil,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else {
            throw AppError.invalid(String(localized: "The model URL must be an HTTPS API URL without a username, password, or query parameters"))
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalid(String(localized: "Enter a model ID that supports images and tool calling"))
        }
        return u
    }
    var keyAccount: String { "provider:" + baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
