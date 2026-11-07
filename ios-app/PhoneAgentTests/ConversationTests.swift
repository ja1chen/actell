import XCTest
import Combine
import AgentKit
import ProviderCore
@testable import PhoneAgent

@MainActor final class ConversationTests: XCTestCase {
    func testTurnSummaryGroupsWholeRunsAndCountsOnlyNonemptyThoughtsAndToolCalls() {
        let first = UUID(), second = UUID()
        let messages = [
            ChatMessage(runID: first, role: .user, text: "first"),
            ChatMessage(runID: first, role: .assistant, text: "", reasoning: .init(text: "one\n\ntwo")),
            ChatMessage(runID: first, role: .tool, text: "", tool: .init(callID: "a", name: "tap", state: .succeeded, detail: "")),
            ChatMessage(runID: first, role: .assistant, text: "answer", reasoning: .init(text: "next")),
            ChatMessage(runID: second, role: .user, text: "second"),
            ChatMessage(runID: second, role: .assistant, text: "answer", reasoning: .init(text: " \n"))
        ]
        let turns = ConversationTurn.group(messages)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].id, messages[0].id)
        XCTAssertEqual(turns[0].runID, first)
        XCTAssertEqual(turns[0].tools.count, 1)
        XCTAssertEqual(turns[0].thoughts.count, 2)
        XCTAssertEqual(turns[0].firstActivityID, messages[1].id)
        XCTAssertEqual(turns[0].foldedMessages.map(\.id), Array(messages[1...3]).map(\.id))
        XCTAssertEqual(turns[0].summaryLabel, "1 次工具调用 · 2 段思考")
        XCTAssertTrue(turns[1].tools.isEmpty)
        XCTAssertTrue(turns[1].thoughts.isEmpty)
        XCTAssertNil(turns[1].firstActivityID)
        XCTAssertTrue(turns[1].foldedMessages.isEmpty)
        XCTAssertEqual(turns[1].summaryLabel, "")
        XCTAssertEqual(turns.flatMap(\.messages), messages)
        XCTAssertTrue(ConversationTurn.group([]).isEmpty)
        XCTAssertEqual(ConversationTurn.group([ChatMessage(role: .user, text: "legacy"), ChatMessage(role: .assistant, text: "old"), ChatMessage(role: .user, text: "next")]).count, 2)
    }
    func testUnsentDraftStaysOutOfHistoryAndEveryArchiveWrite() throws {
        let directory = try temporaryDirectory()
        let store = ConversationStore(directory: directory)
        let existing = store.create(mode: .live)
        let draft = store.createDraft(mode: .live)
        store.setDraft("尚未发送", in: draft)
        store.selectProvider(UUID(), model: "chosen", in: draft)
        store.saveNow()
        XCTAssertEqual(store.conversations.map(\.id), [existing])
        XCTAssertEqual(store.conversation(draft)?.draft, "尚未发送")
        XCTAssertNil(ConversationStore(directory: directory).conversation(draft))
        let prepared = try store.prepare(SessionCommand(.prepare("Siri 草稿")), task: "Siri 草稿")
        XCTAssertNotNil(ConversationStore(directory: directory).conversation(prepared))
        XCTAssertNil(ConversationStore(directory: directory).conversation(draft))
        store.discardDraft(draft)
        XCTAssertNil(store.conversation(draft))
        store.discardDraft(existing)
        XCTAssertNotNil(store.conversation(existing))
    }
    func testFirstMessagePromotesDraftWithSameIdentityAndAttachments() throws {
        let directory = try temporaryDirectory()
        let store = ConversationStore(directory: directory)
        let draft = store.createDraft(mode: .live), provider = UUID()
        let attachment = StoredAttachment(id: UUID(), conversationID: draft, name: "fixture.txt", kind: .text,
            mimeType: "text/plain", byteCount: 3, digest: "mock")
        store.selectProvider(provider, model: "selected-model", in: draft)
        store.addDraftAttachment(attachment, in: draft)
        XCTAssertEqual(store.referencedAttachments, [attachment])
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertNil(ConversationStore(directory: directory).conversation(draft))
        let run = try XCTUnwrap(store.begin(in: draft, query: "第一条消息", attachments: [attachment]))
        XCTAssertFalse(store.isDraft(draft))
        XCTAssertEqual(store.conversations.map(\.id), [draft])
        store.discardDraft(draft)
        XCTAssertNotNil(store.conversation(draft))
        XCTAssertNil(store.begin(in: draft, query: "重复"))
        store.finish(run, phase: .completed, summary: "")
        let restored = try XCTUnwrap(ConversationStore(directory: directory).conversation(draft))
        XCTAssertEqual(restored.title, "第一条消息")
        XCTAssertEqual(restored.providerID, provider)
        XCTAssertEqual(restored.modelID, "selected-model")
        XCTAssertEqual(restored.messages.first?.attachments, [attachment])
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testEmptyToolArgumentsAreHiddenWithoutHidingZeroOrFalse() {
        for value in [nil, "", " \n ", "{}", "{ \n }", "[]", "[ ]", "null", "\"\"", "\" \""] as [String?] {
            XCTAssertNil(ToolStep.nonemptyArguments(value), "Should hide \(value ?? "nil")")
        }
        for value in ["0", "false", "[0]", "{\"x\":0}", "{\"text\":\"hello\"}", "plain text"] {
            XCTAssertEqual(ToolStep.nonemptyArguments(value), value)
        }
    }
    func testPersistAndRestoreInterruptsUnfinishedToolsWithoutResuming() throws {
        let directory = try temporaryDirectory()
        let store = ConversationStore(directory: directory)
        let id = store.create(mode: .demo)
        let token = try XCTUnwrap(store.begin(in: id, query: "任务 A"))
        store.beginAssistantTurn(token); store.appendText("部分公开回复", identity: token)
        store.updateTool(callID: "tap-a", name: "tap", state: .awaitingApproval, detail: "确认一次点击", identity: token)
        store.saveNow()
        let restored = ConversationStore(directory: directory)
        let session = try XCTUnwrap(restored.conversation(id))
        XCTAssertNil(restored.activeRun)
        XCTAssertEqual(session.phase, .interrupted)
        XCTAssertEqual(session.messages.first?.text, "任务 A")
        XCTAssertEqual(session.messages.first(where: { $0.role == .assistant })?.state, .interrupted)
        XCTAssertEqual(session.messages.last?.tool?.state, .interrupted)
        XCTAssertFalse(session.messages.last?.tool?.displayResult.isEmpty ?? true)
    }
    func testBackgroundCompletionPublishesAccumulatedMessagesAtActiveScene() throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        let id = model.createConversation(mode: .live)
        let ui = AgentPresentationAdapter(model: model, sessionID: id)
        let run = try XCTUnwrap(store.begin(in: id, query: "后台完成"))
        store.beginAssistantTurn(run)
        model.setScene(.background)
        store.completeAssistantTurn("最终回复", identity: run)
        store.finish(run, phase: .completed, summary: "")
        var storeChanges = 0, uiChanges = 0
        let observation = store.objectWillChange.sink { storeChanges += 1 }
        let uiObservation = ui.objectWillChange.sink { uiChanges += 1 }
        model.setScene(.inactive)
        XCTAssertEqual(storeChanges, 0, "An inactive handoff must not consume the accumulated foreground refresh")
        model.setScene(.active)
        XCTAssertEqual(storeChanges, 1)
        XCTAssertGreaterThan(uiChanges, 0)
        XCTAssertEqual(ui.session?.messages.last?.text, "最终回复")
        XCTAssertNil(ui.activeTurnID)
        withExtendedLifetime((observation, uiObservation)) {}
    }
    func testBackgroundStreamingPersistsWithoutPublishingHiddenConversationChanges() throws {
        let directory = try temporaryDirectory(), store = ConversationStore(directory: directory)
        let id = store.create(mode: .live), run = try XCTUnwrap(store.begin(in: id, query: "后台执行"))
        store.beginAssistantTurn(run)
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        store.setPresentationActive(false)
        for _ in 0..<1_000 { store.appendReasoning("进度", identity: run) }
        store.updateTool(callID: "wait", name: "wait", state: .succeeded, result: "Wait completed.", identity: run)
        XCTAssertEqual(changes, 0)
        let restored = ConversationStore(directory: directory)
        XCTAssertEqual(restored.conversation(id)?.messages.first(where: { $0.role == .assistant })?.reasoning?.text, String(repeating: "进度", count: 1_000))
        XCTAssertEqual(restored.conversation(id)?.messages.last?.tool?.state, .succeeded)
        store.setPresentationActive(true)
        XCTAssertEqual(changes, 1, "Returning foreground publishes the accumulated history once")
        withExtendedLifetime(observation) {}
    }
    func testRecoveryUsesDeliveryJournalInsteadOfCancellingAcknowledgedDrag() throws {
        let directory = try temporaryDirectory(), store = ConversationStore(directory: directory)
        let id = store.create(mode: .live), run = try XCTUnwrap(store.begin(in: id, query: "绘图"))
        for call in ["delivered", "unknown", "prepared", "denied"] {
            store.updateTool(callID: call, name: "drag", state: call == "denied" ? .denied : .executing, identity: run)
        }
        var checkpoint = RunCheckpoint(runID: run.runID, conversationID: id, generation: UUID())
        checkpoint.tools = zip(["delivered", "unknown", "prepared", "denied"], [RunCheckpoint.Delivery.observedResult, .dispatching, .prepared, .acknowledged]).map {
            .init(callID: $0.0, name: "drag", parameterSummary: "{\"from_x\":590,\"to_x\":665}", argumentDigest: $0.0, delivery: $0.1)
        }
        let restored = ConversationStore(directory: directory)
        restored.reconcileRecovery(checkpoint.recovered())
        restored.reconcileRecovery(checkpoint.recovered())
        let tools = try XCTUnwrap(restored.conversation(id)).messages.compactMap(\.tool)
        XCTAssertEqual(tools.map(\.state), [.succeeded, .outcomeUnknown, .cancelled, .denied])
        XCTAssertEqual(tools[0].result, "Command delivery acknowledged.")
        XCTAssertNotNil(tools[0].displayArguments)
        XCTAssertTrue(tools[1].result.contains("结果未知"))
        XCTAssertTrue(tools[2].result.contains("未发送"))
        XCTAssertEqual(restored.conversation(id)?.messages.filter { $0.role == .notice }.count, 0)
        XCTAssertNil(restored.activeRun, "Recovery never dispatches or resumes an old action")
        XCTAssertEqual(ConversationStore(directory: directory).conversation(id)?.messages.compactMap(\.tool).map(\.state), tools.map(\.state))
    }
    func testRecoveryLeavesExistingNoticesAndHistoryOrderUnchanged() throws {
        struct LegacyArchive: Encodable { let version = 1; let conversations: [AgentConversation] }
        let directory = try temporaryDirectory()
        var session = AgentConversation(mode: .live)
        session.phase = .interrupted
        let runID = UUID(), originalDate = session.updatedAt
        let oldText = "上次执行已挂起；请核对设备并重新获取截图，旧动作不会重放"
        let newText = "上次执行已中断；已发送动作不会自动重发。"
        session.recoveryNotices = ["old": oldText, "new": newText]
        let user = ChatMessage(runID: runID, role: .user, text: oldText)
        let failure = ChatMessage(runID: runID, role: .notice, text: "截图请求与接收失败（超时）")
        session.messages = [user, ChatMessage(role: .notice, text: oldText),
            ChatMessage(runID: runID, role: .notice, text: newText), failure]
        try JSONEncoder().encode(LegacyArchive(conversations: [session]))
            .write(to: directory.appendingPathComponent("conversations-v1.json"))
        let store = ConversationStore(directory: directory)
        let checkpoint = RunCheckpoint(runID: runID, conversationID: session.id, generation: UUID(), phase: .paused).recovered()
        store.reconcileRecovery(checkpoint)
        store.reconcileRecovery(checkpoint)
        let restored = try XCTUnwrap(store.conversation(session.id))
        XCTAssertEqual(restored.messages, session.messages)
        XCTAssertEqual(restored.phase, .interrupted)
        XCTAssertEqual(restored.updatedAt, originalDate)
        XCTAssertEqual(restored.recoveryNotices, session.recoveryNotices)
        XCTAssertNil(store.activeRun)
        XCTAssertEqual(ConversationStore(directory: directory).conversation(session.id)?.messages, restored.messages)
    }
    func testLateEventsCannotAffectAnotherConversationOrLaterRun() throws {
        let store = ConversationStore(inMemory: true)
        let a = store.create(mode: .demo), b = store.create(mode: .live)
        let old = try XCTUnwrap(store.begin(in: a, query: "A"))
        store.beginAssistantTurn(old); store.finish(old, phase: .stopped, summary: "停止")
        let current = try XCTUnwrap(store.begin(in: b, query: "B"))
        store.beginAssistantTurn(current)
        store.appendText("迟到的 A", identity: old)
        store.updateTool(callID: "old", name: "tap", state: .succeeded, identity: old)
        store.finish(old, phase: .completed, summary: "错误结束")
        store.appendText("B 的回复", identity: current)
        XCTAssertEqual(store.activeRun, current)
        XCTAssertFalse(store.conversations.flatMap(\.messages).contains(where: { $0.text.contains("迟到") || $0.tool?.callID == "old" }))
        XCTAssertEqual(store.conversation(b)?.messages.last?.text, "B 的回复")
    }
    func testDuplicateBeginDoesNotAppendSecondUserMessage() throws {
        let store = ConversationStore(inMemory: true), id = UUID()
        XCTAssertNil(store.begin(in: id, query: "无效会话"))
        let actual = store.create(mode: .demo)
        XCTAssertNotNil(store.begin(in: actual, query: "第一条"))
        XCTAssertNil(store.begin(in: actual, query: "重复"))
        XCTAssertEqual(store.conversation(actual)?.messages.count, 1)
    }
    func testHistoryContainsOnlyCompletedPublicTextFromSelectedConversation() throws {
        let store = ConversationStore(inMemory: true)
        let id = store.create(mode: .demo)
        let token = try XCTUnwrap(store.begin(in: id, query: "问题"))
        store.beginAssistantTurn(token); store.completeAssistantTurn("公开答案", identity: token)
        store.updateTool(callID: "s", name: "screenshot", state: .succeeded, result: "private image metadata", identity: token)
        store.beginAssistantTurn(token); store.appendText("中断片段", identity: token)
        store.finish(token, phase: .interrupted, summary: "中断")
        XCTAssertEqual(store.history(in: id).map(\.text), ["问题", "公开答案"])
        XCTAssertTrue(store.history(in: UUID()).isEmpty)
    }
    func testUnreadableHistoryIsNeverOverwritten() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("conversations-v1.json")
        let original = Data("broken but preserve me".utf8)
        try original.write(to: file)
        let store = ConversationStore(directory: directory)
        XCTAssertNotNil(store.warning)
        store.create(mode: .demo); store.saveNow()
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testLegacyMigrationRunsOnlyOnceAndPreservesDrafts() async throws {
        let directory = try temporaryDirectory()
        let legacy = TaskRecord(goal: "旧任务", mode: .demo)
        let store = ConversationStore(directory: directory, legacy: [legacy])
        XCTAssertTrue(store.migrationRequired)
        await store.migrateLegacyHistory()
        XCTAssertFalse(store.migrationRequired)
        store.setDraft("下次继续的消息", in: legacy.id); store.saveNow()
        let restored = ConversationStore(directory: directory, legacy: [legacy, legacy])
        XCTAssertEqual(restored.conversations.count, 1)
        XCTAssertEqual(restored.conversation(legacy.id)?.draft, "下次继续的消息")
        XCTAssertEqual(restored.conversation(legacy.id)?.messages.first?.text, "旧任务")
    }
    func testQueuedToolStartCannotUndoApprovalState() throws {
        let store = ConversationStore(inMemory: true), id = store.create(mode: .demo)
        let token = try XCTUnwrap(store.begin(in: id, query: "test"))
        store.updateTool(callID: "one", name: "tap", state: .awaitingApproval, detail: "正确详情", identity: token)
        store.updateTool(callID: "one", name: "tap", state: .running, identity: token)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.state, .awaitingApproval)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.detail, "正确详情")
    }
}

