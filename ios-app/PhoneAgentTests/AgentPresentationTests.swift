import XCTest
import SwiftAgentKit
@testable import PhoneAgent

@MainActor final class AgentPresentationTests: XCTestCase {
    func testConversationReasoningChoicePersistsAndValidatesModelScope() throws {
        let defaults = UserDefaults(suiteName: "conversation-effort-\(UUID())")!
        defer { defaults.removeObject(forKey: ProviderStore.storageKey) }
        let providers = ProviderStore(defaults: defaults)
        var profile = ProviderProfile(settings: .init(baseURL: "https://fixture.invalid/v1", model: "thinking"), models: ["plain"])
        var metadata = DiscoveredModel(id: "thinking", name: "Thinking")
        metadata.reasoningEfforts = ["low", "high"]
        profile.catalog = ModelCatalog(endpoint: try profile.catalogEndpoint(), fetchedAt: Date(), models: [metadata])
        var parameters = ModelParameters(); parameters.values["temperature"] = "0.2"
        profile.modelParameters = ["thinking": parameters]
        try providers.save(profile)
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false, providers: providers)
        let id = model.createConversation(mode: .live)
        let presentation = AgentPresentationAdapter(model: model, sessionID: id)
        presentation.selectReasoningEffort("high")
        let saved = try XCTUnwrap(ProviderStore(defaults: defaults).profile(profile.id))
        XCTAssertEqual(saved.parameters(for: "thinking").values["temperature"], "0.2")
        XCTAssertEqual(try saved.parameters(for: "thinking").requestFields(providerKind: saved.providerKind, model: saved.metadata(for: "thinking"))["reasoning_effort"] as? String, "high")
        presentation.selectReasoningEffort("unsupported")
        XCTAssertEqual(presentation.reasoningEffort, "high")
        presentation.selectModel("plain")
        XCTAssertNil(presentation.reasoningEffort)
        presentation.selectReasoningEffort("high")
        XCTAssertNil(presentation.reasoningEffort)
        presentation.selectModel("thinking")
        XCTAssertEqual(presentation.reasoningEffort, "high")
        let run = try XCTUnwrap(model.sessions.begin(in: id, query: "busy"))
        presentation.selectReasoningEffort("low")
        XCTAssertEqual(presentation.reasoningEffort, "high")
        model.sessions.finish(run, phase: .completed, summary: "")
        presentation.selectReasoningEffort(nil)
        XCTAssertNil(ProviderStore(defaults: defaults).profile(profile.id)?.parameters(for: "thinking").reasoningEffort)
    }
    func testConversationDraftInheritsChoiceAndCanBeDiscardedWithoutHistory() throws {
        let providers = ProviderStore(defaults: nil)
        let profile = ProviderProfile(settings: .init(model: "default"))
        try providers.save(profile)
        try providers.rememberSelection(providerID: profile.id, model: "last-selected")
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false, providers: providers)
        for _ in 0..<3 {
            let draft = model.createConversationDraft(mode: .live)
            XCTAssertEqual(model.selectedModel(in: draft), "last-selected")
            XCTAssertTrue(model.sessions.conversations.isEmpty)
            model.discardConversationDraft(draft)
            XCTAssertNil(model.sessions.conversation(draft))
            XCTAssertNil(model.existingExecutionModel(for: draft))
        }
        let saved = model.createConversation(mode: .live)
        model.discardConversationDraft(saved)
        XCTAssertEqual(model.sessions.conversations.map(\.id), [saved])
    }
    func testLastModelChoiceDefaultsNewSessionsWithoutChangingExistingSessions() throws {
        let providers = ProviderStore(defaults: nil)
        let first = ProviderProfile(name: "First", settings: .init(model: "first"))
        let second = ProviderProfile(name: "Second", settings: .init(model: "second"))
        try providers.save(first); try providers.save(second)
        let sessions = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: sessions, loadPersistentState: false, providers: providers)
        let old = model.createConversation(mode: .live)
        XCTAssertEqual(model.selectedProvider(in: old)?.id, first.id)
        let chosen = model.createConversation(mode: .live)
        model.selectProvider(second.id, in: chosen)
        model.selectModel("custom-model", in: chosen)
        model.selectConversation(old)
        XCTAssertEqual(model.selectedModel(in: old), "first")
        let fresh = model.createConversation(mode: .live)
        XCTAssertEqual(model.selectedProvider(in: fresh)?.id, second.id)
        XCTAssertEqual(model.selectedModel(in: fresh), "custom-model")
        XCTAssertEqual(providers.profile(second.id)?.settings.model, "second")
        model.selectModel("ignored", in: UUID())
        let run = try XCTUnwrap(sessions.begin(in: fresh, query: "busy"))
        model.selectProvider(first.id, in: fresh)
        model.selectModel("ignored", in: fresh)
        XCTAssertEqual(providers.lastSelection, .init(providerID: second.id, model: "custom-model"))
        sessions.finish(run, phase: .completed, summary: "")
    }
    func testLastSelectionSurvivesReloadAndRemovedProviderFallsBack() throws {
        let defaults = UserDefaults(suiteName: "last-selection-\(UUID())")!
        defer { defaults.removeObject(forKey: ProviderStore.storageKey) }
        let store = ProviderStore(defaults: defaults)
        let first = ProviderProfile(settings: .init(model: "first"))
        let second = ProviderProfile(settings: .init(model: "second"))
        try store.save(first); try store.save(second)
        try store.rememberSelection(providerID: second.id, model: "outside-catalog")
        let restored = ProviderStore(defaults: defaults)
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false, providers: restored)
        let session = model.createConversation(mode: .live)
        XCTAssertEqual(model.selectedProvider(in: session)?.id, second.id)
        XCTAssertEqual(model.selectedModel(in: session), "outside-catalog")
        try restored.remove(second.id)
        XCTAssertEqual(restored.defaultSelection?.profile.id, first.id)
        try restored.restore(second.id)
        XCTAssertEqual(restored.defaultSelection?.model, "outside-catalog")
        try restored.rememberSelection(providerID: second.id, model: "")
        XCTAssertEqual(restored.defaultSelection?.model, "second")
        try restored.remove(first.id); try restored.remove(second.id)
        XCTAssertNil(restored.defaultSelection)
    }
    func testSavedProviderKeyPresenceIsScopedAndEmptySavePreservesSyntheticKey() throws {
        var keys: [String: String] = [:]
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            writeProviderKey: { keys[$1] = $0 }, containsProviderKey: { keys[$0] != nil })
        let draft = ProviderProfile(settings: .init(baseURL: "https://key-fixture.invalid/v1", model: "fixture"))
        XCTAssertFalse(model.hasSavedProviderKey(for: draft))
        XCTAssertTrue(model.saveProvider(draft, key: "UI_TEST_KEY_A"))
        let saved = try XCTUnwrap(model.providers.profile(draft.id))
        XCTAssertTrue(model.hasSavedProviderKey(for: saved))
        var changed = saved
        changed.settings.baseURL = " https://key-fixture.invalid/v1/ "
        XCTAssertTrue(model.hasSavedProviderKey(for: changed))
        changed.settings.baseURL = "https://different.invalid/v1"
        XCTAssertFalse(model.hasSavedProviderKey(for: changed))
        changed = saved; changed.protocolKind = .openRouter
        XCTAssertFalse(model.hasSavedProviderKey(for: changed))
        changed = saved; changed.id = UUID()
        XCTAssertFalse(model.hasSavedProviderKey(for: changed))
        XCTAssertTrue(model.saveProvider(saved, key: ""))
        XCTAssertEqual(keys[saved.keyAccount], "UI_TEST_KEY_A")
        XCTAssertTrue(model.saveProvider(saved, key: "UI_TEST_KEY_B"))
        XCTAssertEqual(keys[saved.keyAccount], "UI_TEST_KEY_B")
        keys.removeValue(forKey: saved.keyAccount)
        XCTAssertFalse(model.hasSavedProviderKey(for: saved))
    }
    func testLongToolResultsSurviveProjectionUpdateAndHistoryRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory), id = store.create(mode: .live)
        let run = try XCTUnwrap(store.begin(in: id, query: "long result"))
        let call = AgentToolCall(id: "apps", name: "list_apps", parameters: [:])
        let text = String(repeating: "完整结果\n", count: 2_000) + "RESULT_END"
        AgentEventProjection.record(.toolCallsReceived([call]), run: run, frame: nil, in: store)
        AgentEventProjection.record(.toolExecutionFinished(call: call, result: .success(toolCallId: call.id, toolName: call.name, result: text)), run: run, frame: nil, in: store)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.result, text)
        store.updateTool(callID: "new", name: "load_skill", state: .succeeded, result: text, identity: run)
        store.finish(run, phase: .completed, summary: "")
        store.saveNow()
        let restored = ConversationStore(directory: directory)
        XCTAssertEqual(restored.conversation(id)?.messages.compactMap(\.tool).map(\.result), [text, text])
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("Offline runtime did not reach expected state")
        throw AppError.timeout
    }
    private func pendingDemo() async throws -> (AgentViewModel, AgentPresentationAdapter, ToolPresentation) {
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
        let id = model.createConversation(mode: .demo)
        let ui = AgentPresentationAdapter(model: model, sessionID: id)
        XCTAssertTrue(ui.dispatch(.send(sessionID: id, text: "演示", cloudConsent: false)))
        try await waitUntil { ui.approvalID != nil }
        let message = try XCTUnwrap(ui.session?.messages.last { $0.tool?.name == "tap" })
        return (model, ui, try XCTUnwrap(ui.presentation(for: message)))
    }
    func testNoArgumentToolsHaveNoParameterPreview() {
        for name in ["screenshot", "list_apps"] {
            XCTAssertNil(AgentEventProjection.arguments(for: AgentToolCall(id: "empty", name: name, parameters: [:])))
        }
    }
    func testApprovalUsesSessionRunStepAndRequestIdentityAndConsumesOnce() async throws {
        let (model, ui, item) = try await pendingDemo()
        defer { model.stop() }
        let approval = try XCTUnwrap(item.approval)
        XCTAssertEqual(ui.pendingApproval?.identity, item.identity)
        XCTAssertEqual(ui.pendingApproval?.approval?.id, approval.id)
        XCTAssertEqual(ui.pendingApproval?.image?.id, approval.imageID)
        XCTAssertFalse(ui.dispatch(.approve(step: StepIdentity(run: RunIdentity(conversationID: UUID(), runID: item.identity.run.runID), stepID: item.identity.stepID), approvalID: approval.id)))
        XCTAssertFalse(ui.dispatch(.approve(step: StepIdentity(run: RunIdentity(conversationID: ui.sessionID, runID: UUID()), stepID: item.identity.stepID), approvalID: approval.id)))
        XCTAssertFalse(ui.dispatch(.approve(step: StepIdentity(run: item.identity.run, stepID: "other-step"), approvalID: approval.id)))
        XCTAssertFalse(ui.dispatch(.approve(step: item.identity, approvalID: UUID())))
        XCTAssertTrue(ui.dispatch(.approve(step: item.identity, approvalID: approval.id)))
        XCTAssertNil(ui.pendingApproval)
        XCTAssertFalse(ui.dispatch(.approve(step: item.identity, approvalID: approval.id)))
        try await waitUntil { !model.running }
        XCTAssertEqual(ui.session?.messages.compactMap(\.tool).filter { $0.name == "tap" && $0.state == .succeeded }.count, 1)
    }
    func testDenyIsDistinctFromStopAndReleasesPendingApproval() async throws {
        let (model, ui, item) = try await pendingDemo()
        let approval = try XCTUnwrap(item.approval)
        XCTAssertTrue(ui.dispatch(.deny(step: item.identity, approvalID: approval.id)))
        XCTAssertFalse(ui.dispatch(.approve(step: item.identity, approvalID: approval.id)))
        try await waitUntil { !model.stopping }
        XCTAssertNil(model.approval); XCTAssertNil(ui.activeRun)
        XCTAssertNil(ui.pendingApproval)
        XCTAssertEqual(ui.session?.phase, .blocked)
        XCTAssertEqual(ui.session?.messages.compactMap(\.tool).last?.state, .denied)
        XCTAssertFalse(ui.session?.messages.compactMap(\.tool).contains { $0.name == "tap" && $0.state == .succeeded } ?? true)
        // A new, explicit send is possible after cleanup; nothing resumes itself.
        XCTAssertTrue(ui.dispatch(.send(sessionID: ui.sessionID, text: "新一轮", cloudConsent: false)))
        model.stop()
        try await waitUntil { !model.stopping }
    }
    func testStopReleasesApprovalAndStaleStopCannotCancelNextRun() async throws {
        let (model, ui, item) = try await pendingDemo()
        XCTAssertTrue(ui.dispatch(.stop(run: item.identity.run)))
        XCTAssertFalse(ui.dispatch(.stop(run: item.identity.run)))
        try await waitUntil { !model.stopping }
        XCTAssertEqual(ui.session?.phase, .stopped)
        XCTAssertEqual(ui.session?.messages.compactMap(\.tool).last?.state, .cancelled)
        XCTAssertNil(model.approval)
        XCTAssertNil(ui.pendingApproval)
        XCTAssertTrue(ui.dispatch(.send(sessionID: ui.sessionID, text: "下一轮", cloudConsent: false)))
        XCTAssertFalse(ui.dispatch(.stop(run: item.identity.run)))
        XCTAssertTrue(model.running)
        model.stop(); try await waitUntil { !model.stopping }
    }
    func testScreenshotAndApprovalCannotAttachToHistoryOrOtherSession() async throws {
        let (model, ui, item) = try await pendingDemo()
        XCTAssertEqual(item.image?.id, item.approval?.imageID)
        let realMessage = try XCTUnwrap(ui.session?.messages.last { $0.tool?.name == "tap" })
        var historical = realMessage; historical.runID = UUID()
        XCTAssertNil(ui.presentation(for: historical)?.image)
        XCTAssertNil(ui.presentation(for: historical)?.approval)
        let otherID = model.createConversation(mode: .demo)
        let other = AgentPresentationAdapter(model: model, sessionID: otherID)
        XCTAssertNil(other.presentation(for: realMessage)?.image)
        XCTAssertNil(other.presentation(for: realMessage)?.approval)
        XCTAssertNil(other.pendingApproval)
        XCTAssertNotNil(ui.pendingApproval)
        model.stop()
        XCTAssertFalse(ui.dispatch(.send(sessionID: ui.sessionID, text: "过期窗口", cloudConsent: false)))
        try await waitUntil { !model.stopping }
    }
    func testRealEventsKeepProviderReasoningSeparateFromAnswerAndToolParameters() throws {
        let store = ConversationStore(inMemory: true), id = store.create(mode: .demo)
        let run = try XCTUnwrap(store.begin(in: id, query: "test"))
        AgentEventProjection.record(.llmCallStarted(turn: 1), run: run, frame: nil, in: store)
        AgentEventProjection.record(.streamChunk("公开"), run: run, frame: nil, in: store)
        AgentEventProjection.record(.reasoningChunk("服务商提供的可读摘要"), run: run, frame: nil, in: store)
        AgentEventProjection.record(.streamChunk("回复"), run: run, frame: nil, in: store)
        XCTAssertEqual(store.conversation(id)?.messages.last?.text, "公开回复")
        XCTAssertEqual(store.conversation(id)?.messages.last?.reasoning?.text, "服务商提供的可读摘要")
        let call = AgentToolCall(id: "t", name: "tap", parameters: ["x": AnyCodable(100), "y": AnyCodable(200), "purpose": AnyCodable("点击演示"), "api_key": AnyCodable("never-display")])
        AgentEventProjection.record(.toolCallsReceived([call]), run: run, frame: nil, in: store)
        let tool = try XCTUnwrap(store.conversation(id)?.messages.last?.tool)
        XCTAssertEqual(tool.state, .requested)
        let data = try XCTUnwrap(tool.arguments?.data(using: .utf8))
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(args["x"] as? Int, 100); XCTAssertEqual(args["api_key"] as? String, "never-display")
        store.finish(run, phase: .interrupted, summary: "")
        let before = store.conversation(id)?.messages
        AgentEventProjection.record(.streamChunk("late"), run: run, frame: nil, in: store)
        AgentEventProjection.record(.toolExecutionStarted(call: call), run: run, frame: nil, in: store)
        XCTAssertEqual(store.conversation(id)?.messages, before)
    }
    func testDeniedStepCannotBeRevivedByQueuedEvents() throws {
        let store = ConversationStore(inMemory: true), id = store.create(mode: .demo)
        let run = try XCTUnwrap(store.begin(in: id, query: "test"))
        store.updateTool(callID: "t", name: "tap", state: .denied, result: "拒绝", identity: run)
        store.updateTool(callID: "t", name: "tap", state: .succeeded, result: "错误成功", identity: run)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.state, .denied)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.result, "拒绝")
    }
    func testSavingProviderIsBlockedDuringRunAndCleanup() async throws {
        let (model, ui, item) = try await pendingDemo()
        // This deliberately invalid configuration would fail before any secret
        // access even if the guard regressed. No real credential is read/written.
        let profile = ProviderProfile(settings: ProviderSettings(baseURL: "invalid", model: ""))
        XCTAssertFalse(model.saveProvider(profile, key: ""))
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(ui.dispatch(.stop(run: item.identity.run)))
        XCTAssertFalse(model.saveProvider(profile, key: ""))
        XCTAssertNil(model.errorMessage)
        try await waitUntil { !model.stopping }
    }
}
