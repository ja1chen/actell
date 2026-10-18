import Foundation
import CoreFoundation

/// Preserve event semantics while removing credentials before local retention.
public enum EventCredentialRedactor {
    private static let keys: Set<String> = ["authorization", "proxyauthorization", "apikey", "xapikey", "accesskey", "accesskeyid", "secretaccesskey", "accesstoken", "refreshtoken", "idtoken", "sessiontoken", "clientsecret", "password", "passwd", "secret", "token", "cookie", "setcookie", "privatekey", "signingkey", "signature"]
    public static func redact(_ value: Any, depth: Int = 0) throws -> Any {
        guard depth < 48 else { throw ModelError.protocolViolation("JSON nesting limit") }
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in object {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                result[key] = keys.contains(normalized) ? "[REDACTED]" : try redact(child, depth: depth + 1)
            }
            return result
        }
        if let array = value as? [Any] { return try array.map { try redact($0, depth: depth + 1) } }
        if let text = value as? String {
            if let data = text.data(using: .utf8), let nested = try? JSONSerialization.jsonObject(with: data), nested is [String: Any] || nested is [Any] {
                let sanitized = try redact(nested, depth: depth + 1)
                let encoded = try JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys, .withoutEscapingSlashes])
                let unchanged = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys, .withoutEscapingSlashes])
                if encoded == unchanged { return text }
                return String(decoding: encoded, as: UTF8.self)
            }
            return text
                .replacingOccurrences(of: #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9+/_=.~\-]+"#, with: "$1 [REDACTED]", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)([?&](?:access_token|refresh_token|api_key|client_secret|password|token)=)[^&#\s]+"#, with: "$1[REDACTED]", options: .regularExpression)
                .replacingOccurrences(of: #"\bsk-[A-Za-z0-9_\-]{16,}"#, with: "[REDACTED]", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)(https?://)[^/\s:@]+:[^/\s@]+@"#, with: "$1[REDACTED]@", options: .regularExpression)
        }
        return value
    }
}

/// Local response attachment, never a replay input or tool authorization.
public struct ProviderStreamEvent: Codable, Sendable, Equatable {
    public let type: String
    public let sequence: Int
    public let responseID: String?
    public let payloadJSON: Data
    public init(type: String, sequence: Int, responseID: String?, payloadJSON: Data) {
        self.type = type; self.sequence = sequence; self.responseID = responseID; self.payloadJSON = payloadJSON
    }
    public func bound(to responseID: String) throws -> Self {
        guard self.responseID == nil || self.responseID == responseID else { throw ModelError.protocolViolation("Response scope changed") }
        return Self(type: type, sequence: sequence, responseID: responseID, payloadJSON: payloadJSON)
    }
}
public struct ProviderResponseEvents: Codable, Sendable {
    public let responseID: String
    public let events: [ProviderStreamEvent]
    public init(responseID: String, events: [ProviderStreamEvent]) { self.responseID = responseID; self.events = events }
}