@MainActor final class ConversationRuntimeTests: XCTestCase {
    func testToolReceiptsAreSavedBeforeNextModelRequest() async throws {
        let store = ConversationStore(inMemory: true)
        let provider = ReceiptInspectionProvider {
            let tools = store.conversations.flatMap(\.messages).compactMap(\.tool)
            XCTAssertEqual(tools.map(\.callID), ["receipt-1", "receipt-2"])
            XCTAssertEqual(tools.map(\.state), [.succeeded, .succeeded])
            XCTAssertTrue(tools.allSatisfy { $0.result == "Wait completed." })
        }
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: .init(provider: provider, bridge: UnavailableBridge()))
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("顺序回执验证", in: id, cloudConsent: true))
        try await waitUntil { !model.running }
        XCTAssertEqual(store.conversation(id)?.phase, .completed)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .completed)
        XCTAssertNil(model.activitySnapshot?.state.operation)
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("Timed out waiting for deterministic offline runtime")
        throw AppError.timeout
    }
    func testDemoUsesRealAgentLoopAndStructuredToolEvents() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        defer { model.stop() }
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("演示", in: id))
        try await waitUntil { model.approval(in: id) != nil }
        let approval = try XCTUnwrap(model.approval(in: id))
        model.approve(true, approvalID: approval.id, conversationID: id)
        try await waitUntil { !model.running }
        let session = try XCTUnwrap(store.conversation(id))
        XCTAssertEqual(session.phase, .completed)
        XCTAssertEqual(session.messages.compactMap(\.tool).map(\.name), ["screenshot", "tap", "screenshot", "finish"])
        XCTAssertTrue(session.messages.compactMap(\.tool).allSatisfy { $0.state == .succeeded })
        XCTAssertTrue(session.messages.contains { $0.role == .assistant && $0.text.contains("离线脚本") })
    }
    func testToolFailureReachesNextModelTurnWithoutDuplicateNotice() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: AgentRunServices(provider: ToolErrorFixtureProvider(), bridge: UnavailableBridge()))
        defer { model.stop() }
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("查看屏幕", in: id, cloudConsent: true))
        try await waitUntil { !model.running }
        let session = try XCTUnwrap(store.conversation(id))
        let tools = session.messages.compactMap(\.tool)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.callID, "fixture-screenshot")
        XCTAssertEqual(tools.first?.state, .failed)
        XCTAssertEqual(tools.first?.result, UnavailableBridge.screenshotMessage)
        // The fixture emits this only after validating the exact ERROR result,
        // role=tool and matching call ID in the real framework's next request.
        XCTAssertEqual(session.messages.last?.role, .assistant)
        XCTAssertEqual(session.messages.last?.text, ToolErrorFixtureProvider.reply)
        XCTAssertFalse(session.messages.contains { $0.role == .notice })
        XCTAssertEqual(session.phase, .completed)
        XCTAssertNil(model.approval)
        XCTAssertNil(store.activeRun)
    }
    func testEmptyReplyAfterToolFailureDoesNotReuseNarrationOrAddNotice() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: AgentRunServices(provider: ToolErrorFixtureProvider(initialText: "我会查看屏幕。", finalReply: ""), bridge: UnavailableBridge()))
        defer { model.stop() }
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("查看屏幕", in: id, cloudConsent: true))
        try await waitUntil { !model.running }
        let session = try XCTUnwrap(store.conversation(id))
        XCTAssertEqual(session.phase, .blocked)
        XCTAssertEqual(session.messages.last?.tool?.state, .failed)
        XCTAssertFalse(session.messages.contains { $0.role == .notice })
        XCTAssertEqual(session.messages.filter { $0.role == .assistant }.map(\.text), ["我会查看屏幕。"])
    }
    func testConcurrentSessionsKeepApprovalsAndCancelIndependently() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        let a = model.createConversation(mode: .demo)
        let first = AgentPresentationAdapter(model: model, sessionID: a)
        XCTAssertTrue(first.dispatch(.send(sessionID: a, text: "A", cloudConsent: false)))
        try await waitUntil { first.pendingApproval != nil }
        let approvalA = try XCTUnwrap(first.pendingApproval)
        first.close()
        XCTAssertTrue(first.running)
        XCTAssertNotNil(first.pendingApproval)
        let b = model.createConversation(mode: .demo)
        let second = AgentPresentationAdapter(model: model, sessionID: b)
        XCTAssertTrue(second.dispatch(.send(sessionID: b, text: "B", cloudConsent: false)))
        try await waitUntil { second.pendingApproval != nil }
        let approvalB = try XCTUnwrap(second.pendingApproval)
        XCTAssertEqual(store.activeRuns.count, 2)
        XCTAssertNotEqual(approvalA.image?.id, approvalB.image?.id)
        XCTAssertFalse(first.dispatch(.approve(step: approvalA.identity, approvalID: approvalA.approval!.id)))
        XCTAssertTrue(second.dispatch(.stop(run: approvalB.identity.run)))
        try await waitUntil { !second.stopping }
        XCTAssertTrue(first.running)
        XCTAssertEqual(first.pendingApproval?.approval?.id, approvalA.approval?.id)
        XCTAssertEqual(store.activeRuns.count, 1)
        first.open()
        XCTAssertFalse(first.dispatch(.stop(run: approvalB.identity.run)))
        XCTAssertTrue(first.dispatch(.approve(step: approvalA.identity, approvalID: approvalA.approval!.id)))
        try await waitUntil { !first.running && !first.stopping }
        XCTAssertEqual(store.conversation(a)?.phase, .completed)
        XCTAssertEqual(store.conversation(b)?.phase, .stopped)
        XCTAssertEqual(store.conversation(a)?.messages.compactMap(\.tool).filter { $0.name == "tap" && $0.state == .succeeded }.count, 1)
        XCTAssertFalse(store.conversation(b)?.messages.compactMap(\.tool).contains { $0.name == "tap" && $0.state == .succeeded } ?? true)
    }
    func testParallelStoreCallbacksRemainScopedAfterOneRunEnds() throws {
        let store = ConversationStore(inMemory: true)
        let a = store.create(mode: .demo), b = store.create(mode: .demo)
        let first = try XCTUnwrap(store.begin(in: a, query: "A"))
        let second = try XCTUnwrap(store.begin(in: b, query: "B"))
        store.beginAssistantTurn(first); store.beginAssistantTurn(second)
        store.appendText("first", identity: first); store.appendText("second", identity: second)
        store.finish(first, phase: .stopped, summary: "")
        store.appendText("late", identity: first)
        store.appendText(" continues", identity: second)
        XCTAssertEqual(store.activeRuns[b], second)
        XCTAssertNil(store.activeRuns[a])
        XCTAssertEqual(store.conversation(b)?.messages.last?.text, "second continues")
        XCTAssertFalse(store.conversation(a)?.messages.contains { $0.text.contains("late") } ?? true)
    }
    func testBackgroundCancellationFencesLateEvents() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("停止测试", in: id))
        model.setForeground(false)
        try await waitUntil { !model.stopping }
        XCTAssertEqual(store.conversation(id)?.phase, .interrupted)
        XCTAssertNil(store.activeRun)
        XCTAssertNil(model.approval)
        XCTAssertFalse(model.send("后台不能发送", in: id))
    }
    func testLiveSendRequiresExplicitConsentBeforeReadingKeysOrRunning() {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        let id = model.createConversation(mode: .live)
        XCTAssertFalse(model.send("测试", in: id))
        XCTAssertFalse(model.running)
        XCTAssertTrue(store.conversation(id)?.messages.isEmpty == true)
    }
}

private struct ReceiptInspectionProvider: ModelProvider {
    static let name = "receipt-inspection"
    let configuration = DemoProvider().configuration
    let inspect: @MainActor @Sendable () -> Void
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        if fixtureMessages(request).contains(where: { $0.role == .tool }) {
            await inspect()
            return ModelResponse(text: "回执验证完成", finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: "", finishReason: .toolCalls, toolCalls: [
            .init(id: "receipt-1", name: "wait", arguments: "{\"duration_ms\":1}"),
            .init(id: "receipt-2", name: "wait", arguments: "{\"duration_ms\":1}")
        ], request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.terminal(response)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
