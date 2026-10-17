import XCTest
import AppIntents
@testable import PhoneAgent

@MainActor private final class CommandMockRunner: SessionCommandRunning {
    var currentRun: RunIdentity?
    var commandCanStart = true
    var commandStartError: String?
    var commandBusy = false
    var commandStatus: SessionPublicStatus = .idle
    var starts: [UUID] = []
    var startHandler: ((String, UUID) -> Bool)?
    func startCommandTask(_ task: String, in sessionID: UUID) -> Bool {
        starts.append(sessionID); return startHandler?(task, sessionID) ?? false
    }
    var cancellations: [RunIdentity] = []
    func cancelCommandRun(_ identity: RunIdentity) -> Bool {
        guard currentRun == identity else { return false }
        cancellations.append(identity); currentRun = nil; commandStatus = .stopping
        return true
    }
}

@MainActor final class SessionCommandTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testRejectedStartReportsItsSpecificReason() throws {
        let store = ConversationStore(inMemory: true), runner = CommandMockRunner()
        runner.commandStartError = "设备连接操作尚未结束，请稍后重试"
        let service = SessionCommandService(sessions: store, runner: runner)
        XCTAssertThrowsError(try service.perform(SessionCommand(.execute("任务")))) {
            XCTAssertEqual($0.localizedDescription, runner.commandStartError)
        }
    }
    func testSendWhileInactiveReportsForegroundReasonWithoutStarting() {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        let id = model.createConversation(mode: .live)
        model.setForeground(false)
        XCTAssertFalse(model.send("任务", in: id, cloudConsent: true))
        XCTAssertEqual(model.errorMessage, "执言尚未进入前台，任务未开始")
        XCTAssertNil(model.currentRun)
    }
    func testDirectExecuteInitializesDefaultProviderWithoutOpeningConversation() async throws {
        let store = ConversationStore(inMemory: true), providers = ProviderStore(defaults: nil)
        let profile = ProviderProfile(name: "Siri default", settings: .init(baseURL: "https://example.com/v1", model: "test-model"))
        try providers.save(profile)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()), providers: providers)
        let service = SessionCommandService(sessions: store, runner: model)
        model.setProtectedDataAvailable(false)
        XCTAssertEqual(try service.perform(SessionCommand(.execute("查看屏幕"))), .deferred)
        XCTAssertNil(model.currentRun)
        model.setProtectedDataAvailable(true)
        service.resumePendingExecutions()
        let session = try XCTUnwrap(store.conversations.first)
        XCTAssertEqual(session.providerID, profile.id)
        XCTAssertEqual(session.modelID, "test-model")
        XCTAssertEqual(session.entry?.state, .submitted)
        let run = try XCTUnwrap(model.currentRun)
        XCTAssertTrue(model.stop(run: run))
        try await waitUntil { !model.stopping }
    }
    func testBackgroundExecuteCreatesIndependentSessionWithoutForegroundOrReplay() async throws {
        let store = ConversationStore(inMemory: true)
        let activity = BackgroundExecutionRegistry.shared
        BackgroundExecutionCoordinator.shared.applySelection([.audio])
        BackgroundExecutionCoordinator.shared.setResident(true)
        defer { BackgroundExecutionCoordinator.shared.setResident(false) }
        let owner = UUID()
        activity.update(owner: owner, active: true)
        defer { activity.update(owner: owner, active: false) }
        let lifecycle = RunLifecycleCoordinator(scheduler: CompositeRunScheduler(registry: activity, allowed: { [.audio] }), storage: MemoryRunCheckpointStore())
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()), lifecycle: lifecycle)
        XCTAssertTrue(model.commandNeedsForeground)
        model.setScene(.background) // A cold launch in background is not a warm App.
        XCTAssertTrue(model.commandNeedsForeground)
        model.setScene(.active)
        let existing = store.create(mode: .live)
        XCTAssertFalse(model.commandNeedsForeground)
        model.setScene(.background)
        XCTAssertFalse(model.commandNeedsForeground)
        XCTAssertTrue(model.commandCanStart)
        let service = SessionCommandService(sessions: store, runner: model)
        let command = SessionCommand(.execute("后台新任务"))
        guard case .started(let id) = try service.perform(command) else { return XCTFail("Should start in background") }
        XCTAssertNotEqual(id, existing)
        XCTAssertEqual(store.conversation(id)?.entry?.state, .submitted)
        XCTAssertNil(service.pendingRoute)
        let run = try XCTUnwrap(model.currentRun)
        XCTAssertEqual(try service.perform(command), .started(id))
        XCTAssertEqual(model.currentRun, run)
        XCTAssertEqual(store.conversations.count, 2)
        // A regular UI send still cannot start another turn from the background.
        XCTAssertFalse(model.send("普通发送", in: existing, cloudConsent: true))
        XCTAssertTrue(model.stop(run: run))
        try await waitUntil { !model.hasBusySessions }
    }
    func testWarmIdleBackgroundRequiresForegroundUntilPlaybackIsActuallyActive() {
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
        model.setScene(.active)
        XCTAssertFalse(model.commandNeedsForeground)
        model.setScene(.background)
        XCTAssertTrue(model.commandNeedsForeground)
        let owner = UUID()
        BackgroundExecutionCoordinator.shared.applySelection([.audio])
        BackgroundExecutionCoordinator.shared.setResident(true)
        defer { BackgroundExecutionCoordinator.shared.setResident(false) }
        BackgroundExecutionRegistry.shared.update(owner: owner, active: true)
        XCTAssertFalse(model.commandNeedsForeground)
        BackgroundExecutionRegistry.shared.update(owner: owner, active: false)
        XCTAssertTrue(model.commandNeedsForeground)
        model.setScene(.inactive) // Siri can cover an idle App without granting playback.
        XCTAssertTrue(model.commandNeedsForeground)
        model.setScene(.active)
        XCTAssertFalse(model.commandNeedsForeground)
    }
    func testBackgroundExecuteWaitsForUnlockAndDoesNotCreateRun() throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        model.setScene(.background)
        model.setProtectedDataAvailable(false)
        let service = SessionCommandService(sessions: store, runner: model)
        XCTAssertFalse(model.commandCanStart)
        XCTAssertEqual(try service.perform(SessionCommand(.execute("锁屏任务"))), .deferred)
        XCTAssertNil(model.currentRun)
        XCTAssertEqual(store.conversations.first?.entry?.state, .pendingConfirmation)
    }
    func testInactiveHandoffStartsOnlyOnceWhenActiveAndDoesNotSurviveRelaunch() throws {
        let store = ConversationStore(inMemory: true), runner = CommandMockRunner()
        runner.commandCanStart = false
        runner.startHandler = { text, id in store.begin(in: id, query: text) != nil }
        let service = SessionCommandService(sessions: store, runner: runner)
        let command = SessionCommand(.execute("前台就绪后执行"))
        XCTAssertEqual(try service.perform(command), .deferred)
        service.resumePendingExecutions()
        XCTAssertTrue(runner.starts.isEmpty)
        runner.commandCanStart = true
        SessionCommandService(sessions: store, runner: runner).resumePendingExecutions()
        XCTAssertTrue(runner.starts.isEmpty)
        service.resumePendingExecutions()
        service.resumePendingExecutions()
        XCTAssertEqual(runner.starts.count, 1)
        XCTAssertEqual(store.conversations.first?.entry?.state, .submitted)
    }
    func testDirectExecuteStartsOnceAndDoesNotReplayAfterRestore() throws {
        let folder = try directory(), store = ConversationStore(directory: folder)
        let runner = CommandMockRunner(), command = SessionCommand(.execute("立即执行"))
        runner.startHandler = { text, id in store.begin(in: id, query: text) != nil }
        let service = SessionCommandService(sessions: store, runner: runner)
        guard case .started(let id) = try service.perform(command) else { return XCTFail() }
        XCTAssertEqual(store.conversation(id)?.entry?.state, .submitted)
        XCTAssertNil(service.pendingRoute)
        XCTAssertEqual(try service.perform(command), .started(id))
        let restored = SessionCommandService(sessions: ConversationStore(directory: folder), runner: runner)
        XCTAssertEqual(try restored.perform(command), .started(id))
        XCTAssertEqual(runner.starts, [id])
    }
    func testDirectExecuteFailureDoesNotReportStarted() throws {
        let store = ConversationStore(inMemory: true), runner = CommandMockRunner()
        let service = SessionCommandService(sessions: store, runner: runner)
        XCTAssertThrowsError(try service.perform(SessionCommand(.execute("任务"))))
        XCTAssertNil(store.activeRun)
        XCTAssertEqual(store.conversations.first?.entry?.state, .pendingConfirmation)
    }
    func testPrepareValidatesBeforeSavingAndDoesNotRun() throws {
        let store = ConversationStore(inMemory: true), runner = CommandMockRunner()
        let service = SessionCommandService(sessions: store, runner: runner)
        for text in ["", " \n ", String(repeating: "字", count: 2_001)] {
            XCTAssertThrowsError(try service.perform(SessionCommand(.prepare(text))))
        }
        XCTAssertTrue(store.conversations.isEmpty)
        guard case .prepared(let id) = try service.perform(SessionCommand(.prepare("  打开计数器  "))) else { return XCTFail() }
        XCTAssertEqual(store.conversation(id)?.draft, "打开计数器")
        XCTAssertEqual(store.conversation(id)?.entry?.state, .pendingConfirmation)
        XCTAssertEqual(store.conversation(id)?.mode, .live)
        XCTAssertEqual(store.conversation(id)?.messages.count, 0)
        XCTAssertNil(runner.currentRun)
        XCTAssertTrue(runner.cancellations.isEmpty)
    }
    func testColdLaunchAndRetryRetainIdentityButIdenticalNewRequestIsDistinct() throws {
        let folder = try directory(), command = SessionCommand(.prepare("同一任务"))
        let original = ConversationStore(directory: folder)
        let first = try original.prepare(command, task: "同一任务")
        let restored = ConversationStore(directory: folder)
        let service = SessionCommandService(sessions: restored, runner: CommandMockRunner())
        XCTAssertEqual(service.pendingRoute, first)
        XCTAssertEqual(try service.perform(command), .prepared(first))
        XCTAssertEqual(restored.conversations.count, 1)
        _ = try service.perform(SessionCommand(.prepare("同一任务")))
        XCTAssertEqual(restored.conversations.count, 2)
        XCTAssertEqual(Set(restored.conversations.compactMap { $0.entry?.commandID }).count, 2)
        XCTAssertNil(restored.activeRun)
    }
    func testBusyOpenAllowsNavigationWithoutCancellingAnotherRun() throws {
        let store = ConversationStore(inMemory: true), runner = CommandMockRunner()
        runner.currentRun = RunIdentity(conversationID: UUID(), runID: UUID())
        runner.commandBusy = true; runner.commandStatus = .running
        let service = SessionCommandService(sessions: store, runner: runner)
        let id = try store.prepare(SessionCommand(.prepare("稍后任务")), task: "稍后任务")
        XCTAssertEqual(try service.perform(SessionCommand(.open, sessionID: id)), .open(id))
        XCTAssertNotNil(runner.currentRun)
        XCTAssertTrue(runner.cancellations.isEmpty)
        XCTAssertEqual(service.pendingRoute, id)
        runner.commandBusy = false
        XCTAssertEqual(try service.perform(SessionCommand(.open, sessionID: id)), .open(id))
    }
    func testCapturedCancelCannotStopLaterRunInSameSessionOrAnotherSession() throws {
        let runner = CommandMockRunner(), store = ConversationStore(inMemory: true)
        let service = SessionCommandService(sessions: store, runner: runner)
        let sessionID = UUID()
        runner.currentRun = RunIdentity(conversationID: sessionID, runID: UUID())
        let stale = service.cancelCurrentCommand()
        runner.currentRun = RunIdentity(conversationID: sessionID, runID: UUID())
        XCTAssertEqual(try service.perform(stale), .noMatchingRun)
        runner.currentRun = RunIdentity(conversationID: UUID(), runID: UUID())
        XCTAssertEqual(try service.perform(stale), .noMatchingRun)
        let valid = service.cancelCurrentCommand()
        XCTAssertEqual(try service.perform(valid), .cancelled)
        XCTAssertEqual(try service.perform(valid), .noMatchingRun)
        XCTAssertEqual(runner.cancellations.count, 1)
    }
    func testCancelCapturedWhenIdleNeverStopsFutureRun() throws {
        let runner = CommandMockRunner()
        let service = SessionCommandService(sessions: ConversationStore(inMemory: true), runner: runner)
        let idle = service.cancelCurrentCommand()
        runner.currentRun = RunIdentity(conversationID: UUID(), runID: UUID())
        XCTAssertEqual(try service.perform(idle), .noMatchingRun)
        XCTAssertTrue(runner.cancellations.isEmpty)
    }
    func testDismissedDraftDoesNotRouteAfterRestartOrRetry() throws {
        let folder = try directory(), command = SessionCommand(.prepare("取消草稿"))
        let store = ConversationStore(directory: folder)
        let id = try store.prepare(command, task: "取消草稿")
        try store.dismissPreparedTask(in: id)
        let restored = ConversationStore(directory: folder)
        let service = SessionCommandService(sessions: restored, runner: CommandMockRunner())
        XCTAssertNil(service.pendingRoute)
        XCTAssertEqual(restored.conversation(id)?.entry?.state, .dismissed)
        XCTAssertEqual(restored.conversation(id)?.draft, "")
        XCTAssertEqual(try service.perform(command), .prepared(id))
        XCTAssertNil(service.pendingRoute)
        XCTAssertThrowsError(try service.perform(SessionCommand(.open, sessionID: id)))
    }
    func testSubmittedDraftRecordsRunAndNeverResumesOnColdLaunch() throws {
        let folder = try directory(), store = ConversationStore(directory: folder)
        let id = try store.prepare(SessionCommand(.prepare("已确认")), task: "已确认")
        let identity = try XCTUnwrap(store.begin(in: id, query: "已确认"))
        let restored = ConversationStore(directory: folder)
        XCTAssertEqual(restored.conversation(id)?.entry?.runID, identity.runID)
        XCTAssertEqual(restored.conversation(id)?.entry?.state, .submitted)
        XCTAssertEqual(restored.conversation(id)?.phase, .interrupted)
        XCTAssertNil(restored.activeRun)
        XCTAssertNil(SessionCommandService(sessions: restored, runner: CommandMockRunner()).pendingRoute)
    }
    func testCorruptArchiveAndFailedWriteNeverClaimDraftSaved() throws {
        let folder = try directory(), file = folder.appendingPathComponent("conversations-v1.json")
        let broken = Data("preserve".utf8); try broken.write(to: file)
        let store = ConversationStore(directory: folder)
        XCTAssertThrowsError(try store.prepare(SessionCommand(.prepare("任务")), task: "任务"))
        XCTAssertEqual(try Data(contentsOf: file), broken)
        let another = try directory(), unavailable = ConversationStore(directory: another)
        try FileManager.default.removeItem(at: another)
        XCTAssertThrowsError(try unavailable.prepare(SessionCommand(.prepare("任务")), task: "任务"))
        XCTAssertTrue(unavailable.conversations.isEmpty)
    }
    func testStatusNeverIncludesTaskTextAndTracksRunner() throws {
        let runner = CommandMockRunner(), store = ConversationStore(inMemory: true)
        let service = SessionCommandService(sessions: store, runner: runner)
        XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(.idle))
        _ = try service.perform(SessionCommand(.prepare("private task secret")))
        XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(.pendingConfirmation))
        for state: SessionPublicStatus in [.running, .awaitingApproval, .stopping] {
            runner.commandStatus = state
            XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(state))
            XCTAssertFalse(state.message.contains("private task secret"))
        }
    }
    func testAuthenticationAndForegroundPolicy() {
        func requireLiveActivityIntent<T: LiveActivityIntent>(_: T.Type) {}
        requireLiveActivityIntent(PrepareAgentTaskIntent.self)
        // Siri prefers background execution and can request foreground on cold launch.
        XCTAssertEqual(PrepareAgentTaskIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(AgentTaskStatusIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(StopAgentTaskIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(PrepareAgentTaskIntent.supportedModes, [.background, .foreground(.dynamic)])
            XCTAssertEqual(AgentTaskStatusIntent.supportedModes, .background)
            XCTAssertEqual(StopAgentTaskIntent.supportedModes, .background)
        }
    }
    func testCancelledIntentDoesNotCreateDraft() async {
        let before = PhoneAgentRuntime.shared.model.sessions.conversations.count
        let operation = Task { @MainActor in
            await Task.yield()
            let intent = PrepareAgentTaskIntent(); intent.task = "cancelled utterance"
            _ = try await intent.perform()
        }
        operation.cancel()
        do { try await operation.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(PhoneAgentRuntime.shared.model.sessions.conversations.count, before)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw AppError.timeout
    }
    func testConfirmedSiriDraftUsesExistingApprovalAndScopedStop() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
                                  runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()))
        let service = SessionCommandService(sessions: store, runner: model)
        let id = try store.prepare(SessionCommand(.prepare("演示")), task: "演示")
        model.selectConversation(id)
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.send("演示", in: id)) // Authentication/dictation isn't cloud consent.
        XCTAssertTrue(model.send("演示", in: id, cloudConsent: true))
        try await waitUntil { model.approval != nil }
        XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(.awaitingApproval))
        XCTAssertEqual(store.conversation(id)?.entry?.runID, model.currentRun?.runID)
        let command = service.cancelCurrentCommand()
        XCTAssertEqual(try service.perform(command), .cancelled)
        try await waitUntil { !model.stopping }
        XCTAssertNil(model.approval)
        XCTAssertNil(model.currentRun)
        XCTAssertEqual(store.conversation(id)?.phase, .stopped)
        XCTAssertFalse(store.conversation(id)!.messages.contains { $0.tool?.name == "tap" && $0.tool?.state == .succeeded })
    }
}
