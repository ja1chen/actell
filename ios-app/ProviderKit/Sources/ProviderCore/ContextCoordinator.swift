import Foundation
import CryptoKit

/// Separate from the device action journal. These checkpoints never authorize
/// automatic action resumption after a process restart.
public struct ProviderRunCheckpoint: Codable, Sendable {
    public var version = 1
    public let scope: ProviderScope
    public var revision = 0
    public var head: ScopedResponseID?
    public var replay: [ModelInputItem] = []
    public var messageDigests: [String] = []
    public var expectedAssistant: ModelMessage?
    public var pendingCalls: [ModelToolCall] = []
    public var cancelEpoch = 0
    public var responseEventHistory: [ProviderResponseEvents]?
}
public struct StreamCheckpoint: Codable, Sendable {
    public var version = 1
    public var scope: ProviderScope?
    public let responseID: String?
    public let sequence: Int?
    public let terminal: ResponseStatus?
    public var itemIDs: [Int: String] = [:]
    public var completedItems: [Int: ModelOutputItem] = [:]
    public var contentPreviews: [String: String] = [:]
    public var argumentPreviews: [String: String] = [:]
    public var events: [ProviderStreamEvent]?
    public init(responseID: String?, sequence: Int?, terminal: ResponseStatus?) { self.responseID = responseID; self.sequence = sequence; self.terminal = terminal }
}
public struct PreparedContext: Sendable { public let request: ModelRequest; public let revision: Int; public let cancelEpoch: Int; fileprivate let digests: [String]; fileprivate let replay: [ModelInputItem] }
/// One coordinator per run/branch, owned by runtime, never by the SDK client.
/// A revision CAS rejects concurrent generations; durable save precedes head publication.
public final class ContextCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    public let scope: ProviderScope
    public let storage: StoragePolicy
    private let file: URL?
    private var checkpoint: ProviderRunCheckpoint
    public init(scope: ProviderScope, storage: StoragePolicy = .none, checkpointFile: URL? = nil) throws {
        self.scope = scope; self.storage = storage; self.file = checkpointFile
        checkpoint = ProviderRunCheckpoint(scope: scope)
        if let file = checkpointFile, FileManager.default.fileExists(atPath: file.path) {
            let restored = try JSONDecoder().decode(ProviderRunCheckpoint.self, from: Data(contentsOf: file))
            guard restored.version == 1, restored.scope == scope else { throw ModelError.protocolViolation("Provider checkpoint scope/version mismatch") }
            // Existing device journal decides recovery; this handle alone must never resume.
            guard restored.cancelEpoch == 0 else { throw ModelError.cancelledLocally }; checkpoint = restored
        }
    }
    public func snapshot() -> ProviderRunCheckpoint { lock.withLock { checkpoint } }
    public func prepare(_ original: ModelRequest) throws -> PreparedContext {
        try lock.withLock {
            guard checkpoint.cancelEpoch == 0 else { throw ModelError.cancelledLocally }
            guard original.model == scope.model else { throw ModelError.protocolViolation("Model scope mismatch") }
            guard original.input == nil, original.context == .stateless, original.storage == .none else {
                throw ModelError.invalidRequest("Runtime message coordinator requires portable messages; explicit native context belongs at the wire adapter boundary")
            }
            var request = original
            request.instructions = original.instructions ?? original.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
            let messages = original.messages.filter { $0.role != .system }
            let digests = try messages.map(Self.digest)
            var consumed = checkpoint.messageDigests.count
            if consumed > 0 {
                guard digests.count > consumed, Array(digests.prefix(consumed)) == checkpoint.messageDigests,
                      let expected = checkpoint.expectedAssistant, Self.matches(messages[consumed], expected) else {
                    throw ModelError.protocolViolation("上下文已改变；不能静默剪链或重放动作，请开始新的任务")
                }
                consumed += 1
            }
            let incoming = try Self.input(messages: Array(messages.dropFirst(consumed)))
            // Validate correlation even if an old screenshot has been removed.
            let results = Set(incoming.compactMap { if case .functionResult(let id, _) = $0 { return id }; return nil })
            guard Set(checkpoint.pendingCalls.map(\.id)).isSubset(of: results) else { throw ModelError.protocolViolation("Missing tool results for committed response") }
            request.storage = storage
            request.context = checkpoint.head.map(ContextMode.previousResponse) ?? .stateless
            let allReplay = Self.pruneDeviceImages(checkpoint.replay + incoming)
            if storage == .none { request.context = .stateless; request.input = allReplay }
            else { request.input = incoming }
            return PreparedContext(request: request, revision: checkpoint.revision, cancelEpoch: checkpoint.cancelEpoch, digests: digests, replay: allReplay)
        }
    }
    public func commit(_ response: ModelResponse, prepared: PreparedContext) throws {
        try lock.withLock {
            guard checkpoint.cancelEpoch == prepared.cancelEpoch, checkpoint.cancelEpoch == 0 else { throw ModelError.cancelledLocally }
            guard checkpoint.revision == prepared.revision else { throw ModelError.protocolViolation("Branch revision conflict") }
            guard response.scope == scope else { throw ModelError.protocolViolation("Response commit scope mismatch") }
            guard response.status == .completed else { throw ModelError.protocolViolation("Only completed output can advance head") }
            try ToolBatchValidator.validate(response.toolCalls, previousCallIDs: Set(checkpoint.replay.compactMap { if case .replay(.functionCall(let c)) = $0 { return c.id }; return nil }))
            var next = checkpoint
            guard response.streamEvents.allSatisfy({ $0.responseID == response.id }) else { throw ModelError.protocolViolation("Response scope changed") }
            if !response.streamEvents.isEmpty {
                var history = Array(((next.responseEventHistory ?? []) + [ProviderResponseEvents(responseID: response.id, events: response.streamEvents)]).suffix(16))
                while try JSONEncoder().encode(history).count > 2 * 1024 * 1024, history.count > 1 { history.removeFirst() }
                guard try JSONEncoder().encode(history).count <= 2 * 1024 * 1024 else { throw ModelError.protocolViolation("Stream extension limit") }
                next.responseEventHistory = history
            }
            next.replay = prepared.replay + (try response.output.map { try $0.asReplayInput(scope: scope) })
            // Keep tool/text dependencies; remove old device image bytes, retaining
            // user attachments. Chain mode's remote history is unaffected by this.
            next.replay = Self.pruneDeviceImages(next.replay)
            next.head = storage == .responseChain ? ScopedResponseID(response.id, scope: scope) : nil
            next.messageDigests = prepared.digests
            next.expectedAssistant = .assistant(content: response.text, toolCalls: response.toolCalls)
            next.pendingCalls = response.toolCalls; next.revision += 1
            try save(next); checkpoint = next
        }
    }
    public func cancel() throws {
        try lock.withLock {
            checkpoint.cancelEpoch += 1 // Preserve evidence; also fence in memory if saving fails.
            try save(checkpoint)
        }
    }
    public func recordStream(_ stream: StreamCheckpoint, force: Bool = false) throws {
        try lock.withLock {
            guard checkpoint.cancelEpoch == 0 else { throw ModelError.cancelledLocally }
            guard stream.scope == scope else { throw ModelError.protocolViolation("Response scope changed") }
            guard force || stream.terminal != nil || (stream.sequence ?? 1) % 32 == 0 else { return }
            guard let file else { return }
            let destination = file.deletingPathExtension().appendingPathExtension("stream.json")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try JSONEncoder().encode(stream).write(to: destination, options: [.atomic, .completeFileProtection])
            #else
            try JSONEncoder().encode(stream).write(to: destination, options: .atomic)
            #endif
        }
    }
    private func save(_ value: ProviderRunCheckpoint) throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        #endif
    }
    private static func digest(_ message: ModelMessage) throws -> String {
        var hash = SHA256()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var portable = message; portable.images = []
        hash.update(data: try encoder.encode(portable))
        // Device observation bytes are intentionally pruned by runtime afterTool.
        // Receipt/call identity remains fixed; user attachments must remain exact.
        for image in message.role == .user ? message.images : [] {
            hash.update(data: Data(image.mimeType.utf8))
            hash.update(data: try image.bytes())
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func matches(_ m: ModelMessage, _ expected: ModelMessage) -> Bool { m.role == .assistant && m.content == expected.content && (m.toolCalls ?? []).map { $0.id } == (expected.toolCalls ?? []).map { $0.id } }
    public static func input(messages: [ModelMessage]) throws -> [ModelInputItem] {
        var result: [ModelInputItem] = []
        let lastDevice = messages.lastIndex { $0.role != .user && !$0.images.isEmpty }
        for (index, message) in messages.enumerated() {
            if message.role == .system { continue }
            if message.role == .tool {
                guard let id = message.toolCallId, !id.isEmpty else { throw ModelError.invalidRequest("Tool result missing call ID") }
                result.append(.functionResult(callID: id, output: message.content))
                if index == lastDevice { result.append(.message(role: .tool, content: message.images.map(ModelInputContent.image))) }
            } else {
                if !message.content.isEmpty || !message.images.isEmpty {
                    result.append(.message(role: message.role, content: [.text(message.content)] + message.images.map(ModelInputContent.image)))
                }
                for call in message.toolCalls ?? [] { result.append(.replay(.functionCall(call))) }
            }
        }
        return result
    }
    private static func pruneDeviceImages(_ input: [ModelInputItem]) -> [ModelInputItem] {
        let last = input.lastIndex { if case .message(role: .tool, _) = $0 { return true }; return false }
        return input.enumerated().compactMap { i, item in
            if case .message(role: .tool, _) = item, i != last { return nil }; return item
        }
    }
}
