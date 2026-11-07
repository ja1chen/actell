import Foundation
import CryptoKit
import ProviderCore

public enum TransactionKind: String, Codable, Sendable {
    case sessionCreated, sessionUpdated, presentationUpdated, turnStarted, requestPrepared, modelOutput, toolClaimed, toolResult, turnEnded, turnInterrupted, compactionStarted, contextCompacted, recovery, legacyImported
}

public struct DisplayItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var turnID: UUID?
    public var role: String
    public var text: String
    public var state: String
    public var createdAt: Date?
    /// App-owned, presentation-only data; never model input or authorization.
    public var metadata: JSONValue?
    public init(id: UUID = UUID(), turnID: UUID? = nil, role: String, text: String, state: String = "complete", metadata: JSONValue? = nil, createdAt: Date? = nil) {
        self.id = id; self.turnID = turnID; self.role = role; self.text = text; self.state = state; self.metadata = metadata; self.createdAt = createdAt
    }
}

public struct ToolResultRecord: Codable, Sendable, Equatable {
    public var turnID: UUID
    public var callID: String
    public var outcome: ToolOutcome
    public init(turnID: UUID, callID: String, outcome: ToolOutcome) {
        self.turnID = turnID; self.callID = callID; self.outcome = outcome
    }
}
public struct PendingToolCall: Sendable, Equatable {
    public var turnID: UUID
    public var call: ModelToolCall
    public var claimed: Bool
    public init(turnID: UUID, call: ModelToolCall, claimed: Bool) { self.turnID = turnID; self.call = call; self.claimed = claimed }
}
public struct ContextSnapshot: Sendable, Equatable {
    public var epoch: UUID
    public var scope: ProviderScope?
    public var items: [ModelInputItem]
    public var head: String?
    public var headCoveredItemCount: Int
    public var preservedNativeItemCount: Int
    public init(epoch: UUID = UUID(), scope: ProviderScope? = nil, items: [ModelInputItem], head: String? = nil, headCoveredItemCount: Int = 0, preservedNativeItemCount: Int = 0) {
        self.epoch = epoch; self.scope = scope; self.items = items; self.head = head; self.headCoveredItemCount = headCoveredItemCount; self.preservedNativeItemCount = preservedNativeItemCount
    }
}
public struct ContextHead: Codable, Sendable, Equatable {
    public var epoch: UUID
    public var scope: ProviderScope
    public var responseID: String?
    public var coveredItemCount: Int
    public init(epoch: UUID, scope: ProviderScope, responseID: String?, coveredItemCount: Int) {
        self.epoch = epoch; self.scope = scope; self.responseID = responseID; self.coveredItemCount = coveredItemCount
    }
}
public struct SessionTransaction: Sendable, Equatable {
    public var id: UUID
    public var sessionID: UUID
    public var turnID: UUID?
    public var kind: TransactionKind
    public var createdAt: Date
    public var contextItems: [ModelInputItem]
    public var displayItems: [DisplayItem]
    public var usage: ModelUsage?
    public var snapshot: ContextSnapshot?
    public var contextHead: ContextHead?
    public var toolClaims: [String]
    public var toolResults: [ToolResultRecord]
    public var metadata: JSONValue?
    public var removedDisplayItemIDs: [UUID]
    public init(id: UUID = UUID(), sessionID: UUID, turnID: UUID? = nil, kind: TransactionKind, createdAt: Date = Date(),
                contextItems: [ModelInputItem] = [], displayItems: [DisplayItem] = [], usage: ModelUsage? = nil,
                snapshot: ContextSnapshot? = nil, contextHead: ContextHead? = nil, toolClaims: [String] = [], toolResults: [ToolResultRecord] = [], metadata: JSONValue? = nil, removedDisplayItemIDs: [UUID] = []) {
        self.id = id; self.sessionID = sessionID; self.turnID = turnID; self.kind = kind; self.createdAt = createdAt; self.contextItems = contextItems
        self.displayItems = displayItems; self.usage = usage; self.snapshot = snapshot; self.contextHead = contextHead; self.toolClaims = toolClaims; self.toolResults = toolResults
        self.metadata = metadata; self.removedDisplayItemIDs = removedDisplayItemIDs
    }
}
public struct CommitReceipt: Sendable, Equatable {
    public var sequence: Int
    public var revision: Int
    public init(sequence: Int, revision: Int) { self.sequence = sequence; self.revision = revision }
}
public struct HistoryQuery: Sendable {
    public var sessionID: UUID
    public var beforeSequence: Int?
    public var limit: Int
    public init(sessionID: UUID, beforeSequence: Int? = nil, limit: Int = 50) { self.sessionID = sessionID; self.beforeSequence = beforeSequence; self.limit = limit }
}
public struct HistoryPage: Sendable {
    public var items: [DisplayItem]
    public var nextBeforeSequence: Int?
    /// The verified prefix is viewable, but continuation and append are unsafe.
    public var integrityGap: Bool
    public init(items: [DisplayItem], nextBeforeSequence: Int?, integrityGap: Bool = false) { self.items = items; self.nextBeforeSequence = nextBeforeSequence; self.integrityGap = integrityGap }
}
/// A verified session-local image, without retaining image bytes in the display cache.
public struct SessionImageReference: Sendable, Equatable {
    public let digest: String
    public let byteCount: Int
    public let mimeType: String
    public let width: Int?
    public let height: Int?
    public init(image: ModelImage) {
        digest = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
        byteCount = image.data.count; mimeType = image.mimeType
        width = image.width; height = image.height
    }
}
public struct SessionPresentation: Sendable {
    public var metadata: JSONValue?
    public var items: [DisplayItem]
    public var sequence: Int
    public var revision: Int
    public var integrityGap: Bool
    public var recoveredTail: Bool
    public var protectedDisplayItemIDs: Set<UUID>
    public var toolImages: [UUID: [SessionImageReference]]
    public init(metadata: JSONValue?, items: [DisplayItem], sequence: Int, revision: Int, integrityGap: Bool, recoveredTail: Bool = false, protectedDisplayItemIDs: Set<UUID> = [], toolImages: [UUID: [SessionImageReference]] = [:]) {
        self.metadata = metadata; self.items = items; self.sequence = sequence; self.revision = revision; self.integrityGap = integrityGap; self.recoveredTail = recoveredTail; self.protectedDisplayItemIDs = protectedDisplayItemIDs; self.toolImages = toolImages
    }
}
public struct RestoredContext: Sendable {
    public var revision: Int
    public var sequence: Int
    public var snapshot: ContextSnapshot?
    public var items: [ModelInputItem]
    public var pendingCalls: [PendingToolCall]
    public var callIDsByTurn: [UUID: Set<String>]
    public var recoveredCompactionMissing: Bool
    public var lastInputTokens: Int?
    public var lastInputEstimate: Int?
    public var calibrationEpoch: UUID?
    public var usage: [ModelUsage]
    public init(revision: Int = 0, sequence: Int = 0, snapshot: ContextSnapshot? = nil, items: [ModelInputItem] = [], pendingCalls: [PendingToolCall] = [], callIDsByTurn: [UUID: Set<String>] = [:], recoveredCompactionMissing: Bool = false, lastInputTokens: Int? = nil, lastInputEstimate: Int? = nil, calibrationEpoch: UUID? = nil, usage: [ModelUsage] = []) {
        self.revision = revision; self.sequence = sequence; self.snapshot = snapshot; self.items = items; self.pendingCalls = pendingCalls; self.callIDsByTurn = callIDsByTurn; self.recoveredCompactionMissing = recoveredCompactionMissing; self.lastInputTokens = lastInputTokens; self.lastInputEstimate = lastInputEstimate; self.calibrationEpoch = calibrationEpoch; self.usage = usage
    }
}
public protocol SessionStore: Sendable {
    func append(_ transaction: SessionTransaction, expecting revision: Int) async throws -> CommitReceipt
    func readPage(_ query: HistoryQuery) async throws -> HistoryPage
    func loadContext(_ sessionID: UUID) async throws -> RestoredContext
    /// Read complete authoritative facts independently of the lightweight context projection.
    func readTransactions(_ sessionID: UUID) async throws -> [SessionTransaction]
    /// Public reconstruction facts; an implementation may omit verified context-only snapshots, but must retain every mandatory fact.
    func readContextFacts(_ sessionID: UUID) async throws -> [SessionTransaction]
}
public extension SessionStore {
    func readContextFacts(_ sessionID: UUID) async throws -> [SessionTransaction] { try await readTransactions(sessionID) }
}
