import Foundation
import ProviderCore

public enum StopReason: String, Codable, Sendable { case user, backgroundExpired, superseded, hostShutdown }
public enum TurnStatus: String, Codable, Sendable { case completed, interrupted, failed }
public enum TurnFailure: Sendable, Equatable {
    case cancelled, storage, contextCapacity, contextCompression, protocolViolation, unsupportedCapability, hostFailure
    case provider(ModelError)
    case timeout(TimeInterval)
}
public struct TurnResult: Sendable, Equatable {
    public let turnID: UUID
    public let status: TurnStatus
    public let text: String
    public let error: String?
    public let failure: TurnFailure?
    public init(turnID: UUID, status: TurnStatus, text: String = "", error: String? = nil, failure: TurnFailure? = nil) { self.turnID = turnID; self.status = status; self.text = text; self.error = error; self.failure = failure }
}
public struct TurnInput: Sendable {
    public let itemID: UUID
    public let text: String
    public let images: [ModelImage]
    public init(itemID: UUID = UUID(), text: String, images: [ModelImage] = []) { self.itemID = itemID; self.text = text; self.images = images }
}
public struct SessionHandle: Sendable {
    public let id: UUID
    public let revision: Int
    public let context: [ModelInputItem]
    public init(id: UUID, revision: Int, context: [ModelInputItem]) { self.id = id; self.revision = revision; self.context = context }
}
public struct TurnHandle: Sendable {
    public let id: UUID
    public let events: AsyncStream<AgentRuntimeEvent>
    private let task: Task<TurnResult, Never>
    init(id: UUID, events: AsyncStream<AgentRuntimeEvent>, task: Task<TurnResult, Never>) { self.id = id; self.events = events; self.task = task }
    public func result() async -> TurnResult { await task.value }
}
public enum CompactionStrategy: String, Sendable { case automatic, native, portable }
public enum CompactionMethod: String, Sendable { case native, portable, unchanged }
public struct CompactionOutcome: Sendable, Equatable {
    public let method: CompactionMethod
    public let sourceRevision: Int
    public let targetRevision: Int
    public let beforeTokens: Int
    public let afterTokens: Int
    public init(method: CompactionMethod, sourceRevision: Int, targetRevision: Int, beforeTokens: Int, afterTokens: Int) {
        self.method = method; self.sourceRevision = sourceRevision; self.targetRevision = targetRevision; self.beforeTokens = beforeTokens; self.afterTokens = afterTokens
    }
}
public enum AgentRuntimeEvent: Sendable {
    case turnStarted(UUID)
    case inferenceStarted(Int)
    case responseCommitted(ModelResponse)
    case assistantDelta(itemID: UUID, text: String)
    case reasoningDelta(itemID: UUID, text: String)
    case assistantCommitted(DisplayItem)
    case toolPrepared(ToolInvocation)
    case toolStarted(ToolInvocation)
    case toolCompleted(ToolInvocation, ToolOutcome)
    case compactionStarted
    case compactionCompleted(CompactionOutcome)
    case resyncRequired(sequence: Int)
    case turnFinished(TurnResult)
}
public struct AgentConfiguration: Sendable {
    public static let defaultStageTimeout: TimeInterval = 180
    public let model: String
    public let instructions: String
    public let scope: ProviderReplayScope?
    public let storage: StoragePolicy
    public let budget: ContextBudget
    public let temperature: Double?
    public let maxOutputTokens: Int?
    public let reasoningEffort: ModelReasoningEffort?
    public let cacheKey: String?
    /// Optional host-selected inference budget; nil imposes no arbitrary task-turn limit.
    public let maximumInferences: Int?
    public let streamIdleTimeout: TimeInterval
    public let summaryTimeout: TimeInterval
    public let compactionTimeout: TimeInterval
    public let observationRetention: ObservationRetentionPolicy
    public init(model: String, instructions: String = "", scope: ProviderReplayScope? = nil, storage: StoragePolicy = .none,
                budget: ContextBudget = .init(), temperature: Double? = nil, maxOutputTokens: Int? = nil,
                reasoningEffort: ModelReasoningEffort? = nil, cacheKey: String? = nil, maximumInferences: Int? = nil, streamIdleTimeout: TimeInterval = AgentConfiguration.defaultStageTimeout,
                summaryTimeout: TimeInterval = AgentConfiguration.defaultStageTimeout, compactionTimeout: TimeInterval = AgentConfiguration.defaultStageTimeout, observationRetention: ObservationRetentionPolicy = .init()) {
        self.model = model; self.instructions = instructions; self.scope = scope; self.storage = storage; self.budget = budget
        self.temperature = temperature; self.maxOutputTokens = maxOutputTokens; self.reasoningEffort = reasoningEffort
        self.cacheKey = cacheKey; self.maximumInferences = maximumInferences.map { max(1, $0) }
        self.streamIdleTimeout = streamIdleTimeout.isFinite ? max(0.01, streamIdleTimeout) : Self.defaultStageTimeout
        self.summaryTimeout = summaryTimeout.isFinite ? max(0.01, summaryTimeout) : Self.defaultStageTimeout
        self.compactionTimeout = compactionTimeout.isFinite ? max(0.01, compactionTimeout) : Self.defaultStageTimeout
        self.observationRetention = observationRetention
    }
}
public enum AgentRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case busy, duplicateToolName(String), invalidTerminal(String), unsupportedCapability(String), contextCapacity, invalidSummary(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .busy: return "The session still has an active operation."
        case .duplicateToolName(let name): return "Duplicate tool name: \(name)"
        case .invalidTerminal(let reason): return "Invalid model terminal: \(reason)"
        case .unsupportedCapability(let feature): return "Unsupported provider capability: \(feature)"
        case .contextCapacity: return "The context exceeds the known input capacity."
        case .invalidSummary(let reason): return "Invalid context summary: \(reason)"
        case .cancelled: return "The operation was cancelled."
        }
    }
}
