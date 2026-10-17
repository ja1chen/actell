import Foundation

// Deliberately typed receipts. Never serialize screenshots, raw HTTP bodies,
// credentials, or model reasoning into persistent task history.
enum RunPhase: String, Codable { case idle, running, awaitingApproval, stopped, interrupted, completed, blocked }
enum RunMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case demo, live
    var id: String { rawValue }
    var label: String { self == .demo ? "离线演示" : "真实模型" }
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
    // Retained property name for the original PNG route; NCM video emits JPEG.
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
struct AgentLimits: Sendable {
    // SwiftAgentKit's loop uses a non-optional Int. No product turn budget.
    let maxTurns = Int.max
    let maxOutputTokens: Int? = nil
}
enum AppError: LocalizedError, Equatable {
    case invalid(String), unavailable(String), protocolViolation(String), stopped, timeout, unknownOutcome
    var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .protocolViolation(let s): return s
        case .stopped: return "已停止"
        case .timeout: return "桥接超时，已断开；没有自动重发动作"
        case .unknownOutcome: return "动作结果未知；未自动重发。"
        }
    }
}
struct ProviderSettings: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    func validatedURL() throws -> URL {
        guard let u = URL(string: baseURL), u.scheme == "https", u.host != nil,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else {
            throw AppError.invalid("模型地址必须是无用户名、密码、查询参数的 HTTPS API 地址")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalid("请填写支持图片和工具调用的模型 ID")
        }
        return u
    }
    var keyAccount: String { "provider:" + baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