public enum JSONValue: Sendable, Equatable, Codable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(any: Any, depth: Int = 0) throws {
        guard depth < 48 else { throw ModelError.protocolViolation("JSON nesting limit") }
        switch any {
        case is NSNull: self = .null
        case let s as String: self = .string(s)
        case let n as NSNumber: self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(try a.map { try JSONValue(any: $0, depth: depth + 1) })
        case let o as [String: Any]: self = .object(try o.mapValues { try JSONValue(any: $0, depth: depth + 1) })
        default: throw ModelError.protocolViolation("Unsupported JSON value")
        }
    }
    public var foundation: Any { switch self { case .null: return NSNull(); case .bool(let b): return b; case .number(let n): return n; case .string(let s): return s; case .array(let a): return a.map(\.foundation); case .object(let o): return o.mapValues(\.foundation) } }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let n = try? c.decode(Double.self) { self = .number(n) } else if let s = try? c.decode(String.self) { self = .string(s) } else if let a = try? c.decode([JSONValue].self) { self = .array(a) } else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .null: try c.encodeNil(); case .bool(let b): try c.encode(b); case .number(let n): try c.encode(n); case .string(let s): try c.encode(s); case .array(let a): try c.encode(a); case .object(let o): try c.encode(o) } }
}
public struct ProviderScope: Sendable, Equatable, Codable {
    public let provider: String, endpoint: String, account: String, project: String, model: String
    public let run: UUID, branch: UUID
    public init(provider: String, endpoint: String, account: String, project: String = "", model: String, run: UUID = UUID(), branch: UUID = UUID()) { self.provider = provider; self.endpoint = endpoint; self.account = account; self.project = project; self.model = model; self.run = run; self.branch = branch }
}
public struct ScopedResponseID: Sendable, Equatable, Codable { public let value: String; public let scope: ProviderScope; public init(_ value: String, scope: ProviderScope) { self.value = value; self.scope = scope } }
public enum ContextMode: Sendable, Equatable, Codable { case stateless, previousResponse(ScopedResponseID), conversation(String) }
public enum StoragePolicy: String, Sendable, Codable { case none, responseChain }
public enum ExecutionMode: String, Sendable, Codable { case foreground, background }
public enum ResponseStatus: String, Sendable, Codable { case queued, inProgress = "in_progress", completed, incomplete, failed, cancelled, unknown }
public struct ProviderCapabilities: Sendable {
    public var foreground: Bool, streaming: Bool, stateless: Bool, responseChain: Bool
    public let conversations = false, background = false, compaction = false, hostedTools = false, remoteCancel = false
    public init(foreground: Bool = true, streaming: Bool = true, stateless: Bool = true, responseChain: Bool = true) { self.foreground = foreground; self.streaming = streaming; self.stateless = stateless; self.responseChain = responseChain }
}
public struct APIErrorInfo: Sendable, Equatable, Codable { public let code: String; public let message: String; public init(code: String, message: String) { self.code = code; self.message = message } }
public enum ModelOutputContent: Sendable, Equatable, Codable { case text(String, annotations: [JSONValue]), refusal(String) }
public struct OutputMessage: Sendable, Equatable, Codable {
    public let id: String; public let content: [ModelOutputContent]; public let phase: String?; public let scope: ProviderScope?; public let status: ResponseStatus; public let extra: [String: JSONValue]
    public init(id: String, content: [ModelOutputContent], phase: String? = nil, status: ResponseStatus = .completed, extra: [String: JSONValue] = [:], scope: ProviderScope? = nil) { self.id = id; self.content = content; self.phase = phase; self.scope = scope; self.status = status; self.extra = extra }
}
public struct ReasoningItem: Sendable, Equatable, Codable {
    public var readableText: String {
        let content = (extra["content"]?.foundation as? [[String: Any]] ?? []).compactMap { part in
            part["type"] as? String == "reasoning_text" ? part["text"] as? String : nil
        }
        return (summary + content).joined(separator: "\n")
    }
    public let id: String; public let summary: [String]; private let opaque: String?; public let scope: ProviderScope?; public let extra: [String: JSONValue]
    public init(id: String, summary: [String], encryptedContent: String? = nil, scope: ProviderScope? = nil, extra: [String: JSONValue] = [:]) { self.id = id; self.summary = summary; self.opaque = encryptedContent; self.scope = scope; self.extra = extra }
    /// Only wire serialization uses this field; never projected to UI or logs.
    public var encryptedContentForReplay: String? { opaque }
}
public struct ProviderOwnedItem: Sendable, Equatable, Codable { public let type: String; public let payload: JSONValue; public let scope: ProviderScope; public init(type: String, payload: JSONValue, scope: ProviderScope) { self.type = type; self.payload = payload; self.scope = scope } }
public enum ModelOutputItem: Sendable, Equatable, Codable {
    case message(OutputMessage), functionCall(ModelToolCall), reasoning(ReasoningItem), providerOwned(ProviderOwnedItem), unknown(ProviderOwnedItem)
    public func asReplayInput(scope: ProviderScope) throws -> ModelInputItem {
        switch self { case .message(let m): guard m.scope == nil || m.scope == scope else { throw ModelError.protocolViolation("Message scope mismatch") }; return .replay(self)
        case .functionCall(let c): guard c.scope == nil || c.scope == scope else { throw ModelError.protocolViolation("Function scope mismatch") }; return .replay(self)
        case .reasoning(let r): guard r.scope == nil || r.scope == scope else { throw ModelError.protocolViolation("Reasoning scope mismatch") }; return .replay(self)
        case .providerOwned(let i), .unknown(let i): guard i.scope == scope else { throw ModelError.protocolViolation("Opaque scope mismatch") }; throw ModelError.unsupportedCapability("Unknown output cannot be replayed") }
    }
}
public enum ModelInputContent: Sendable, Equatable, Codable { case text(String), image(ModelImage) }
public enum ModelInputItem: Sendable, Equatable, Codable {
    case message(role: ModelMessageRole, content: [ModelInputContent])
    case functionResult(callID: String, output: String)
    case replay(ModelOutputItem)
}
public enum ToolBatchValidator {
    public static func validate(_ calls: [ModelToolCall], previousCallIDs: Set<String> = []) throws {
        var ids = previousCallIDs
        for call in calls {
            guard !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ids.insert(call.id).inserted, !call.name.isEmpty, call.decodedArguments() != nil else { throw ModelError.protocolViolation("工具调用 ID 缺失、重复或参数不完整；本批未执行") }
        }
    }
}

/// Exact ordered gateway reasoning blocks, kept separately from visible reasoning.
/// Valid only in the original provider/endpoint/account/model/run/branch scope.
public struct ScopedChatReplayState: Sendable, Equatable, Codable {
    public let scope: ProviderScope
    private let blocks: [JSONValue]
    public init(scope: ProviderScope, reasoningDetails: [JSONValue]) { self.scope = scope; self.blocks = reasoningDetails }
    public func reasoningDetailsForReplay(scope: ProviderScope) throws -> [JSONValue] {
        guard self.scope == scope else { throw ModelError.protocolViolation("Chat reasoning scope mismatch") }; return blocks
    }
}
