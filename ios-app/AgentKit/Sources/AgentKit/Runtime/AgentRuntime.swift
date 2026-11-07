import Foundation
import ProviderCore

/// A registry of independent, single-writer session engines. Hosts inject models and authorized tools.
public actor AgentRuntime {
    private let store: any SessionStore
    private let provider: any ModelProvider
    private let configuration: AgentConfiguration
    private let tools: [any AgentTool]
    private var sessions: [UUID: SessionEngine] = [:]
    public init(store: any SessionStore, provider: any ModelProvider, configuration: AgentConfiguration, tools: [any AgentTool] = []) {
        self.store = store; self.provider = provider; self.configuration = configuration; self.tools = tools
    }
    public func createSession(id: UUID = UUID()) async throws -> UUID {
        let engine = engine(id)
        try await engine.create()
        return id
    }
    public func loadSession(_ id: UUID) async throws -> SessionHandle { try await engine(id).load() }
    public func startTurn(in session: UUID, input: TurnInput, turnID: UUID = UUID()) async throws -> TurnHandle {
        try await engine(session).start(input: input, turnID: turnID)
    }
    public func cancelTurn(_ turn: UUID, reason: StopReason = .user) async {
        for engine in sessions.values { await engine.cancel(turn: turn, reason: reason) }
    }
    public func compactSession(_ session: UUID, strategy: CompactionStrategy = .automatic) async throws -> CompactionOutcome {
        try await engine(session).compact(strategy: strategy)
    }
    private func engine(_ id: UUID) -> SessionEngine {
        if let value = sessions[id] { return value }
        let value = SessionEngine(id: id, store: store, provider: provider, configuration: configuration, tools: tools)
        sessions[id] = value
        return value
    }
}

