import Foundation

/// There is one app process, one conversation store, and independently lifecycle-managed conversation runners.
@MainActor final class PhoneAgentRuntime {
    static let shared = PhoneAgentRuntime()
    let model: AgentViewModel
    let commands: SessionCommandService
    // Intentionally dormant: only explicit local provisioning may call start.
    let remoteTools: RemoteToolsService
    let museConnection: RemoteConnectionController
    private init() {
        model = Self.makeModel()
        commands = SessionCommandService(sessions: model.sessions, runner: model)
        remoteTools = RemoteToolsService(model: model)
        museConnection = RemoteConnectionController.make(service: remoteTools, model: model)
    }
    #if DEBUG
    private var invokedSiriFixture = false
    func invokeSiriFixtureIfNeeded(busy: Bool) async {
        let arguments = ProcessInfo.processInfo.arguments
        let flag = busy ? "--ui-test-siri-busy" : "--ui-test-siri-warm"
        guard arguments.contains("--ui-testing"), arguments.contains(flag), !invokedSiriFixture else { return }
        invokedSiriFixture = true
        let intent = PrepareAgentTaskIntent(); intent.task = "查看演示计数器"
        do { _ = try await intent.perform() }
        catch { model.errorMessage = error.localizedDescription }
    }
    #endif
    #if DEBUG
    private var delayedBackgroundUIRun: RunIdentity?
    func completeBackgroundUIFixtureIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--ui-test-background-completion"),
              let run = model.sessions.activeRun else { return }
        model.sessions.completeAssistantTurn("后台任务最终回复", identity: run)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-background-auto-route") {
            model.openActivityURL(AgentActivityRoute(sessionID: run.conversationID, runID: run.runID).url)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-background-delayed-finish") {
            delayedBackgroundUIRun = run
        } else { model.sessions.finish(run, phase: .completed, summary: "") }
    }
    func finishForegroundUIFixtureIfNeeded() {
        guard let run = delayedBackgroundUIRun else { return }
        delayedBackgroundUIRun = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            model.sessions.finish(run, phase: .completed, summary: "")
        }
    }
    #endif
    private static func makeModel() -> AgentViewModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--task-pip-probe") {
            let sessions = ConversationStore(inMemory: true)
            let id = sessions.create(mode: .demo)
            let streamProbe = ProcessInfo.processInfo.arguments.contains("--background-stream-probe")
            if streamProbe, let run = sessions.begin(in: id, query: "离线后台流式更新验证") {
                for index in 0..<30 {
                    sessions.beginAssistantTurn(run)
                    sessions.completeAssistantTurn("", reasoning: String(repeating: "离线思考内容。", count: 100), identity: run)
                    sessions.updateTool(callID: "seed-\(index)", name: "drag", state: .succeeded, result: "Synthetic receipt.", identity: run)
                }
                sessions.finish(run, phase: .completed, summary: "")
            }
            let primary: any RunBackgroundScheduler = ProcessInfo.processInfo.arguments.contains("--activity-probe-no-system")
                ? ActivityOnlyProbeScheduler() : ContinuedProcessingScheduler()
            BackgroundExecutionCoordinator.shared.applySelection(streamProbe ? [.audio] : [.audio, .systemTask])
            let lifecycle = RunLifecycleCoordinator(
                scheduler: CompositeRunScheduler(primary: streamProbe ? nil : primary, allowed: { streamProbe ? [.audio] : [.audio, .systemTask] }),
                storage: MemoryRunCheckpointStore())
            return AgentViewModel(sessions: sessions, loadPersistentState: false,
                runServices: .init(provider: TaskPiPProbeProvider(), bridge: DemoBridge()),
                lifecycle: lifecycle, backgroundCoordinator: .shared, liveActivitiesEnabled: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] == "1" {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-test-reasoning-seed") || arguments.contains("--ui-test-reasoning-restore") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentReasoningUITest", isDirectory: true)
                if arguments.contains("--ui-test-reasoning-seed") { try? FileManager.default.removeItem(at: directory) }
                let sessions = ConversationStore(directory: directory)
                if sessions.conversations.isEmpty { sessions.create(mode: .live) }
                let outcome = arguments.contains("--ui-test-reasoning-paused") ? "paused" : (arguments.contains("--ui-test-reasoning-failed") ? "failed" : "completed")
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: ReasoningFixtureProvider(outcome: outcome), bridge: UnavailableBridge()))
            }
            if arguments.contains("--ui-test-images-seed") || arguments.contains("--ui-test-images-restore") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentImageUITest", isDirectory: true)
                if arguments.contains("--ui-test-images-seed") { try? FileManager.default.removeItem(at: directory) }
                let sessions = ConversationStore(directory: directory)
                if sessions.conversations.isEmpty { sessions.create(mode: .demo) }
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()),
                    attachments: AttachmentStore(directory: directory.appendingPathComponent("assets")))
            }
            if arguments.contains("--ui-test-siri-seed") || arguments.contains("--ui-test-siri-restore") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentSiriUITest", isDirectory: true)
                if arguments.contains("--ui-test-siri-seed") { try? FileManager.default.removeItem(at: directory) }
                let sessions = ConversationStore(directory: directory)
                if arguments.contains("--ui-test-siri-seed") {
                    _ = try? sessions.prepare(SessionCommand(.prepare("查看演示计数器")), task: "查看演示计数器")
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()))
            }
            let sessions = ConversationStore(inMemory: true)
            if arguments.contains("--ui-test-turn-summaries") {
                let id = sessions.create(mode: .live)
                if let run = sessions.begin(in: id, query: "汇总验收") {
                    for index in 1...2 {
                        sessions.beginAssistantTurn(run)
                        sessions.completeAssistantTurn("中间答复\(index)", reasoning: "第\(index)段思考内容", identity: run)
                        sessions.updateTool(callID: "summary-\(index)", name: "wait", state: .succeeded, result: "已等待", identity: run)
                    }
                    sessions.beginAssistantTurn(run)
                    sessions.completeAssistantTurn("汇总后的最终答复", identity: run)
                    sessions.finish(run, phase: .completed, summary: "")
                }
                if let run = sessions.begin(in: id, query: "只有正文") {
                    sessions.beginAssistantTurn(run)
                    sessions.completeAssistantTurn("没有工具和思考的答复", identity: run)
                    sessions.finish(run, phase: .completed, summary: "")
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false)
            }
            if arguments.contains("--ui-test-provider-key") {
                var keys: [String: String] = [:]
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false,
                    writeProviderKey: { keys[$1] = $0 }, containsProviderKey: { keys[$0] != nil })
                _ = model.saveProvider(ProviderProfile(name: "Key Fixture", settings: .init(baseURL: "https://fixture.invalid/v1", model: "fixture")), key: "UI_TEST_ONLY_NOT_A_REAL_KEY")
                return model
            }
            if arguments.contains("--ui-test-disclosure-scroll") {
                let id = sessions.create(mode: .live)
                for index in 0..<20 { sessions.addNotice("展开滚动验收 \(index)\n本地历史记录", in: id) }
                if let run = sessions.begin(in: id, query: "展开位置验收") {
                    sessions.beginAssistantTurn(run)
                    sessions.completeAssistantTurn("", reasoning: String(repeating: "长思考内容用于验证展开时保留阅读位置。\n", count: 100), identity: run)
                    sessions.updateTool(callID: "disclosure-tool", name: "list_apps", state: .succeeded,
                        result: String(repeating: "长工具结果用于验证展开时保留阅读位置。\n", count: 100) + "工具结果末尾标记", arguments: "{}", identity: run)
                    sessions.finish(run, phase: .completed, summary: "")
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false)
            }
            if arguments.contains("--ui-test-skill-tools") {
                sessions.create(mode: .live)
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: SkillFixtureProvider(), bridge: UnavailableBridge()))
            }
            if arguments.contains("--ui-test-attachments") {
                let id = sessions.create(mode: .demo)
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false)
                model.selectConversation(id)
                Task { @MainActor in
                    let frame = try? await DemoBridge().screenshot()
                    if let frame { try? await model.importDraftAttachment(data: frame.png, name: "synthetic.png", in: id) }
                    try? await model.importDraftAttachment(data: Data("Synthetic file contents".utf8), name: "synthetic.md", in: id)
                }
                return model
            }
            if arguments.contains("--ui-test-new-conversation") {
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: ReasoningFixtureProvider(), bridge: UnavailableBridge()))
            }
            if arguments.contains("--ui-test-composer-models") {
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false)
                try? model.providers.save(ProviderProfile(name: "Fixture One", settings: .init(baseURL: "https://fixture.invalid/v1", model: "model-a")))
                try? model.providers.save(ProviderProfile(name: "Fixture Two", settings: .init(baseURL: "https://fixture.invalid/v1", model: "model-b"), models: ["model-b-alt"]))
                return model
            }
            if arguments.contains("--ui-test-background-completion") {
                let id = sessions.create(mode: .live)
                if let run = sessions.begin(in: id, query: "后台完成刷新验收") {
                    for index in 0..<30 {
                        sessions.beginAssistantTurn(run)
                        sessions.completeAssistantTurn("中间回复 \(index)", reasoning: String(repeating: "合成思考内容。", count: 60), identity: run)
                        sessions.updateTool(callID: "background-\(index)", name: "wait", state: .succeeded, result: "Synthetic receipt.", identity: run)
                    }
                    sessions.beginAssistantTurn(run)
                    sessions.appendText("等待后台完成", identity: run)
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false)
            }
            if arguments.contains("--ui-test-composer-history") {
                let id = sessions.create(mode: .live)
                if arguments.contains("--ui-test-conversation-navigation"), let run = sessions.begin(in: id, query: "新会话") {
                    sessions.finish(run, phase: .completed, summary: "")
                }
                for index in 0..<30 {
                    sessions.addNotice("滚动验收 \(index)\n保持键盘开合前后的底部可见内容\n这是仅用于 UI 验收的本地记录", in: id)
                }
                sessions.addNotice("滚动验收最后一条消息", in: id)
                return AgentViewModel(sessions: sessions, loadPersistentState: false)
            }
            if arguments.contains("--ui-test-model-catalog") {
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false)
                try? model.providers.save(ProviderProfile(name: "Catalog Fixture", settings: .init(baseURL: "https://catalog-fixture.invalid/v1", model: "")))
                return model
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-tool-error") {
                sessions.create(mode: .live)
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: ToolErrorFixtureProvider(), bridge: UnavailableBridge()))
            }
            // Existing demo history keeps UI regression tests offline without
            // exposing a demo-creation route in the production conversation UI.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               (arguments.contains("--ui-test-demo-history") || arguments.contains("--ui-test-siri-busy")) {
                sessions.create(mode: .demo)
            }
            if arguments.contains("--ui-test-siri-warm") || arguments.contains("--ui-test-siri-busy") {
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()))
            }
            return AgentViewModel(sessions: sessions, loadPersistentState: false,
                liveActivitiesEnabled: arguments.contains("--ui-test-live-activity"))
        }
        #endif
        return AgentViewModel()
    }
}

#if DEBUG
/// Finite UIKit handoff only; intentionally creates no system progress card.
/// Used with the offline fixture to test the custom WidgetKit presentation alone.
@MainActor private final class ActivityOnlyProbeScheduler: RunBackgroundScheduler {
    private var leases: [String: ExecutionTransitionLease] = [:]
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        let lease = ExecutionTransitionLease()
        lease.begin()
        guard lease.valid else { throw AppError.unavailable(String(localized: "The diagnostic task was not granted background time")) }
        leases[identifier] = lease
        BackgroundExecutionTrace.record("activity.probeUIKitOnly")
        launched(lease)
    }
    func cancel(identifier: String) { leases.removeValue(forKey: identifier)?.complete(success: false) }
}
#endif
