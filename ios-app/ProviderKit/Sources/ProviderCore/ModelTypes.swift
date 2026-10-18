import Foundation

/// Portable Agent messages are an input projection; native output is authoritative.
public enum ModelMessageRole: String, Sendable, Codable { case system, user, assistant, tool }
public struct ModelMessage: Sendable, Equatable, Codable {
    public let role: ModelMessageRole
    public let content: String
    public var images: [ModelImage]
    public var replayState: ScopedChatReplayState?
    public var toolCallId: String?
    public var toolCalls: [ModelToolCall]?
    public init(role: ModelMessageRole, content: String, images: [ModelImage] = [], toolCallId: String? = nil, toolCalls: [ModelToolCall]? = nil, replayState: ScopedChatReplayState? = nil) {
        self.role = role; self.content = content; self.images = images; self.toolCallId = toolCallId; self.toolCalls = toolCalls; self.replayState = replayState
    }
    public static func system(_ text: String) -> Self { .init(role: .system, content: text) }
    public static func user(_ text: String) -> Self { .init(role: .user, content: text) }
    public static func user(_ text: String, images: [ModelImage]) -> Self { .init(role: .user, content: text, images: images) }
    public static func assistant(_ text: String, replayState: ScopedChatReplayState? = nil) -> Self { .init(role: .assistant, content: text, replayState: replayState) }
    public static func assistant(content: String = "", toolCalls: [ModelToolCall], replayState: ScopedChatReplayState? = nil) -> Self { .init(role: .assistant, content: content, toolCalls: toolCalls, replayState: replayState) }
    public static func tool(_ text: String, toolCallId: String) -> Self { .init(role: .tool, content: text, toolCallId: toolCallId) }
}
/// Data is a copy-on-write byte reference, never a retained base64 string. Codable
/// keeps the old AgentMessage image envelope readable. Disk-backed media can be
/// supplied by URL; loaded only at serialization and bounded there.
public struct ModelImage: Sendable, Equatable, Codable {
    public let data: Data
    public let mimeType: String
    public var fileURL: URL? = nil
    public var observationID: String? = nil
    public var width: Int? = nil
    public var height: Int? = nil
    public init(data: Data, mimeType: String = "image/png") { self.data = data; self.mimeType = mimeType }
    public init(fileURL: URL, mimeType: String, observationID: String? = nil) {
        self.data = Data(); self.fileURL = fileURL; self.mimeType = mimeType; self.observationID = observationID
    }
    public func bytes(limit: Int = 8 * 1024 * 1024) throws -> Data {
        guard ["image/png", "image/jpeg", "image/webp"].contains(mimeType) else { throw ModelError.invalidRequest("Unsupported image type") }
        if let fileURL {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit + 1
            guard size <= limit else { throw ModelError.invalidRequest("Image exceeds byte limit") }
        }
        let value = try fileURL.map { try Data(contentsOf: $0, options: .mappedIfSafe) } ?? data
        guard value.count <= limit else { throw ModelError.invalidRequest("Image exceeds byte limit") }; return value
    }
}
public enum ModelReasoningEffort: String, Sendable, Codable { case off = "none", minimal, low, medium, high, xhigh, max, ultra }
public struct ModelRequest: Sendable {
    public var model: String
    public var messages: [ModelMessage]
    public var input: [ModelInputItem]? = nil
    public var instructions: String? = nil
    public var context: ContextMode = .stateless
    public var storage: StoragePolicy = .none
    public var execution: ExecutionMode = .foreground
    public var temperature: Double?
    public var maxTokens: Int?
    public var topP: Double?
    public var tools: [ModelToolDefinition]
    public var reasoningEffort: ModelReasoningEffort?
    public var id: UUID
    public var stallTimeout: TimeInterval? = nil
    public init(model: String, messages: [ModelMessage], temperature: Double? = nil, maxTokens: Int? = nil, topP: Double? = nil, tools: [ModelToolDefinition] = [], reasoningEffort: ModelReasoningEffort? = nil, id: UUID = UUID()) {
        self.model = model; self.messages = messages; self.temperature = temperature; self.maxTokens = maxTokens; self.topP = topP; self.tools = tools; self.reasoningEffort = reasoningEffort; self.id = id
    }
}
public enum ModelEvent: Sendable {
    case text(String), reasoning(String), toolCall(ModelToolCall)
    /// Legacy fixture completion; native adapters emit exactly one terminal.
    case finish(reason: ModelFinishReason?, usage: ModelUsage?)
    case terminal(ModelResponse)
    case progress(ModelProgress)
    case error(any Error)
}
public enum ModelFinishReason: String, Sendable, Codable { case stop, length, contentFilter = "content_filter", toolCalls = "tool_calls", unknown }
public struct ModelUsage: Sendable, Equatable, Codable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let cachedTokens: Int?
    public let reasoningTokens: Int?
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil, cachedTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.totalTokens = totalTokens; self.cachedTokens = cachedTokens; self.reasoningTokens = reasoningTokens
    }
}
public struct ModelResponse: Sendable {
    public let id: String
    public let scope: ProviderScope?
    public var scopedID: ScopedResponseID? { scope.map { ScopedResponseID(id, scope: $0) } }
    public let model: String
    public let status: ResponseStatus
    public let output: [ModelOutputItem]
    public let error: APIErrorInfo?
    public let incomplete: JSONValue?
    public let extra: [String: JSONValue]
    public let streamEvents: [ProviderStreamEvent]
    public let usage: ModelUsage?
    public let request: ModelRequest
    public let providerName: String
    public let replayState: ScopedChatReplayState?
    public let finishReason: ModelFinishReason?
    public let permitsTextToolInference: Bool
    public var rawData: Data? { nil }
    public var text: String { output.compactMap { if case .message(let m) = $0 { return m.content.compactMap { if case .text(let text, _) = $0 { return text }; if case .refusal(let text) = $0 { return text }; return nil }.joined() }; return nil }.joined() }
    public var reasoning: String? { let s = output.compactMap { if case .reasoning(let r) = $0 { return r.readableText }; return nil }.joined(separator: "\n"); return s.isEmpty ? nil : s }
    public var toolCalls: [ModelToolCall] { output.compactMap { if case .functionCall(let c) = $0 { return c }; return nil } }
    public init(id: String, model: String, status: ResponseStatus, scope: ProviderScope? = nil, output: [ModelOutputItem], usage: ModelUsage? = nil, error: APIErrorInfo? = nil, incomplete: JSONValue? = nil, extra: [String: JSONValue] = [:], streamEvents: [ProviderStreamEvent] = [], request: ModelRequest, providerName: String, permitsTextToolInference: Bool = false) {
        self.streamEvents = streamEvents
        self.replayState = nil; self.id = id; self.scope = scope; self.model = model; self.status = status; self.output = output; self.usage = usage; self.error = error; self.incomplete = incomplete; self.extra = extra; self.request = request; self.providerName = providerName; self.permitsTextToolInference = permitsTextToolInference
        finishReason = status == .completed ? (output.contains { if case .functionCall = $0 { return true }; return false } ? .toolCalls : .stop) : .unknown
    }
    /// In-process fixtures supply the same domain output without SDK DTOs.
    public init(text: String, reasoning: String? = nil, finishReason: ModelFinishReason? = nil, usage: ModelUsage? = nil, toolCalls: [ModelToolCall] = [], request: ModelRequest, providerName: String, rawData: Data? = nil, replayState: ScopedChatReplayState? = nil) {
        self.streamEvents = []
        self.replayState = replayState; self.id = request.id.uuidString; self.scope = nil; self.model = request.model; self.status = .completed; self.usage = usage; self.request = request; self.providerName = providerName; self.finishReason = finishReason; self.error = nil; self.incomplete = nil; self.extra = [:]; self.permitsTextToolInference = false
        output = (reasoning.map { [.reasoning(.init(id: "reasoning", summary: [$0]))] } ?? []) + (text.isEmpty ? [] : [.message(.init(id: "message", content: [.text(text, annotations: [])]))]) + toolCalls.map(ModelOutputItem.functionCall)
    }
}
public struct ModelToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let schema: JSONValue
    public var parameters: [String: Any] { schema.foundation as? [String: Any] ?? [:] }
    public init(name: String, description: String, parameters: [String: Any]) { self.name = name; self.description = description; self.schema = (try? JSONValue(any: parameters)) ?? .object([:]) }
}
public struct ModelToolCall: Sendable, Equatable, Codable {
    public let id: String // call ID, never the output item ID
    public let itemID: String?
    public let scope: ProviderScope?
    public let status: ResponseStatus?
    public let extra: [String: JSONValue]?
    public let name: String
    public let arguments: String
    public var providerMetadata: [String: String]
    public init(id: String = UUID().uuidString, itemID: String? = nil, name: String, arguments: String, providerMetadata: [String: String] = [:], status: ResponseStatus? = nil, extra: [String: JSONValue]? = nil, scope: ProviderScope? = nil) { self.id = id; self.itemID = itemID; self.scope = scope; self.status = status; self.extra = extra; self.name = name; self.arguments = arguments; self.providerMetadata = providerMetadata }
    public func decodedArguments() -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] }
}
public struct ProviderConfiguration: Sendable {
    public let name: String
    public let baseURL: URL
    public let apiKey: String?
    public let defaultModel: String?
    public init(name: String, baseURL: URL, apiKey: String? = nil, defaultModel: String? = nil) { self.name = name; self.baseURL = baseURL; self.apiKey = apiKey; self.defaultModel = defaultModel }
}
public protocol ModelProvider: Sendable {
    static var name: String { get }
    var configuration: ProviderConfiguration { get }
    func capabilities(for model: String) async throws -> ProviderCapabilities
    func complete(_ request: ModelRequest) async throws -> ModelResponse
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
}
public enum ModelError: Error, Sendable, Equatable, LocalizedError {
    case invalidRequest(String), invalidResponse(String), streamingError(String), providerError(String), networkError(String), unsupportedOperation(String), unknownProvider(String)
    case httpError(Int, Data?)
    case protocolViolation(String), interrupted, cancelledLocally, unsupportedCapability(String)
    public var errorDescription: String? {
        switch self {
        case .httpError(let code, _): return "模型服务返回 HTTP \(code)；没有自动重试"
        case .interrupted: return "模型请求受理结果不明；没有自动重试"
        case .cancelledLocally: return "本地已停止接收；未核实远端取消"
        case .invalidRequest(let s), .invalidResponse(let s), .streamingError(let s), .providerError(let s), .networkError(let s), .unsupportedOperation(let s), .unknownProvider(let s), .protocolViolation(let s), .unsupportedCapability(let s): return s
        }
    }
}
public struct ModelStreamStalled: Error, Sendable { public let seconds: TimeInterval; public init(seconds: TimeInterval) { self.seconds = seconds } }
public struct ModelErrorMessage: Sendable { public let summary: String; public let details: String?; public init(summary: String, details: String? = nil) { self.summary = summary; self.details = details } }
extension Error { public var modelUserMessage: ModelErrorMessage { ModelErrorMessage(summary: localizedDescription) } }

public struct ProviderIdentity: Sendable, Equatable {
    public let implementation: String, endpoint: URL
    public init(implementation: String, endpoint: URL) { self.implementation = implementation; self.endpoint = endpoint }
}
public struct ModelProgress: Sendable {
    public let responseID: String?, sequence: Int?, itemID: String?, outputIndex: Int?, contentIndex: Int?
    public let kind: String
    public init(responseID: String?, sequence: Int?, itemID: String?, outputIndex: Int?, contentIndex: Int?, kind: String) { self.responseID = responseID; self.sequence = sequence; self.itemID = itemID; self.outputIndex = outputIndex; self.contentIndex = contentIndex; self.kind = kind }
}
extension ModelProvider {
    public var identity: ProviderIdentity { .init(implementation: Self.name, endpoint: configuration.baseURL) }
    public func create(_ request: ModelRequest) async throws -> ModelResponse { try await complete(request) }
    public func capabilities(for model: String) async throws -> ProviderCapabilities { .init(responseChain: false) }
}