private actor SessionEngine {
    let id: UUID
    let store: any SessionStore
    let provider: any ModelProvider
    let configuration: AgentConfiguration
    let tools: [any AgentTool]
    var restored = RestoredContext()
    var active: UUID?
    var generation = UUID()
    var fence: ExecutionFence?
    var task: Task<TurnResult, Never>?
    var continuation: AsyncStream<AgentRuntimeEvent>.Continuation?
    var stopReason: StopReason?
    var lastFailedCompactionRevision: Int?
    init(id: UUID, store: any SessionStore, provider: any ModelProvider, configuration: AgentConfiguration, tools: [any AgentTool]) {
        self.id = id; self.store = store; self.provider = provider; self.configuration = configuration; self.tools = tools
    }
    var scope: ProviderReplayScope {
        configuration.scope ?? .init(provider: provider.identity.implementation, endpoint: provider.identity.endpoint.absoluteString,
                                     account: "default", model: configuration.model, session: id)
    }
    func create() async throws {
        guard active == nil else { throw AgentRuntimeError.busy }
        restored = try await store.loadContext(id)
        if restored.sequence == 0 { try await commit(.init(sessionID: id, kind: .sessionCreated)) }
    }
    func load() async throws -> SessionHandle {
        guard active == nil else { return .init(id: id, revision: restored.revision, context: restored.items) }
        let operation = UUID(); active = operation
        defer { active = nil }
        restored = try await store.loadContext(id)
        try await recoverMissingCompaction()
        try await closePendingCalls()
        return .init(id: id, revision: restored.revision, context: restored.items)
    }
    func start(input: TurnInput, turnID: UUID) async throws -> TurnHandle {
        guard active == nil else { throw AgentRuntimeError.busy }
        active = turnID; generation = UUID(); stopReason = nil
        let currentGeneration = generation, currentFence = ExecutionFence()
        fence = currentFence
        let (stream, sink) = AsyncStream<AgentRuntimeEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        continuation = sink
        let currentTask = Task { await self.run(input: input, turnID: turnID, generation: currentGeneration, fence: currentFence) }
        task = currentTask
        return .init(id: turnID, events: stream, task: currentTask)
    }
    func cancel(turn: UUID, reason: StopReason) async {
        guard active == turn else { return }
        // Fence first: cancellation is effective even if a network or host operation ignores Task cancellation.
        generation = UUID(); stopReason = reason
        await fence?.invalidate()
        task?.cancel()
    }
    func compact(strategy: CompactionStrategy) async throws -> CompactionOutcome {
        guard active == nil else { throw AgentRuntimeError.busy }
        active = UUID(); generation = UUID()
        let token = generation
        defer { active = nil }
        restored = try await store.loadContext(id)
        try await recoverMissingCompaction()
        try await closePendingCalls()
        try await ensureCompatibleScope()
        try await retainObservations(generation: token)
        return try await performCompaction(strategy: strategy, generation: token)
    }

    func run(input: TurnInput, turnID: UUID, generation token: UUID, fence currentFence: ExecutionFence) async -> TurnResult {
        var finalText = ""
        var assistantID = UUID(), previewText = "", previewReasoning = ""
        do {
            var names = Set<String>()
            for tool in tools { guard names.insert(tool.descriptor.name).inserted else { throw AgentRuntimeError.duplicateToolName(tool.descriptor.name) } }
            restored = try await store.loadContext(id)
            try await recoverMissingCompaction()
            try check(token)
            try await closePendingCalls()
            try await ensureCompatibleScope()
            try check(token)
            let images = try input.images.map(materialize)
            let userItem = ModelInputItem.message(role: .user, content: [.text(input.text)] + images.map(ModelInputContent.image))
            try await commit(.init(sessionID: id, turnID: turnID, kind: .turnStarted, contextItems: [userItem],
                                   displayItems: [.init(id: input.itemID, turnID: turnID, role: "user", text: input.text)]))
            emit(.turnStarted(turnID))
            var inferences = 0, performedRejectionRecovery = false, hasCommittedToolResult = false
            while true {
                try check(token)
                try await retainObservations(generation: token)
                if let limit = configuration.maximumInferences, inferences >= limit { throw AgentRuntimeError.invalidTerminal("host inference budget exhausted") }
                inferences += 1
                let estimate = estimate()
                if estimate.tokens + configuration.budget.outputReserve + configuration.budget.toolResultReserve >= configuration.budget.softThreshold,
                   lastFailedCompactionRevision != restored.revision {
                    do { _ = try await performCompaction(strategy: .automatic, generation: token) }
                    catch is CancellationError { throw CancellationError() }
                    catch { try check(token); lastFailedCompactionRevision = restored.revision }
                }
                try ContextProjection.validateClosedTools(restored.items)
                let capabilities = try await provider.capabilities(for: configuration.model)
                guard configuration.storage != .responseChain || capabilities.responseChain else { throw AgentRuntimeError.unsupportedCapability("response chain") }
                guard configuration.storage == .responseChain || capabilities.stateless else { throw AgentRuntimeError.unsupportedCapability("stateless requests") }
                emit(.inferenceStarted(inferences))
                let contextEpoch = restored.snapshot?.epoch ?? UUID()
                let requestEstimatedTokens = conservativeEstimate().tokens
                let inferenceID = UUID()
                var request = ModelRequest(model: configuration.model, messages: [], temperature: configuration.temperature,
                                           maxTokens: configuration.maxOutputTokens, tools: tools.map(\.descriptor).sorted { $0.name < $1.name }.map(\.modelDefinition),
                                           reasoningEffort: configuration.reasoningEffort, id: inferenceID)
                request.instructions = configuration.instructions; request.storage = configuration.storage
                request.ownership = .init(turn: turnID, inference: inferenceID, attempt: UUID())
                request.input = restored.items
                if configuration.storage == .responseChain, let snapshot = restored.snapshot, snapshot.scope == scope,
                   let head = snapshot.head, snapshot.headCoveredItemCount <= restored.items.count {
                    request.context = .previousResponse(.init(head, scope: scope))
                    request.input = Array(restored.items.dropFirst(snapshot.headCoveredItemCount))
                }
                request.cachePolicy = configuration.cacheKey.map { .init(key: $0) }
                try await commit(.init(sessionID: id, turnID: turnID, kind: .requestPrepared,
                                       metadata: .object(["inferenceID": .string(inferenceID.uuidString), "sourceRevision": .number(Double(restored.revision))])))
                try check(token)
                assistantID = UUID(); previewText = ""; previewReasoning = ""; finalText = ""
                var terminal: ModelResponse?
                let events = StageDeadline.stream(provider.stream(request), idleSeconds: configuration.streamIdleTimeout)
                do {
                for try await event in events {
                    try check(token)
                    switch event {
                    case .text(let text): previewText += text; emit(.assistantDelta(itemID: assistantID, text: text))
                    case .reasoning(let text): previewReasoning += text; emit(.reasoningDelta(itemID: assistantID, text: text))
                    case .terminal(let response):
                        guard terminal == nil else { throw AgentRuntimeError.invalidTerminal("multiple terminals") }
                        terminal = response
                    case .toolCall, .progress: break
                    case .finish: throw AgentRuntimeError.invalidTerminal("legacy finish is not authoritative")
                    case .error(let error): throw error
                    }
                }
                } catch ModelError.rejectedBeforeAcceptance(let reason) {
                    await events.cancel()
                    guard !performedRejectionRecovery else { throw ModelError.rejectedBeforeAcceptance(reason: reason) }
                    performedRejectionRecovery = true
                    switch reason {
                    case .invalidResponseHead:
                        guard case .previousResponse = request.context else { throw ModelError.rejectedBeforeAcceptance(reason: reason) }
                        try await commit(.init(sessionID: id, turnID: turnID, kind: .recovery, contextHead: .init(epoch: UUID(), scope: scope, responseID: nil, coveredItemCount: 0)))
                    case .contextCapacity:
                        let outcome = try await performCompaction(strategy: .automatic, generation: token)
                        guard outcome.method != .unchanged else { throw AgentRuntimeError.contextCapacity }
                    }
                    continue
                } catch { await events.cancel(); throw error }
                await events.cancel()
                try check(token)
                guard let response = terminal, response.status == .completed else { throw AgentRuntimeError.invalidTerminal("missing completed terminal") }
                guard !response.text.isEmpty || !response.toolCalls.isEmpty || hasCommittedToolResult else { throw AgentRuntimeError.invalidTerminal("empty response") }
                let contextIDs = Set(restored.items.compactMap { item -> String? in if case .replay(.functionCall(let call)) = item { return call.id }; return nil })
                let previousIDs = contextIDs.union(restored.callIDsByTurn[turnID] ?? [])
                try ToolBatchValidator.validate(response.toolCalls, previousCallIDs: previousIDs)
                var replay = try response.output.map { try $0.asReplayInput(scope: scope) }
                if let state = response.replayState {
                    _ = try state.reasoningDetailsForReplay(scope: scope)
                    replay.append(.chatReplayState(state))
                }
                let newItemCount = restored.items.count + replay.count
                var display: [DisplayItem] = []
                if !response.text.isEmpty || response.reasoning?.isEmpty == false {
                    display.append(.init(id: assistantID, turnID: turnID, role: "assistant", text: response.text,
                                         metadata: response.reasoning.map { .object(["reasoning": .string($0)]) }))
                }
                for call in response.toolCalls {
                    let invocation = ToolInvocation(sessionID: id, turnID: turnID, call: call)
                    display.append(.init(id: invocation.displayItemID, turnID: turnID, role: "tool", text: call.name, state: "prepared", metadata: .object(["callID": .string(call.id), "name": .string(call.name), "rawArguments": .string(call.arguments)])))
                }
                let head = ContextHead(epoch: contextEpoch, scope: scope,
                                       responseID: configuration.storage == .responseChain ? response.id : nil,
                                       coveredItemCount: configuration.storage == .responseChain ? newItemCount : 0)
                try await commit(.init(sessionID: id, turnID: turnID, kind: .modelOutput, contextItems: replay,
                                       displayItems: display, usage: response.usage, contextHead: head,
                                       metadata: .object(["requestEstimateTokens": .number(Double(requestEstimatedTokens)), "contextEpoch": .string(contextEpoch.uuidString)])))
                try check(token)
                for item in display where item.role != "tool" { emit(.assistantCommitted(item)) }
                emit(.responseCommitted(response))
                for call in response.toolCalls { emit(.toolPrepared(.init(sessionID: id, turnID: turnID, call: call))) }
                finalText = response.text
                if response.toolCalls.isEmpty { break }
                var stopBatch = false, requestedFinish = false, finishText = ""
                for call in response.toolCalls {
                    try check(token)
                    let invocation = ToolInvocation(sessionID: id, turnID: turnID, call: call)
                    if stopBatch {
                        try await record(invocation, outcome: .init(kind: .cancelledBeforeDispatch, content: "The preceding tool ended this batch."))
                        continue
                    }
                    // Claim is durable before the host gets authorization or any chance to send an effect.
                    try await commit(.init(sessionID: id, turnID: turnID, kind: .toolClaimed, toolClaims: [call.id]))
                    try check(token)
                    emit(.toolStarted(invocation))
                    let outcome: ToolOutcome
                    var hostCancelled = false
                    if let tool = tools.first(where: { $0.descriptor.name == call.name }) {
                        do {
                            let context = ToolExecutionContext(sessionID: id, turnID: turnID, generation: token, fence: currentFence)
                            try await context.checkCancellation()
                            outcome = try await tool.execute(invocation, context: context)
                        } catch is CancellationError {
                            hostCancelled = true
                            await currentFence.invalidate()
                            outcome = .init(kind: .outcomeUnknown, content: "Execution was interrupted after the runtime claim; delivery must be established by the host checkpoint.")
                        }
                        catch { outcome = .init(kind: .infrastructureFailure, content: error.localizedDescription) }
                    } else { outcome = .init(kind: .validationFailed, content: "No registered tool named \(call.name).") }
                    // A completed host operation is still a fact after cancellation. Persist it, but never dispatch another effect.
                    try await record(invocation, outcome: outcome)
                    hasCommittedToolResult = true
                    if hostCancelled { throw CancellationError() }
                    try check(token)
                    stopBatch = outcome.stopsBatch || outcome.finishTurn
                    if outcome.finishTurn { requestedFinish = true; finishText = outcome.content }
                }
                if requestedFinish { finalText = finishText; break }
                if stopBatch { throw CancellationError() }
            }
            try check(token)
            try await commit(.init(sessionID: id, turnID: turnID, kind: .turnEnded))
            return finish(.init(turnID: turnID, status: .completed, text: finalText))
        } catch {
            let cancelled = error is CancellationError || token != generation || stopReason != nil
            // Recovery closes all committed calls; it never invokes the host executor.
            try? await closePendingCalls()
            if restored.snapshot?.head != nil {
                try? await commit(.init(sessionID: id, turnID: turnID, kind: .recovery, contextHead: .init(epoch: UUID(), scope: scope, responseID: nil, coveredItemCount: 0)))
            }
            var interrupted: [DisplayItem] = []
            if !previewText.isEmpty || !previewReasoning.isEmpty {
                interrupted.append(.init(id: assistantID, turnID: turnID, role: "assistant", text: previewText, state: cancelled ? "interrupted" : "failed",
                                         metadata: previewReasoning.isEmpty ? nil : .object(["reasoning": .string(previewReasoning)])))
            }
            try? await commit(.init(sessionID: id, turnID: turnID, kind: .turnInterrupted, displayItems: interrupted))
            return finish(.init(turnID: turnID, status: cancelled ? .interrupted : .failed, text: finalText, error: error.localizedDescription, failure: classify(error, cancelled: cancelled)))
        }
    }

    func recoverMissingCompaction() async throws {
        guard restored.recoveredCompactionMissing else { return }
        try await commit(.init(sessionID: id, kind: .recovery, snapshot: .init(scope: restored.snapshot?.scope, items: restored.items, preservedNativeItemCount: restored.snapshot?.preservedNativeItemCount ?? 0)))
        restored.recoveredCompactionMissing = false
    }
    func ensureCompatibleScope() async throws {
        if let existing = restored.snapshot?.scope, existing != scope {
            let facts = try await store.readContextFacts(id)
            let portable = ContextProjection.portableItems(from: facts)
            try ContextProjection.validateClosedTools(portable)
            try await commit(.init(sessionID: id, kind: .recovery, snapshot: .init(scope: scope, items: portable)))
        }
    }
    func conservativeEstimate() -> TokenEstimate {
        ContextEstimator.estimate(items: restored.items, instructions: configuration.instructions,
                                  tools: tools.map(\.descriptor).sorted { $0.name < $1.name }.map(\.modelDefinition), revision: restored.revision)
    }
    func estimate() -> TokenEstimate {
        let coarse = conservativeEstimate()
        guard let measured = restored.lastInputTokens, let baseline = restored.lastInputEstimate,
              restored.calibrationEpoch == restored.snapshot?.epoch else { return coarse }
        let growth = max(0, coarse.tokens - baseline)
        let (calibrated, overflow) = measured.addingReportingOverflow(growth)
        guard !overflow, calibrated <= Int.max / 2 else { return coarse }
        let margin = max(coarse.safetyMargin, calibrated / 10)
        return .init(tokens: calibrated + margin, method: .usageCalibrated, revision: restored.revision, safetyMargin: margin)
    }
    func retainObservations(generation token: UUID) async throws {
        guard restored.pendingCalls.isEmpty else { return }
        let preserved = restored.snapshot?.preservedNativeItemCount ?? 0
        guard let candidate = ObservationRetention.candidate(items: restored.items, preservedNativeItemCount: preserved, policy: configuration.observationRetention) else { return }
        try check(token)
        try ContextProjection.validateClosedTools(candidate.items)
        try await commit(.init(sessionID: id, turnID: active, kind: .recovery,
                               snapshot: .init(scope: scope, items: candidate.items, preservedNativeItemCount: preserved),
                               metadata: .object(["reason": .string("observationRetention"), "removedObservationGroups": .number(Double(candidate.removedGroupCount)), "removedImageBytes": .number(Double(candidate.removedBytes))])))
        try check(token)
    }
    func performCompaction(strategy: CompactionStrategy, generation token: UUID) async throws -> CompactionOutcome {
        try check(token)
        let sourceRevision = restored.revision, before = estimate().tokens
        let compactionID = UUID()
        guard restored.pendingCalls.isEmpty else { throw AgentRuntimeError.invalidSummary("pending tool calls") }
        emit(.compactionStarted)
        try await commit(.init(sessionID: id, turnID: active, kind: .compactionStarted,
                               metadata: .object(["sourceRevision": .number(Double(sourceRevision)), "strategy": .string(strategy.rawValue), "compactionID": .string(compactionID.uuidString), "coveredThroughSequence": .number(Double(restored.sequence))])))
        let needsPublicRebuild = restored.items.contains { if case .replay(.compaction) = $0 { return true }; return false }
        let facts = needsPublicRebuild ? try await store.readContextFacts(id) : []
        let candidate = try await ContextCompressor.candidate(items: restored.items, transactions: facts, scope: scope,
                                                              provider: provider, configuration: configuration, strategy: strategy)
        try check(token)
        guard restored.revision == sourceRevision else { throw AgentRuntimeError.invalidSummary("source revision changed") }
        guard let candidate else {
            let unchanged = CompactionOutcome(method: .unchanged, sourceRevision: sourceRevision, targetRevision: sourceRevision, beforeTokens: before, afterTokens: before)
            emit(.compactionCompleted(unchanged)); return unchanged
        }
        let after = ContextEstimator.estimate(items: candidate.items, instructions: configuration.instructions, tools: tools.map(\.descriptor).map(\.modelDefinition)).tokens
        guard after < before else { throw AgentRuntimeError.invalidSummary("candidate does not reduce the request") }
        try await commit(.init(sessionID: id, turnID: active, kind: .contextCompacted, usage: candidate.usage,
                               snapshot: .init(scope: scope, items: candidate.items, preservedNativeItemCount: candidate.method == .native ? candidate.items.count : 0),
                               metadata: .object(["sourceRevision": .number(Double(sourceRevision)), "method": .string(candidate.method.rawValue), "compactionID": .string(compactionID.uuidString)])))
        let outcome = CompactionOutcome(method: candidate.method, sourceRevision: sourceRevision, targetRevision: restored.revision, beforeTokens: before, afterTokens: after)
        emit(.compactionCompleted(outcome)); return outcome
    }
    func closePendingCalls() async throws {
        let calls = restored.pendingCalls
        for pending in calls {
            let invocation = ToolInvocation(sessionID: id, turnID: pending.turnID, call: pending.call)
            let outcome = ToolOutcome(kind: pending.claimed ? .outcomeUnknown : .cancelledBeforeDispatch,
                                      content: pending.claimed ? "Recovered a claimed call without a durable result. It was not replayed; consult the host delivery checkpoint." : "Recovered a prepared call that was never dispatched. It was not replayed.")
            try await record(invocation, outcome: outcome, recovery: true)
        }
    }
    func record(_ invocation: ToolInvocation, outcome: ToolOutcome, recovery: Bool = false) async throws {
        // A tool result is a complete protocol value, including structured JSON.
        // Context budgeting may compact history, but must never clip this value.
        var context: [ModelInputItem] = [.functionResult(callID: invocation.callID, output: outcome.modelContent)]
        let images = try outcome.images.map(materialize)
        let durableOutcome = ToolOutcome(kind: outcome.kind, content: outcome.content, images: images, finishTurn: outcome.finishTurn)
        if !images.isEmpty { context.append(.message(role: .user, content: images.map(ModelInputContent.image))) }
        let item = DisplayItem(id: invocation.displayItemID, turnID: invocation.turnID, role: "tool", text: outcome.content,
                               state: outcome.kind.rawValue, metadata: .object(["callID": .string(invocation.callID), "name": .string(invocation.name), "rawArguments": .string(invocation.rawArguments), "outcome": .string(outcome.kind.rawValue)]))
        try await commit(.init(sessionID: id, turnID: invocation.turnID, kind: recovery ? .recovery : .toolResult,
                               contextItems: context, displayItems: [item], toolResults: [.init(turnID: invocation.turnID, callID: invocation.callID, outcome: durableOutcome)]))
        if !recovery { emit(.toolCompleted(invocation, durableOutcome)) }
    }
    func commit(_ transaction: SessionTransaction) async throws {
        let receipt = try await store.append(transaction, expecting: restored.revision)
        restored.revision = receipt.revision; restored.sequence = receipt.sequence
        if let snapshot = transaction.snapshot { restored.snapshot = snapshot; restored.items = snapshot.items }
        else { restored.items += transaction.contextItems }
        if let head = transaction.contextHead {
            restored.snapshot = .init(epoch: head.epoch, scope: head.scope, items: restored.snapshot?.items ?? [], head: head.responseID, headCoveredItemCount: head.coveredItemCount, preservedNativeItemCount: restored.snapshot?.preservedNativeItemCount ?? 0)
        }
        if restored.calibrationEpoch != restored.snapshot?.epoch {
            restored.lastInputTokens = nil; restored.lastInputEstimate = nil; restored.calibrationEpoch = nil
        }
        if transaction.kind == .modelOutput, let inputTokens = transaction.usage?.promptTokens,
           case .object(let metadata) = transaction.metadata, case .number(let baseline) = metadata["requestEstimateTokens"],
           case .string(let rawEpoch) = metadata["contextEpoch"], let epoch = UUID(uuidString: rawEpoch),
           baseline.isFinite, baseline >= 0, baseline < Double(Int.max), inputTokens >= 0 {
            restored.lastInputTokens = inputTokens; restored.lastInputEstimate = Int(baseline); restored.calibrationEpoch = epoch
        }
        if let usage = transaction.usage { restored.usage.append(usage) }
        for item in transaction.contextItems { if case .replay(.functionCall(let call)) = item, let turn = transaction.turnID { restored.pendingCalls.append(.init(turnID: turn, call: call, claimed: false)); restored.callIDsByTurn[turn, default: []].insert(call.id) } }
        for callID in transaction.toolClaims {
            if let index = restored.pendingCalls.firstIndex(where: { $0.call.id == callID && $0.turnID == transaction.turnID }) { restored.pendingCalls[index].claimed = true }
        }
        for result in transaction.toolResults { restored.pendingCalls.removeAll { $0.turnID == result.turnID && $0.call.id == result.callID } }
    }
    func classify(_ error: any Error, cancelled: Bool) -> TurnFailure {
        if cancelled { return .cancelled }
        if let provider = error as? ModelError { return .provider(provider) }
        if let timeout = error as? ModelStreamStalled { return .timeout(timeout.seconds) }
        if error is StoreError { return .storage }
        if let error = error as? AgentRuntimeError {
            switch error {
            case .contextCapacity: return .contextCapacity
            case .invalidSummary: return .contextCompression
            case .unsupportedCapability: return .unsupportedCapability
            case .cancelled: return .cancelled
            case .invalidTerminal, .duplicateToolName: return .protocolViolation
            case .busy: return .hostFailure
            }
        }
        return .hostFailure
    }
    func materialize(_ image: ModelImage) throws -> ModelImage {
        var copy = ModelImage(data: try image.bytes(), mimeType: image.mimeType)
        copy.observationID = image.observationID; copy.width = image.width; copy.height = image.height
        return copy
    }
    func check(_ token: UUID) throws { try Task.checkCancellation(); guard token == generation else { throw CancellationError() } }
    func emit(_ event: AgentRuntimeEvent) {
        guard let continuation else { return }
        if case .dropped = continuation.yield(event) { _ = continuation.yield(.resyncRequired(sequence: restored.sequence)) }
    }
    func finish(_ result: TurnResult) -> TurnResult {
        emit(.turnFinished(result)); continuation?.finish(); continuation = nil
        active = nil; task = nil; fence = nil
        return result
    }
}
