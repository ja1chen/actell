import Foundation
import XCTest
import AgentKit
import ProviderCore

private actor RuntimeFixtureProvider: ModelCompactingProvider {
    nonisolated static let name = "runtime-fixture"
    nonisolated let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://example.invalid/v1")!, defaultModel: "fixture")
    enum Step: Sendable { case text(String), tools([ModelToolCall]), eof, duplicateTerminal, failure, rejected(ModelRejectionReason), stall, burst(Int) }
    var steps: [Step]
    var requests: [ModelRequest] = []
    var summaryRequests: [ModelRequest] = []
    var summaryGate: RuntimeGate?
    var invalidSummary = false
    var stalled: [AsyncThrowingStream<ModelEvent, Error>.Continuation] = []
    let chain: Bool
    let nativeScope: ProviderReplayScope?
    init(_ steps: [Step], chain: Bool = false, nativeScope: ProviderReplayScope? = nil) { self.steps = steps; self.chain = chain; self.nativeScope = nativeScope }
    func capabilities(for model: String) async throws -> ProviderCapabilities { .init(responseChain: chain, compaction: nativeScope != nil) }
    func compact(_ request: ModelCompactionRequest) async throws -> ModelCompactionResponse {
        guard let scope = nativeScope else { throw ModelError.unsupportedCapability("native compaction") }
        return .init(id: "compacted", scope: scope, input: [.replay(.compaction(.init(id: "memory", encryptedContent: "encrypted-memory", scope: scope)))])
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        summaryRequests.append(request)
        if let summaryGate { await summaryGate.wait() }
        XCTAssertTrue(request.tools.isEmpty)
        guard !invalidSummary else { return .init(text: "invalid-json", request: request, providerName: Self.name) }
        let prompt = request.input?.compactMap { item -> String? in if case .message(_, let parts) = item { return parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined() }; return nil }.joined() ?? ""
        let begin = prompt.range(of: "exactly [")!.upperBound
        let end = prompt[begin...].firstIndex(of: "]")!
        let ids = try JSONDecoder().decode([String].self, from: Data(("[" + prompt[begin..<end] + "]").utf8))
        let data = try JSONEncoder().encode(ContextMemory(summary: "Earlier goals and facts retained.", sourceItemIDs: ids))
        return .init(text: String(decoding: data, as: UTF8.self), request: request, providerName: Self.name)
    }
    nonisolated func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.deliver(request, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func deliver(_ request: ModelRequest, _ continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation) {
        requests.append(request)
        let step = steps.isEmpty ? .text("ok") : steps.removeFirst()
        switch step {
        case .text(let text):
            continuation.yield(.text("preview differs"))
            continuation.yield(.terminal(.init(text: text, request: request, providerName: Self.name)))
        case .tools(let calls):
            continuation.yield(.toolCall(.init(id: "preview-only", name: "must-not-execute", arguments: "{}")))
            continuation.yield(.terminal(.init(text: "", toolCalls: calls, request: request, providerName: Self.name)))
        case .eof: continuation.yield(.toolCall(.init(id: "orphan", name: "effect", arguments: "{}")))
        case .duplicateTerminal:
            let terminal = ModelEvent.terminal(.init(text: "bad", request: request, providerName: Self.name))
            continuation.yield(terminal); continuation.yield(terminal)
        case .failure: continuation.finish(throwing: ModelError.interrupted); return
        case .rejected(let reason): continuation.finish(throwing: ModelError.rejectedBeforeAcceptance(reason: reason)); return
        case .stall: stalled.append(continuation); return
        case .burst(let count):
            for _ in 0..<count { continuation.yield(.text("fragment")) }
            continuation.yield(.terminal(.init(text: "canonical-final", request: request, providerName: Self.name)))
        }
        continuation.finish()
    }
    func setSummaryGate(_ gate: RuntimeGate?) { summaryGate = gate }
    func setInvalidSummary(_ value: Bool) { invalidSummary = value }
    func inputs() -> [[ModelInputItem]] { requests.map { $0.input ?? [] } }
    func allRequests() -> [ModelRequest] { requests }
    func summaryCount() -> Int { summaryRequests.count }
}
private actor RuntimeGate {
    var waiting: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
    func hasEntered() -> Bool { entered }
}
private actor RuntimeToolLog {
    var calls: [String] = []
    func record(_ id: String) { calls.append(id) }
    func values() -> [String] { calls }
}
private actor RuntimeMemoryStore: SessionStore {
    private var transactions: [SessionTransaction] = []
    var failKind: TransactionKind?
    func setFailure(_ kind: TransactionKind?) { failKind = kind }
    func append(_ transaction: SessionTransaction, expecting revision: Int) async throws -> CommitReceipt {
        if transaction.kind == failKind { throw StoreError.io("injected") }
        let state = try await loadContext(transaction.sessionID)
        guard revision == state.revision else { throw StoreError.revisionConflict }
        transactions.append(transaction)
        return .init(sequence: transactions.count, revision: revision + ((!transaction.contextItems.isEmpty || transaction.snapshot != nil || transaction.contextHead != nil) ? 1 : 0))
    }
    func readPage(_ query: HistoryQuery) async throws -> HistoryPage {
        var items: [UUID: DisplayItem] = [:], order: [UUID] = []
        for transaction in transactions { for item in transaction.displayItems { if items[item.id] == nil { order.append(item.id) }; items[item.id] = item } }
        return .init(items: order.compactMap { items[$0] }, nextBeforeSequence: nil)
    }
    func readTransactions(_ sessionID: UUID) async throws -> [SessionTransaction] { transactions }
    func loadContext(_ sessionID: UUID) async throws -> RestoredContext {
        var state = RestoredContext()
        for t in transactions {
            if let snapshot = t.snapshot { state.snapshot = snapshot; state.items = snapshot.items } else { state.items += t.contextItems }
            if let head = t.contextHead { state.snapshot = .init(epoch: head.epoch, scope: head.scope, items: state.snapshot?.items ?? [], head: head.responseID, headCoveredItemCount: head.coveredItemCount, preservedNativeItemCount: state.snapshot?.preservedNativeItemCount ?? 0) }
            if !t.contextItems.isEmpty || t.snapshot != nil || t.contextHead != nil { state.revision += 1 }
            if let turn = t.turnID {
                for item in t.contextItems { if case .replay(.functionCall(let call)) = item { state.pendingCalls.append(.init(turnID: turn, call: call, claimed: false)); state.callIDsByTurn[turn, default: []].insert(call.id) } }
                for id in t.toolClaims { if let index = state.pendingCalls.firstIndex(where: { $0.call.id == id && $0.turnID == turn }) { state.pendingCalls[index].claimed = true } }
            }
            for result in t.toolResults { state.pendingCalls.removeAll { $0.call.id == result.callID && $0.turnID == result.turnID } }
        }
        state.sequence = transactions.count
        return state
    }
}

@MainActor final class RuntimeCoreTests: XCTestCase {
    private func tool(_ log: RuntimeToolLog, name: String = "effect", outcome: ToolOutcome = .init(content: "receipt")) -> ClosureTool {
        .init(descriptor: .init(name: name, description: "fixture", parameters: .object([:]))) { invocation, context in
            try await context.checkCancellation()
            await log.record(invocation.callID)
            return outcome
        }
    }
    private func run(_ runtime: AgentRuntime, session: UUID, text: String = "goal") async throws -> TurnResult {
        let turn = try await runtime.startTurn(in: session, input: .init(text: text))
        return await turn.result()
    }
    func testSequentialToolsAndStructuredErrorsReachNextInferenceOnce() async throws {
        let provider = RuntimeFixtureProvider([.tools([.init(id: "a", name: "effect", arguments: "{}"), .init(id: "b", name: "unknown", arguments: "{}"), .init(id: "c", name: "effect", arguments: "{}")]), .text("done")])
        let log = RuntimeToolLog(), store = RuntimeMemoryStore(), session = UUID()
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: [tool(log)])
        let result = try await run(runtime, session: session)
        XCTAssertEqual(result.status, .completed)
        let calls = await log.values(); XCTAssertEqual(calls, ["a", "c"])
        let inputs = await provider.inputs(); XCTAssertEqual(inputs.count, 2)
        let results = inputs[1].compactMap { item -> String? in if case .functionResult(let id, _) = item { return id }; return nil }
        XCTAssertEqual(results, ["a", "b", "c"])
        if case .functionResult(_, let text) = inputs[1][5] { XCTAssertTrue(text.contains("validationFailed")) }
        let state = try await store.loadContext(session)
        XCTAssertTrue(state.pendingCalls.isEmpty)
        let page = try await store.readPage(.init(sessionID: session))
        XCTAssertEqual(page.items.last(where: { $0.role == "assistant" })?.text, "done")
    }
    func testLargeToolResultsReachModelAndReloadWithoutTruncation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID(), log = RuntimeToolLog()
        let rows = (0..<600).map { ["name": "应用🙂-\($0)", "bundle_id": "test.example.app\($0)", "version": "1.0"] }
        let text = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        XCTAssertGreaterThan(text.utf8.count, 4096 * 3)
        let outcomes = [ToolOutcome(content: text), ToolOutcome(kind: .validationFailed, content: text)]
        let calls = outcomes.indices.map { ModelToolCall(id: "result-\($0)", name: "tool-\($0)", arguments: "{}") }
        let tools = outcomes.enumerated().map { tool(log, name: "tool-\($0.offset)", outcome: $0.element) }
        let provider = RuntimeFixtureProvider([.tools(calls), .text("done"), .text("continued")])
        let configuration = AgentConfiguration(model: "fixture", budget: .init(planningTokens: 1_000_000))
        let runtime = AgentRuntime(store: JSONLSessionStore(root: root, sessionID: session), provider: provider,
                                   configuration: configuration, tools: tools)
        let result = try await run(runtime, session: session)
        XCTAssertEqual(result.status, .completed)
        let reopened = JSONLSessionStore(root: root, sessionID: session)
        let next = AgentRuntime(store: reopened, provider: provider, configuration: configuration, tools: tools)
        let continued = try await run(next, session: session)
        XCTAssertEqual(continued.status, .completed)
        let inputs = await provider.inputs()
        for input in inputs.dropFirst() {
            let results = input.compactMap { item -> String? in
                if case .functionResult(_, let output) = item { return output }; return nil
            }
            XCTAssertEqual(results, outcomes.map(\.modelContent))
        }
        let stored = try await reopened.readTransactions(session)
        XCTAssertEqual(stored.flatMap(\.toolResults).map(\.outcome), outcomes)
        let executed = await log.values()
        XCTAssertEqual(executed, calls.map(\.id))
    }
    func testInvalidBatchEOFAndDuplicateTerminalExecuteNothingAndFutureTurnSucceeds() async throws {
        for step in [RuntimeFixtureProvider.Step.tools([.init(id: "same", name: "effect", arguments: "{}"), .init(id: "same", name: "effect", arguments: "{}")]), .eof, .duplicateTerminal] {
            let provider = RuntimeFixtureProvider([step, .text("recovered")]), log = RuntimeToolLog(), store = RuntimeMemoryStore(), session = UUID()
            let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: [tool(log)])
            let failed = try await run(runtime, session: session); XCTAssertEqual(failed.status, .failed)
            let calls = await log.values(); XCTAssertTrue(calls.isEmpty)
            let recovered = try await run(runtime, session: session); XCTAssertEqual(recovered.text, "recovered")
            let state = try await store.loadContext(session)
            XCTAssertFalse(state.items.contains { if case .replay(.functionCall) = $0 { return true }; return false })
        }
    }
    func testDurableOutputOrClaimFailurePreventsEffectAndDoesNotLeaveBusy() async throws {
        for kind in [TransactionKind.modelOutput, .toolClaimed] {
            let store = RuntimeMemoryStore(), log = RuntimeToolLog(), provider = RuntimeFixtureProvider([.tools([.init(id: "a", name: "effect", arguments: "{}")]), .text("recovered")]), session = UUID()
            await store.setFailure(kind)
            let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: [tool(log)])
            let result = try await run(runtime, session: session); XCTAssertEqual(result.status, .failed)
            let calls = await log.values(); XCTAssertTrue(calls.isEmpty)
            await store.setFailure(nil)
            let next = try await run(runtime, session: session); XCTAssertEqual(next.status, .completed)
            let state = try await store.loadContext(session); XCTAssertTrue(state.pendingCalls.isEmpty)
        }
    }
    func testRestartClosesPreparedAndClaimedCallsWithoutExecutingThem() async throws {
        let store = RuntimeMemoryStore(), session = UUID(), oldTurn = UUID(), log = RuntimeToolLog()
        let calls = [ModelToolCall(id: "prepared", name: "effect", arguments: "{}"), .init(id: "claimed", name: "effect", arguments: "{}")]
        _ = try await store.append(.init(sessionID: session, turnID: oldTurn, kind: .modelOutput, contextItems: calls.map { .replay(.functionCall($0)) }), expecting: 0)
        _ = try await store.append(.init(sessionID: session, turnID: oldTurn, kind: .toolClaimed, toolClaims: ["claimed"]), expecting: 1)
        let provider = RuntimeFixtureProvider([.text("new")])
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: [tool(log)])
        _ = try await runtime.loadSession(session)
        let state = try await store.loadContext(session)
        XCTAssertTrue(state.pendingCalls.isEmpty)
        let facts = try await store.readTransactions(session)
        XCTAssertEqual(facts.flatMap(\.toolResults).map(\.outcome.kind), [.cancelledBeforeDispatch, .outcomeUnknown])
        let callsAfterLoad = await log.values(); XCTAssertTrue(callsAfterLoad.isEmpty)
        _ = try await run(runtime, session: session)
        let callsAfterTurn = await log.values(); XCTAssertTrue(callsAfterTurn.isEmpty)
    }
    func testThirtyTwoTurnsAreStableAcrossRuntimeRestartAndUIIdentity() async throws {
        let store = RuntimeMemoryStore(), provider = RuntimeFixtureProvider([]), session = UUID()
        let config = AgentConfiguration(model: "fixture", budget: .init(planningTokens: 1_000_000))
        var runtime = AgentRuntime(store: store, provider: provider, configuration: config)
        for index in 0..<32 { _ = try await run(runtime, session: session, text: "question-\(index)") }
        runtime = AgentRuntime(store: store, provider: provider, configuration: config)
        _ = try await run(runtime, session: session, text: "last")
        let inputs = await provider.inputs()
        XCTAssertEqual(inputs.last?.count, 65)
        XCTAssertEqual(Array(inputs[20].prefix(inputs[19].count)), inputs[19])
        let page = try await store.readPage(.init(sessionID: session)); XCTAssertEqual(page.items.count, 66)
    }
    func testExplicitResponseChainUsesDeltaAndStaleHeadRecoveryKeepsInputOnce() async throws {
        let store = RuntimeMemoryStore(), provider = RuntimeFixtureProvider([.text("one"), .rejected(.invalidResponseHead), .text("two")], chain: true), session = UUID()
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture", storage: .responseChain))
        _ = try await run(runtime, session: session, text: "first")
        let result = try await run(runtime, session: session, text: "second"); XCTAssertEqual(result.status, .completed)
        let requests = await provider.allRequests()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[1].input?.count, 1); XCTAssertEqual(requests[2].input?.count, 3)
        if case .previousResponse = requests[1].context {} else { XCTFail("Expected response head") }
        XCTAssertEqual(requests[2].context, .stateless)
        let state = try await store.loadContext(session)
        XCTAssertEqual(state.items.filter { if case .message(role: .user, _) = $0 { return true }; return false }.count, 2)
    }
    func testManualPortableCompactionIsAtomicPreservesDisplayAndDoesNotReappendOldFacts() async throws {
        let store = RuntimeMemoryStore(), provider = RuntimeFixtureProvider([]), session = UUID()
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture", budget: .init(planningTokens: 1_000_000)))
        for index in 0..<12 { _ = try await run(runtime, session: session, text: "goal-\(index) " + String(repeating: "details ", count: 300)) }
        let before = try await store.loadContext(session), uiBefore = try await store.readPage(.init(sessionID: session))
        let outcome = try await runtime.compactSession(session, strategy: .portable)
        XCTAssertEqual(outcome.method, .portable); XCTAssertLessThan(outcome.afterTokens, outcome.beforeTokens)
        let compacted = try await store.loadContext(session), uiAfter = try await store.readPage(.init(sessionID: session))
        XCTAssertLessThan(compacted.items.count, before.items.count); XCTAssertEqual(uiBefore.items, uiAfter.items)
        _ = try await run(runtime, session: session, text: "continue")
        let inputs = await provider.inputs(); XCTAssertEqual(inputs.last?.count, compacted.items.count + 1)
        XCTAssertEqual(Array(inputs.last!.prefix(compacted.items.count)), compacted.items)
        await provider.setInvalidSummary(true)
        let stable = try await store.loadContext(session)
        do { _ = try await runtime.compactSession(session, strategy: .portable); XCTFail("Expected invalid summary") } catch {}
        let afterFailure = try await store.loadContext(session); XCTAssertEqual(stable.items, afterFailure.items)
        await provider.setInvalidSummary(false)
        let next = try await run(runtime, session: session); XCTAssertEqual(next.status, .completed)
    }
    func testCancellationFenceIsImmediateAndLateToolCannotDispatchFollowingCall() async throws {
        let store = RuntimeMemoryStore(), log = RuntimeToolLog(), gate = RuntimeGate(), session = UUID()
        let provider = RuntimeFixtureProvider([.tools([.init(id: "first", name: "blocking", arguments: "{}"), .init(id: "later", name: "effect", arguments: "{}")]), .text("recovered")])
        let blocking = ClosureTool(descriptor: .init(name: "blocking", description: "fixture", parameters: .object([:]))) { invocation, context in
            await log.record(invocation.callID)
            await gate.wait() // Deliberately ignores Task cancellation, like an in-flight device transport.
            let valid = await context.fence.isValid
            XCTAssertFalse(valid)
            return .init(content: "late delivery fact")
        }
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: [blocking, tool(log)])
        let handle = try await runtime.startTurn(in: session, input: .init(text: "goal"))
        for _ in 0..<100 { if await gate.hasEntered() { break }; try await Task.sleep(for: .milliseconds(5)) }
        await runtime.cancelTurn(handle.id)
        do { _ = try await runtime.startTurn(in: session, input: .init(text: "too early")); XCTFail("Active resource must stay isolated") }
        catch { XCTAssertEqual(error as? AgentRuntimeError, .busy) }
        await gate.release()
        let stopped = await handle.result(); XCTAssertEqual(stopped.status, .interrupted)
        let calls = await log.values(); XCTAssertEqual(calls, ["first"])
        let facts = try await store.readTransactions(session)
        XCTAssertEqual(facts.flatMap(\.toolResults).map(\.outcome.kind), [.returned, .cancelledBeforeDispatch])
        let next = try await run(runtime, session: session); XCTAssertEqual(next.status, .completed)
    }
    func testResultCommitFailureStopsFollowingEffectThenRecoveryDoesNotReplay() async throws {
        let store = RuntimeMemoryStore(), log = RuntimeToolLog(), session = UUID()
        let provider = RuntimeFixtureProvider([.tools([.init(id: "first", name: "effect", arguments: "{}"), .init(id: "later", name: "effect", arguments: "{}")]), .text("recovered")])
        await store.setFailure(.toolResult)
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: [tool(log)])
        let failed = try await run(runtime, session: session); XCTAssertEqual(failed.status, .failed)
        let calls = await log.values(); XCTAssertEqual(calls, ["first"])
        await store.setFailure(nil)
        let next = try await run(runtime, session: session); XCTAssertEqual(next.status, .completed)
        let state = try await store.loadContext(session); XCTAssertTrue(state.pendingCalls.isEmpty)
        let facts = try await store.readTransactions(session)
        XCTAssertEqual(facts.flatMap(\.toolResults).map(\.outcome.kind), [.outcomeUnknown, .cancelledBeforeDispatch])
        let after = await log.values(); XCTAssertEqual(after, ["first"])
    }
    func testNativeCompressionPreservesCanonicalWindowAndResetsResponseHead() async throws {
        let session = UUID(), store = RuntimeMemoryStore()
        let scope = ProviderReplayScope(provider: RuntimeFixtureProvider.name, endpoint: "https://example.invalid/v1", account: "fixture", model: "fixture", session: session)
        let provider = RuntimeFixtureProvider([], chain: true, nativeScope: scope)
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture", scope: scope, storage: .responseChain, budget: .init(planningTokens: 1_000_000)))
        for index in 0..<8 { _ = try await run(runtime, session: session, text: "question-\(index) " + String(repeating: "content ", count: 80)) }
        let before = try await store.readPage(.init(sessionID: session))
        let outcome = try await runtime.compactSession(session, strategy: .native); XCTAssertEqual(outcome.method, .native)
        let state = try await store.loadContext(session)
        XCTAssertNil(state.snapshot?.head)
        guard case .replay(.compaction(let memory)) = state.items.first else { return XCTFail("Full canonical native replacement must survive") }
        XCTAssertEqual(memory.encryptedContentForReplay, "encrypted-memory")
        _ = try await run(runtime, session: session, text: "continue")
        let requests = await provider.allRequests(); XCTAssertEqual(requests.last?.context, .stateless)
        XCTAssertEqual(requests.last?.input?.count, state.items.count + 1)
        let after = try await store.readPage(.init(sessionID: session)); XCTAssertEqual(after.items.count, before.items.count + 2)
        let reloaded = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture", scope: scope, storage: .responseChain, budget: .init(planningTokens: 1_000_000)))
        _ = try await run(reloaded, session: session, text: "after-reload")
        let continued = await provider.allRequests()
        if case .previousResponse = continued.last?.context {} else { XCTFail("Expected a newly established post-compaction head") }
        XCTAssertEqual(continued.last?.input?.count, 1)
    }
    func testPortableCompactionPersistsJSONLAndReopensWithStableLocalWindow() async throws {
        let session = UUID(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-portable-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLSessionStore(root: directory, sessionID: session), provider = RuntimeFixtureProvider([])
        let config = AgentConfiguration(model: "fixture", budget: .init(planningTokens: 1_000_000))
        let runtime = AgentRuntime(store: store, provider: provider, configuration: config)
        for index in 0..<12 { _ = try await run(runtime, session: session, text: "prior-\(index) " + String(repeating: "detail ", count: 300)) }
        let uiBefore = try await store.readPage(.init(sessionID: session))
        let outcome = try await runtime.compactSession(session, strategy: .portable)
        XCTAssertEqual(outcome.method, .portable)
        let compacted = try await store.loadContext(session)
        let uiAfter = try await store.readPage(.init(sessionID: session)); XCTAssertEqual(uiBefore.items, uiAfter.items)
        let reopened = JSONLSessionStore(root: directory, sessionID: session, requireExistingHistory: true)
        let nextRuntime = AgentRuntime(store: reopened, provider: provider, configuration: config)
        let restored = try await nextRuntime.loadSession(session); XCTAssertEqual(restored.context, compacted.items)
        let result = try await run(nextRuntime, session: session, text: "after portable restart")
        XCTAssertEqual(result.status, .completed)
        let requests = await provider.allRequests(), request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.context, .stateless)
        let input = try XCTUnwrap(request.input)
        XCTAssertEqual(Array(input.prefix(compacted.items.count)), compacted.items)
        XCTAssertEqual(input.count, compacted.items.count + 1)
        let facts = try await reopened.readTransactions(session)
        let messages = facts.flatMap(\.contextItems).filter { if case .message(.user, let content) = $0 { return content == [.text("after portable restart")] }; return false }
        XCTAssertEqual(messages.count, 1)
    }
    func testNativeCompactionJSONLRestartUsesFullWindowThenChainDelta() async throws {
        let session = UUID(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLSessionStore(root: directory, sessionID: session)
        let scope = ProviderReplayScope(provider: RuntimeFixtureProvider.name, endpoint: "https://example.invalid/v1", account: "fixture", model: "fixture", session: session)
        let provider = RuntimeFixtureProvider([], chain: true, nativeScope: scope)
        let config = AgentConfiguration(model: "fixture", scope: scope, storage: .responseChain, budget: .init(planningTokens: 1_000_000))
        let runtime = AgentRuntime(store: store, provider: provider, configuration: config)
        for index in 0..<8 { _ = try await run(runtime, session: session, text: "prior-\(index) " + String(repeating: "content ", count: 80)) }
        let uiBefore = try await store.readPage(.init(sessionID: session))
        let outcome = try await runtime.compactSession(session, strategy: .native); XCTAssertEqual(outcome.method, .native)
        let compacted = try await store.loadContext(session), uiAfter = try await store.readPage(.init(sessionID: session))
        XCTAssertEqual(uiBefore.items, uiAfter.items); XCTAssertNil(compacted.snapshot?.head)
        let reopened = JSONLSessionStore(root: directory, sessionID: session, requireExistingHistory: true)
        let nextRuntime = AgentRuntime(store: reopened, provider: provider, configuration: config)
        let restored = try await nextRuntime.loadSession(session); XCTAssertEqual(restored.context, compacted.items)
        guard case .replay(.compaction(let opaque)) = restored.context.first else { return XCTFail("Missing native compaction") }
        XCTAssertEqual(opaque.encryptedContentForReplay, "encrypted-memory")
        let first = try await run(nextRuntime, session: session, text: "first after native"); XCTAssertEqual(first.status, .completed)
        var requests = await provider.allRequests(); let firstRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(firstRequest.context, .stateless)
        XCTAssertEqual(Array(try XCTUnwrap(firstRequest.input).prefix(compacted.items.count)), compacted.items)
        let stateAfter = try await reopened.loadContext(session)
        let finalStore = JSONLSessionStore(root: directory, sessionID: session, requireExistingHistory: true)
        let finalRuntime = AgentRuntime(store: finalStore, provider: provider, configuration: config)
        let finalRestore = try await finalRuntime.loadSession(session); XCTAssertEqual(finalRestore.context, stateAfter.items)
        let second = try await run(finalRuntime, session: session, text: "second after native"); XCTAssertEqual(second.status, .completed)
        requests = await provider.allRequests(); let secondRequest = try XCTUnwrap(requests.last)
        if case .previousResponse = secondRequest.context {} else { XCTFail("Expected a newly established response head") }
        XCTAssertEqual(secondRequest.input, [.message(role: .user, content: [.text("second after native")])])
        let finalUI = try await finalStore.readPage(.init(sessionID: session))
        XCTAssertEqual(Array(finalUI.items.prefix(uiBefore.items.count)), uiBefore.items)
        let facts = try await finalStore.readTransactions(session)
        for text in ["first after native", "second after native"] {
            XCTAssertEqual(facts.flatMap(\.contextItems).filter { if case .message(.user, let content) = $0 { return content == [.text(text)] }; return false }.count, 1)
        }
    }
    func testSoftCompressionFailureAndUnknownCapacityDoNotBlockConversation() async throws {
        let store = RuntimeMemoryStore(), provider = RuntimeFixtureProvider([]), session = UUID()
        await provider.setInvalidSummary(true)
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "unknown-model", budget: .init(planningTokens: 512, outputReserve: 32, toolResultReserve: 32)))
        for index in 0..<6 {
            let result = try await run(runtime, session: session, text: "question-\(index) " + String(repeating: "details ", count: 40))
            XCTAssertEqual(result.status, .completed)
        }
        let summaryCount = await provider.summaryCount(); XCTAssertGreaterThan(summaryCount, 0)
        let state = try await store.loadContext(session); XCTAssertEqual(state.items.count, 12)
    }
    func testIdleTimeoutAndUnknownAcceptanceNeverRetryAndNextTurnCanSucceed() async throws {
        for step in [RuntimeFixtureProvider.Step.stall, .failure] {
            let store = RuntimeMemoryStore(), provider = RuntimeFixtureProvider([step, .text("recovered")]), session = UUID()
            let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture", streamIdleTimeout: 0.03))
            let failed = try await run(runtime, session: session)
            XCTAssertEqual(failed.status, .failed)
            let first = await provider.allRequests(); XCTAssertEqual(first.count, 1)
            let next = try await run(runtime, session: session); XCTAssertEqual(next.status, .completed)
            let requests = await provider.allRequests(); XCTAssertEqual(requests.count, 2)
        }
    }
    func testAwaitedInferenceBackpressureAndSlowUIKeepTerminalAuthoritative() async throws {
        let store = RuntimeMemoryStore(), provider = RuntimeFixtureProvider([.burst(2048)]), session = UUID()
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"))
        let handle = try await runtime.startTurn(in: session, input: .init(text: "goal"))
        let result = await handle.result(); XCTAssertEqual(result.text, "canonical-final"); XCTAssertEqual(result.status, .completed)
        var resync = false
        for await event in handle.events { if case .resyncRequired = event { resync = true } }
        XCTAssertTrue(resync)
        let page = try await store.readPage(.init(sessionID: session))
        XCTAssertEqual(page.items.last?.text, "canonical-final")
    }
    func testCapacityRejectionCompactsExactlyOnceAndDoesNotDuplicateInput() async throws {
        let store = RuntimeMemoryStore(), session = UUID(), provider = RuntimeFixtureProvider([])
        let config = AgentConfiguration(model: "fixture", budget: .init(planningTokens: 1_000_000))
        let setup = AgentRuntime(store: store, provider: provider, configuration: config)
        for index in 0..<8 { _ = try await run(setup, session: session, text: "prior-\(index) " + String(repeating: "facts ", count: 120)) }
        let rejecting = RuntimeFixtureProvider([.rejected(.contextCapacity), .rejected(.contextCapacity), .text("recovered")])
        let runtime = AgentRuntime(store: store, provider: rejecting, configuration: config)
        let rejected = try await run(runtime, session: session, text: "same-user-input"); XCTAssertEqual(rejected.status, .failed)
        let requests = await rejecting.allRequests(); XCTAssertEqual(requests.count, 2)
        let state = try await store.loadContext(session)
        XCTAssertEqual(state.items.filter { if case .message(role: .user, let content) = $0 { return content == [.text("same-user-input")] }; return false }.count, 1)
        let next = try await run(runtime, session: session, text: "new-request"); XCTAssertEqual(next.status, .completed)
    }
    func testJSONLRestartUsesDeltasAndScopeRebuildKeepsAllPublicFacts() async throws {
        let session = UUID(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-runtime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLSessionStore(root: directory, sessionID: session), provider = RuntimeFixtureProvider([])
        let config = AgentConfiguration(model: "fixture", budget: .init(planningTokens: 1_000_000))
        let runtime = AgentRuntime(store: store, provider: provider, configuration: config)
        _ = try await runtime.createSession(id: session)
        for index in 0..<18 { _ = try await run(runtime, session: session, text: "fact-\(index)") }
        let facts = try await store.readTransactions(session)
        XCTAssertTrue(facts.filter { $0.kind == .modelOutput }.allSatisfy { $0.snapshot == nil && $0.contextHead != nil })
        let reopened = JSONLSessionStore(root: directory, sessionID: session)
        let newScope = ProviderReplayScope(provider: "new-provider", endpoint: "https://new.example.invalid/v1", account: "new-account", model: "fixture", session: session)
        let changed = AgentRuntime(store: reopened, provider: provider, configuration: .init(model: "fixture", scope: newScope, budget: .init(planningTokens: 1_000_000)))
        let result = try await run(changed, session: session, text: "new-scope"); XCTAssertEqual(result.status, .completed)
        let requests = await provider.allRequests(); XCTAssertEqual(requests.last?.input?.count, 37)
        XCTAssertFalse(requests.last!.input!.contains { if case .chatReplayState = $0 { return true }; if case .replay(.compaction) = $0 { return true }; return false })
    }
    func testCancelledAndRevisionConflictedSummariesNeverReplaceAuthoritativeWindow() async throws {
        for cancel in [true, false] {
            let store = RuntimeMemoryStore(), provider = RuntimeFixtureProvider([]), session = UUID()
            let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture", budget: .init(planningTokens: 1_000_000)))
            for index in 0..<6 { _ = try await run(runtime, session: session, text: "goal-\(index) " + String(repeating: "details ", count: 80)) }
            let before = try await store.loadContext(session), gate = RuntimeGate()
            await provider.setSummaryGate(gate)
            let operation = Task { try await runtime.compactSession(session, strategy: .portable) }
            for _ in 0..<100 { if await gate.hasEntered() { break }; try await Task.sleep(for: .milliseconds(5)) }
            if cancel { operation.cancel() }
            else { _ = try await store.append(.init(sessionID: session, kind: .recovery, contextItems: [.message(role: .user, content: [.text("external committed fact")])]), expecting: before.revision) }
            await gate.release()
            do { _ = try await operation.value; XCTFail("Cancelled or stale candidate must fail") } catch {}
            let after = try await store.loadContext(session)
            XCTAssertEqual(Array(after.items.prefix(before.items.count)), before.items)
            let facts = try await store.readTransactions(session)
            XCTAssertFalse(facts.contains { $0.kind == .contextCompacted })
            await provider.setSummaryGate(nil)
            let next = try await run(runtime, session: session); XCTAssertEqual(next.status, .completed)
        }
    }
    func testDeviceObservationByteRetentionPreservesAttachmentsToolGroupsAndDisplayHistory() async throws {
        let store = RuntimeMemoryStore(), session = UUID()
        let steps: [RuntimeFixtureProvider.Step] = (0..<6).map { .tools([.init(id: "screen-\($0)", name: "screenshot", arguments: "{}")]) } + [.text("finished")]
        let provider = RuntimeFixtureProvider(steps, chain: true)
        let screenshot = ClosureTool(descriptor: .init(name: "screenshot", description: "fixture", parameters: .object([:]))) { invocation, _ in
            var image = ModelImage(data: Data(repeating: 0x31, count: 3 * 1024 * 1024))
            image.observationID = "observation-" + invocation.callID; image.width = 1024; image.height = 1024
            return .init(content: "Captured \(invocation.callID)", images: [image])
        }
        let attachment = ModelImage(data: Data(repeating: 0x72, count: 2 * 1024 * 1024))
        let runtime = AgentRuntime(store: store, provider: provider,
            configuration: .init(model: "fixture", storage: .responseChain, budget: .init(planningTokens: 1_000_000),
                                 observationRetention: .init(maximumGroups: 2, maximumImageBytes: 5 * 1024 * 1024)), tools: [screenshot])
        let handle = try await runtime.startTurn(in: session, input: .init(text: "inspect six frames", images: [attachment]))
        let result = await handle.result(); XCTAssertEqual(result.status, .completed)
        let state = try await store.loadContext(session)
        let images = state.items.flatMap { item -> [ModelImage] in if case .message(_, let parts) = item { return parts.compactMap { if case .image(let image) = $0 { return image }; return nil } }; return [] }
        XCTAssertEqual(images.filter { $0.observationID != nil }.map(\.observationID), ["observation-screen-5"])
        XCTAssertEqual(images.filter { $0.observationID == nil }, [attachment])
        let calls = state.items.compactMap { item -> String? in if case .replay(.functionCall(let call)) = item { return call.id }; return nil }
        let results = state.items.compactMap { item -> String? in if case .functionResult(let id, _) = item { return id }; return nil }
        XCTAssertEqual(calls, (0..<6).map { "screen-\($0)" }); XCTAssertEqual(results, calls)
        try ContextProjection.validateClosedTools(state.items)
        let facts = try await store.readTransactions(session)
        let transforms = facts.filter { $0.snapshot != nil }
        XCTAssertEqual(transforms.count, 5); XCTAssertTrue(transforms.allSatisfy { $0.displayItems.isEmpty })
        XCTAssertEqual(facts.flatMap(\.toolResults).flatMap(\.outcome.images).count, 6)
        let page = try await store.readPage(.init(sessionID: session)); XCTAssertEqual(page.items.filter { $0.role == "tool" }.count, 6)
        let requests = await provider.allRequests()
        XCTAssertTrue(requests.dropFirst(2).allSatisfy { $0.context == .stateless }, "Replacing a media window must reset the prior server head")
        XCTAssertTrue(requests.dropFirst(2).allSatisfy { request in
            (request.input ?? []).contains { if case .message(_, let parts) = $0 { return parts.contains(.image(attachment)) }; return false }
        })
    }
    func testHostCancellationWithoutTaskCancellationStopsRemainingCallsAndEmptyToolTerminalDoesNotReuseNarration() async throws {
        let log = RuntimeToolLog(), store = RuntimeMemoryStore(), session = UUID()
        let cancelled = ClosureTool(descriptor: .init(name: "cancel", description: "fixture", parameters: .object([:]))) { _, _ in throw CancellationError() }
        let provider = RuntimeFixtureProvider([.tools([.init(id: "cancel", name: "cancel", arguments: "{}"), .init(id: "later", name: "effect", arguments: "{}")]), .text("recovered")])
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: [cancelled, tool(log)])
        let stopped = try await run(runtime, session: session); XCTAssertEqual(stopped.status, .interrupted)
        let calls = await log.values(); XCTAssertTrue(calls.isEmpty)
        let facts = try await store.readTransactions(session)
        XCTAssertEqual(facts.flatMap(\.toolResults).map(\.outcome.kind), [.outcomeUnknown, .cancelledBeforeDispatch])
        let next = try await run(runtime, session: session); XCTAssertEqual(next.status, .completed)
        let emptyProvider = RuntimeFixtureProvider([.tools([.init(id: "failed", name: "missing", arguments: "{}")]), .text("")])
        let empty = AgentRuntime(store: RuntimeMemoryStore(), provider: emptyProvider, configuration: .init(model: "fixture"))
        let completed = try await run(empty, session: UUID()); XCTAssertEqual(completed.status, .completed); XCTAssertEqual(completed.text, "")
    }
    func testObservationRetentionNeverRewritesNativeCanonicalPrefix() async throws {
        let store = RuntimeMemoryStore(), provider = RuntimeFixtureProvider([]), session = UUID()
        let scope = ProviderReplayScope(provider: RuntimeFixtureProvider.name, endpoint: "https://example.invalid/v1", account: "fixture", model: "fixture", session: session)
        func image(_ id: String) -> ModelImage { var value = ModelImage(data: Data([1, 2, 3])); value.observationID = id; return value }
        let prefix: [ModelInputItem] = [.replay(.compaction(.init(id: "native", encryptedContent: "canonical", scope: scope))), .message(role: .user, content: [.image(image("native-image"))])]
        _ = try await store.append(.init(sessionID: session, kind: .contextCompacted, snapshot: .init(scope: scope, items: prefix, preservedNativeItemCount: prefix.count)), expecting: 0)
        _ = try await store.append(.init(sessionID: session, kind: .recovery, contextItems: (0..<4).map { .message(role: .user, content: [.image(image("tail-\($0)"))]) }), expecting: 1)
        let runtime = AgentRuntime(store: store, provider: provider,
                                  configuration: .init(model: "fixture", scope: scope, observationRetention: .init(maximumGroups: 1, maximumImageBytes: 1)))
        _ = try await run(runtime, session: session)
        var state = try await store.loadContext(session)
        XCTAssertEqual(Array(state.items.prefix(prefix.count)), prefix); XCTAssertEqual(state.snapshot?.preservedNativeItemCount, prefix.count)
        _ = try await store.append(.init(sessionID: session, kind: .recovery, contextItems: [.message(role: .user, content: [.image(image("new-tail"))])]), expecting: state.revision)
        _ = try await run(runtime, session: session)
        state = try await store.loadContext(session)
        XCTAssertEqual(Array(state.items.prefix(prefix.count)), prefix); XCTAssertEqual(state.snapshot?.preservedNativeItemCount, prefix.count)
        let ids = state.items.flatMap { item -> [String] in if case .message(_, let content) = item { return content.compactMap { if case .image(let value) = $0 { return value.observationID }; return nil } }; return [] }
        XCTAssertEqual(ids, ["native-image", "new-tail"])
    }
    func testMissingPureCompactionThenScopeSwitchPreservesOriginalAndTailWithoutEffects() async throws {
        let session = UUID(), priorTurn = UUID(), tailTurn = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-scope-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldScope = ProviderReplayScope(provider: "prior-provider", endpoint: "https://prior.example.invalid/v1", account: "prior-account", model: "fixture", session: session)
        let original = ModelInputItem.message(role: .user, content: [.text("original goal")])
        let call = ModelToolCall(id: "completed-old-call", name: "effect", arguments: "{}")
        let receipt = ToolOutcome(content: "prior receipt")
        let result = ModelInputItem.functionResult(callID: call.id, output: receipt.content)
        let answer = ModelInputItem.replay(.message(.init(id: "original-answer", content: [.text("original answer", annotations: [])], scope: oldScope)))
        let tail = ModelInputItem.message(role: .user, content: [.text("tail goal")])
        let tailAnswer = ModelInputItem.replay(.message(.init(id: "tail-answer", content: [.text("tail answer", annotations: [])], scope: oldScope)))
        let toolDisplayID = UUID()
        let opaque = ModelInputItem.replay(.compaction(.init(id: "lost-native-memory", encryptedContent: "opaque old memory", scope: oldScope)))
        let old: [SessionTransaction] = [
            .init(sessionID: session, turnID: priorTurn, kind: .turnStarted, contextItems: [original], displayItems: [.init(turnID: priorTurn, role: "user", text: "original goal")]),
            .init(sessionID: session, turnID: priorTurn, kind: .modelOutput, contextItems: [.replay(.functionCall(call))], displayItems: [.init(id: toolDisplayID, turnID: priorTurn, role: "tool", text: call.name)], contextHead: .init(epoch: UUID(), scope: oldScope, responseID: "prior-head", coveredItemCount: 2)),
            .init(sessionID: session, turnID: priorTurn, kind: .toolClaimed, toolClaims: [call.id]),
            .init(sessionID: session, turnID: priorTurn, kind: .toolResult, contextItems: [result], displayItems: [.init(id: toolDisplayID, turnID: priorTurn, role: "tool", text: receipt.content)], toolResults: [.init(turnID: priorTurn, callID: call.id, outcome: receipt)]),
            .init(sessionID: session, turnID: priorTurn, kind: .modelOutput, contextItems: [answer], displayItems: [.init(turnID: priorTurn, role: "assistant", text: "original answer")]),
            .init(sessionID: session, kind: .contextCompacted, snapshot: .init(scope: oldScope, items: [opaque], preservedNativeItemCount: 1)),
            .init(sessionID: session, turnID: tailTurn, kind: .turnStarted, contextItems: [tail], displayItems: [.init(turnID: tailTurn, role: "user", text: "tail goal")]),
            .init(sessionID: session, turnID: tailTurn, kind: .modelOutput, contextItems: [tailAnswer], displayItems: [.init(turnID: tailTurn, role: "assistant", text: "tail answer")], contextHead: .init(epoch: UUID(), scope: oldScope, responseID: "old-tail-head", coveredItemCount: 3))]
        try LegacySessionFixtures.write(root: directory, sessionID: session, transactions: old, missing: [5])
        let reopened = JSONLSessionStore(root: directory, sessionID: session)
        try reopened.migrateLegacySync { _ in XCTFail("Unexpected UI conversion"); return [] }
        let before = try await reopened.readPage(.init(sessionID: session))
        let provider = RuntimeFixtureProvider([.text("continued")]), log = RuntimeToolLog()
        let newScope = ProviderReplayScope(provider: "new-provider", endpoint: "https://new.example.invalid/v1", account: "new-account", model: "fixture", session: session)
        let runtime = AgentRuntime(store: reopened, provider: provider, configuration: .init(model: "fixture", scope: newScope, budget: .init(planningTokens: 1_000_000)), tools: [tool(log)])
        let restored = try await runtime.loadSession(session)
        XCTAssertEqual(restored.context, [original, .replay(.functionCall(call)), result, answer, tail, tailAnswer])
        let requestsBeforeTurn = await provider.allRequests(); XCTAssertTrue(requestsBeforeTurn.isEmpty)
        let effectsBeforeTurn = await log.values(); XCTAssertTrue(effectsBeforeTurn.isEmpty)
        let completed = try await run(runtime, session: session, text: "continue in new scope")
        XCTAssertEqual(completed.status, .completed); XCTAssertEqual(completed.text, "continued")
        let requests = await provider.allRequests(); XCTAssertEqual(requests.count, 1)
        let input = try XCTUnwrap(requests.first?.input)
        XCTAssertEqual(input, [original, .replay(.functionCall(call)), result,
            .message(role: .assistant, content: [.text("original answer")]), tail,
            .message(role: .assistant, content: [.text("tail answer")]), .message(role: .user, content: [.text("continue in new scope")])])
        let effects = await log.values(); XCTAssertTrue(effects.isEmpty)
        let after = try await reopened.readPage(.init(sessionID: session))
        XCTAssertEqual(Array(after.items.prefix(before.items.count)), before.items)
        let final = try await reopened.loadContext(session); XCTAssertEqual(final.snapshot?.scope, newScope); XCTAssertTrue(final.pendingCalls.isEmpty)
        do { _ = try await reopened.readTransactions(session); XCTFail("Strict audit must continue reporting the missing compaction payload") }
        catch StoreError.missingBlob {} catch { XCTFail("Unexpected audit error: \(error)") }
    }
    func testTrustedFinishClosesRemainderWithoutDispatch() async throws {
        let store = RuntimeMemoryStore(), log = RuntimeToolLog(), provider = RuntimeFixtureProvider([.tools([.init(id: "finish", name: "finish", arguments: "{}"), .init(id: "later", name: "effect", arguments: "{}")])]), session = UUID()
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: [tool(log), tool(log, name: "finish", outcome: .init(content: "finished", finishTurn: true))])
        let result = try await run(runtime, session: session); XCTAssertEqual(result.status, .completed); XCTAssertEqual(result.text, "finished")
        let calls = await log.values(); XCTAssertEqual(calls, ["finish"])
        let state = try await store.loadContext(session); XCTAssertTrue(state.pendingCalls.isEmpty)
        let facts = try await store.readTransactions(session)
        XCTAssertEqual(facts.flatMap(\.toolResults).last?.outcome.kind, .cancelledBeforeDispatch)
    }
}
