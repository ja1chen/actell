import Foundation
import SwiftUI
import Combine
import AgentKit
import ProviderCore

struct AgentRunServices {
    let provider: any ModelProvider
    let bridge: any DeviceBridge
}

@MainActor final class AgentViewModel: ObservableObject {
    @Published var goal = String(localized: "View the demo screen, tap the counter once, then check the result")
    @Published var mode: RunMode = .demo
    @Published var records: [TaskRecord] = []
    @Published private(set) var latestFrame: PresentedFrame?
    var latestImage: FrameImage? { latestFrame?.image }
    @Published var approval: Approval?
    @Published var running = false
    @Published var stopping = false
    @Published var status = String(localized: "The offline demo does not use the network or control real devices")
    @Published var bridgeStatus = String(localized: "The device bridge has not started")
    @Published private(set) var usbConnectionStatus: USBConnectionStatus = .idle
    let usbDiagnostics = USBDiagnosticsLog()
    lazy var museDiagnostics = MuseDiagnosticsLog()
    let capture: ScreenCaptureController
    private var previewTask: Task<Void, Never>?
    @Published private(set) var previewingCapture = false
    private var usbClient: (any USBConnectionSession)?
    private var usbGeneration = UUID()
    private let makeUSBClient: @MainActor (USBDiagnosticsLog, @escaping @Sendable (USBConnectionStatus) -> Void) -> any USBConnectionSession
    @Published var errorMessage: String?
    @Published var storageWarning: String?
    @Published private(set) var selectedConversationID: UUID?
    let providers: ProviderStore
    private let writeProviderKey: (String, String) throws -> Void
    private let containsProviderKey: (String) throws -> Bool
    let attachments: AttachmentStore
    let skills: SkillStore
    private var runSkillNames: [String: String] = [:]
    private var assetMutations = 0
    private var clearingAssets = false
    let sessions: ConversationStore
    let lifecycle: RunLifecycleCoordinator
    private let executionScheduler: RunExecutionScheduler
    private let executionBackground: BackgroundExecutionCoordinator
    private let allowSystemProcessing: Bool
    @Published private(set) var backgroundStatus = ""
    private var lifecycleSubscription: AnyCancellable?
    private var providerSubscription: AnyCancellable?
    private var screenExecutionContext: ScreenUSBExecutionContext?
    private let toolAuthorizationPolicy: ToolAuthorizationPolicy
    private var finishingRun = false
    private var protectedDataAvailable = true
    let liveActivities: AgentLiveActivityController
    let approvalRecords: ApprovalRecordStore
    @Published private(set) var activitySnapshot: AgentActivitySnapshot?
    @Published private(set) var activityNavigation: ActivityNavigation?
    @Published var activityLinkError: String?
    private var approvalTimeout: Task<Void, Never>?
    private var completedToolIDs: Set<String> = []
    private var activeActionCallID: String?
    // First display time of the current island status; clearing waits until the
    // minimum display duration has elapsed. A newer state cancels the clear.
    private var statusShownAt = Date.distantPast
    private var statusClearTask: Task<Void, Never>?
    // True from the model request start until any reply content arrives; the
    // island identity slot shows a distinct icon while this is set. Fully
    // independent from the right-side status lifecycle.
    private var modelReplyPending = false
    private var activityHandoffRun: RunIdentity?
    private var runIdentity: RunIdentity?
    var ownedRun: RunIdentity? { runIdentity }
    var currentRun: RunIdentity? {
        if let id = selectedConversationID, let run = sessionRuntimes[id]?.ownedRun { return run }
        return runIdentity ?? sessionRuntimes.values.compactMap(\.ownedRun).first
    }
    private var primarySessionID: UUID?
    private var sessionRuntimes: [UUID: AgentViewModel] = [:]
    private var sessionSubscriptions: [UUID: AnyCancellable] = [:]
    private weak var runtimeOwner: AgentViewModel?
    private let persistentRuntime: Bool
    private let runServicesFactory: (@MainActor (UUID) -> AgentRunServices)?
    var hasBusySessions: Bool { remoteLeaseID != nil || running || stopping || sessionRuntimes.values.contains { $0.running || $0.stopping } }
    var displayStatus: AgentStatusSnapshot {
        let worker = currentRun.flatMap { existingExecutionModel(for: $0.conversationID) } ?? self
        return .make(mode: worker.mode, phase: worker.activeRecord?.phase, running: worker.running, awaitingApproval: worker.approval != nil)
    }
    private var appOwner: AgentViewModel { runtimeOwner ?? self }
    func executionModel(for id: UUID) -> AgentViewModel {
        if let runtimeOwner { return runtimeOwner.executionModel(for: id) }
        if primarySessionID == nil { primarySessionID = id }
        if primarySessionID == id { return self }
        if let value = sessionRuntimes[id] { return value }
        let worker = AgentViewModel(sessions: sessions, loadPersistentState: persistentRuntime,
            backgroundCoordinator: allowSystemProcessing ? executionBackground : nil, approvalRecords: approvalRecords,
            attachments: attachments, skills: skills, providers: providers, sharedCapture: capture,
            sharedActivities: liveActivities, checkpointConversationID: id, restoreLegacyState: false,
            runServicesFactory: runServicesFactory, makeUSBClient: makeUSBClient, toolAuthorizationPolicy: toolAuthorizationPolicy)
        worker.runtimeOwner = self; worker.primarySessionID = id; worker.selectedConversationID = id
        worker.hasActivatedScene = hasActivatedScene
        worker.foreground = foreground; worker.currentScene = currentScene; worker.protectedDataAvailable = protectedDataAvailable
        worker.lifecycle.setForeground(foreground)
        sessionRuntimes[id] = worker
        sessionSubscriptions[id] = worker.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return worker
    }
    func existingExecutionModel(for id: UUID) -> AgentViewModel? {
        if let runtimeOwner { return runtimeOwner.existingExecutionModel(for: id) }
        return primarySessionID == id ? self : sessionRuntimes[id]
    }

    private var activeID: UUID?
    private var generation = UUID()
    private var runTask: Task<Void, Never>?
    var isListening: Bool { listenerTask != nil }
    private var listenerTask: Task<Void, Never>?
    private var listenerGeneration = UUID()
    // A warm Siri invocation may submit a new run without changing the scene.
    // Dispatch still requires the new run's own background lease.
    var commandCanStart: Bool { (foreground || hasActivatedScene) && protectedDataAvailable }
    var commandNeedsForeground: Bool {
        // A retained process/scene is not proof of background execution time.
        // Idle apps stop media playback and may already be suspended.
        !hasActivatedScene || !commandCanStart || (!foreground && !executionBackground.residentReady)
    }
    private var hasActivatedScene = false
    private var foreground = true
    private var healthObserver: UUID?
    private var agent: AgentRuntime?
    private var provider: (any CancellableModelProvider)?
    private var coordinator: ActionCoordinator?
    @Published private var remoteLeaseID: String?
    private var remoteRuntime: RemoteToolRuntime?
    private var remoteContinuityDemand: UUID?
    func endRemoteContinuity(releaseMedia: Bool = true) {
        if releaseMedia { DeviceControlCoordinator.shared.revokeMuseMediaRetention() }
        if let remoteContinuityDemand { executionBackground.releaseDemand(remoteContinuityDemand) }
        remoteContinuityDemand = nil
    }
    private func retainRemoteContinuity() {
        guard allowSystemProcessing else { return }
        endRemoteContinuity(releaseMedia: false)
        let allowed = executionBackground.selection.intersection(BackgroundMechanism.continuous)
        guard !allowed.isEmpty else { return }
        remoteContinuityDemand = executionBackground.acquireDemand(runID: UUID(), allowed: allowed, userInitiated: false)
    }
    private let makeRemoteBridge: (@MainActor () throws -> any DeviceBridge)?
    private var bridge: (any DeviceBridge)?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private let limits = AgentLimits()
    private let runServices: AgentRunServices?

    var activeRecord: TaskRecord? { records.first(where: { $0.id == activeID }) ?? records.first }
    var canResume: Bool { !running && !stopping && [.stopped, .interrupted, .blocked].contains(activeRecord?.phase ?? .idle) }
    init(sessions: ConversationStore? = nil, loadPersistentState: Bool = true, runServices: AgentRunServices? = nil,
         lifecycle: RunLifecycleCoordinator? = nil, backgroundCoordinator: BackgroundExecutionCoordinator? = nil,
         approvalRecords: ApprovalRecordStore? = nil, liveActivitiesEnabled: Bool? = nil,
         attachments: AttachmentStore? = nil, skills: SkillStore? = nil,
         providers: ProviderStore? = nil, sharedCapture: ScreenCaptureController? = nil,
         sharedActivities: AgentLiveActivityController? = nil, checkpointConversationID: UUID? = nil,
         makeRemoteBridge: (@MainActor () throws -> any DeviceBridge)? = nil,
         restoreLegacyState: Bool = true, runServicesFactory: (@MainActor (UUID) -> AgentRunServices)? = nil,
         writeProviderKey: @escaping (String, String) throws -> Void = { try SecretStore.save($0, account: $1) },
         containsProviderKey: @escaping (String) throws -> Bool = SecretStore.contains,
         makeUSBClient: @escaping @MainActor (USBDiagnosticsLog, @escaping @Sendable (USBConnectionStatus) -> Void) -> any USBConnectionSession = { USBCommandClient(diagnostics: $0, onProgress: $1) },
         toolAuthorizationPolicy: ToolAuthorizationPolicy = .fullAccess) {
        self.providers = providers ?? ProviderStore(defaults: loadPersistentState ? .standard : nil)
        self.writeProviderKey = writeProviderKey; self.containsProviderKey = containsProviderKey
        self.capture = sharedCapture ?? ScreenCaptureController()
        self.persistentRuntime = loadPersistentState; self.runServicesFactory = runServicesFactory
        self.skills = skills ?? SkillStore(inMemory: !loadPersistentState)
        self.attachments = attachments ?? AttachmentStore(directory: sessions?.storageRoot ?? (loadPersistentState ? nil : FileManager.default.temporaryDirectory.appendingPathComponent("test-assets-\(UUID())")))
        self.makeUSBClient = makeUSBClient
        self.approvalRecords = approvalRecords ?? ApprovalRecordStore(inMemory: !loadPersistentState)
        self.liveActivities = sharedActivities ?? AgentLiveActivityController(enabled: liveActivitiesEnabled ?? loadPersistentState)
        self.runServices = runServices
        self.toolAuthorizationPolicy = toolAuthorizationPolicy
        self.makeRemoteBridge = makeRemoteBridge
        self.executionBackground = backgroundCoordinator ?? .shared
        self.executionScheduler = RunExecutionScheduler(coordinator: self.executionBackground)
        self.allowSystemProcessing = loadPersistentState || backgroundCoordinator != nil
        var legacy: [TaskRecord] = []
        if loadPersistentState && restoreLegacyState && sessions == nil && !SessionStorageLayout(root: SessionStorageLayout.defaultRoot).isInstalled {
            do { legacy = try TaskStore().load(); records = legacy }
            catch { storageWarning = String(localized: "Previous task records could not be read. The original file has been kept.") }
        }
        let sessionStore = sessions ?? ConversationStore(legacy: legacy)
        self.sessions = sessionStore
        self.lifecycle = lifecycle ?? RunLifecycleCoordinator(scheduler: executionScheduler,
            storage: loadPersistentState ? SessionRunCheckpointStore(sessions: sessionStore, conversationID: checkpointConversationID)
                : MemoryRunCheckpointStore())
        self.lifecycle.onPause = { [weak self] message in
            guard let self else { return }
            if let context = self.screenExecutionContext, let failure = context.failureMessage {
                self.usbDiagnostics.record("run.healthFailed source=lifecycle \(context.diagnosticSummary)")
                self.cancelRun(message: failure, phase: .interrupted)
            } else { self.cancelRun(message: message, phase: .interrupted) }
        }
        providerSubscription = self.providers.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        lifecycleSubscription = self.lifecycle.$backgroundStatus.sink { [weak self] in self?.backgroundStatus = $0 }
        for saved in self.lifecycle.recoveries { self.sessions.reconcileRecovery(saved) }
        if sharedCapture == nil {
            capture.onDiagnostic = { [weak self] event in self?.usbDiagnostics.record(event) }
            capture.onLoss = { [weak self] in
                guard let self else { return }
                for worker in self.sessionRuntimes.values where worker.screenExecutionContext != nil || worker.bridge is LocalScreenBridge { worker.stop(message: String(localized: "Screen capture has stopped. Input is disabled.")) }
                guard self.usbClient != nil || self.screenExecutionContext != nil || self.bridge is LocalScreenBridge else { return }
                self.usbDiagnostics.record("capture.loss revokeInput=true hasUSB=\(self.usbClient != nil)")
                self.stop(message: String(localized: "Screen capture has stopped. Input is disabled."))
            }
        }
    }
    @discardableResult func createConversation(mode: RunMode) -> UUID {
        let id = sessions.create(mode: mode); selectConversation(id); return id
    }
    @discardableResult func createConversationDraft(mode: RunMode) -> UUID {
        let id = sessions.createDraft(mode: mode); selectConversation(id); return id
    }
    func discardConversationDraft(_ id: UUID) {
        if let runtimeOwner { runtimeOwner.discardConversationDraft(id); return }
        guard sessions.isDraft(id), !isRunning(in: id), existingExecutionModel(for: id)?.stopping != true else { return }
        sessions.discardDraft(id)
        if selectedConversationID == id { selectedConversationID = nil }
        if primarySessionID == id { primarySessionID = nil }
        sessionSubscriptions.removeValue(forKey: id)
        sessionRuntimes.removeValue(forKey: id)
    }
    func selectConversation(_ id: UUID) {
        if let runtimeOwner { runtimeOwner.selectConversation(id); return }
        guard sessions.conversation(id) != nil else { return }
        selectedConversationID = id
        let worker = executionModel(for: id)
        if sessions.conversation(id)?.providerID == nil, let selection = providers.defaultSelection {
            sessions.selectProvider(selection.profile.id, model: selection.model, in: id)
        }
        if !worker.running && !worker.stopping {
            worker.mode = sessions.conversation(id)?.mode ?? .demo
            worker.errorMessage = nil
        }
    }
    func leaveConversation(_ id: UUID) {
        if let runtimeOwner { runtimeOwner.leaveConversation(id); return }
        guard selectedConversationID == id else { return }
        selectedConversationID = nil; sessions.saveNow()
    }
    func isRunning(in id: UUID) -> Bool { existingExecutionModel(for: id)?.running == true }
    func approval(in id: UUID) -> Approval? {
        guard let worker = existingExecutionModel(for: id), worker.runIdentity?.conversationID == id else { return nil }
        return worker.approval
    }
    func approve(_ approved: Bool, approvalID: UUID, conversationID: UUID) {
        guard let worker = existingExecutionModel(for: conversationID), worker.runIdentity?.conversationID == conversationID,
              worker.approval?.id == approvalID else { return }
        worker.approve(approved)
    }
    func stop(run: RunIdentity) -> Bool {
        guard let worker = existingExecutionModel(for: run.conversationID), worker.runIdentity == run, worker.running, !worker.stopping else { return false }
        worker.stop(); return true
    }
    func selectedProvider(in conversationID: UUID) -> ProviderProfile? {
        providers.profile(sessions.conversation(conversationID)?.providerID)
    }
    func selectedModel(in conversationID: UUID) -> String {
        sessions.conversation(conversationID)?.modelID ?? selectedProvider(in: conversationID)?.settings.model ?? ""
    }
    func selectProvider(_ id: UUID, in conversationID: UUID) {
        guard sessions.conversation(conversationID) != nil, sessions.activeRuns[conversationID] == nil,
              !isRunning(in: conversationID), existingExecutionModel(for: conversationID)?.stopping != true, let profile = providers.profile(id) else { return }
        sessions.selectProvider(id, model: profile.settings.model, in: conversationID)
        do { try providers.rememberSelection(providerID: id, model: profile.settings.model) }
        catch { errorMessage = Self.safeError(error) }
    }
    func selectModel(_ model: String, in conversationID: UUID) {
        guard sessions.conversation(conversationID) != nil, sessions.activeRuns[conversationID] == nil,
              !isRunning(in: conversationID), existingExecutionModel(for: conversationID)?.stopping != true, let profile = selectedProvider(in: conversationID) else { return }
        sessions.selectProvider(profile.id, model: model, in: conversationID)
        do { try providers.rememberSelection(providerID: profile.id, model: model) }
        catch { errorMessage = Self.safeError(error) }
    }
    func selectReasoningEffort(_ effort: String?, in conversationID: UUID) {
        guard sessions.conversation(conversationID) != nil, sessions.activeRuns[conversationID] == nil,
              !appOwner.hasBusySessions, var profile = selectedProvider(in: conversationID) else { return }
        let model = selectedModel(in: conversationID)
        var parameters = profile.parameters(for: model)
        parameters.reasoningEffort = effort
        do {
            _ = try parameters.requestFields(providerKind: profile.providerKind, model: profile.metadata(for: model))
            var allParameters = profile.modelParameters ?? [:]
            allParameters[model] = parameters
            profile.modelParameters = allParameters
            try providers.save(profile)
            errorMessage = nil
        } catch { errorMessage = Self.safeError(error) }
    }
    @discardableResult func saveProvider(_ draft: ProviderProfile, key: String) -> Bool {
        guard !appOwner.hasBusySessions else { return false }
        do {
            if draft.providerKind == .chatGPTSubscription, !key.isEmpty {
                throw AppError.invalid(String(localized: "ChatGPT subscriptions do not accept API keys"))
            }
            let value = try providers.prepared(draft)
            if !key.isEmpty {
                try writeProviderKey(key, value.keyAccount)
            }
            try providers.save(value)
            errorMessage = nil
            return true
        } catch { errorMessage = Self.safeError(error); return false }
    }
    func removeProvider(_ id: UUID) {
        guard !appOwner.hasBusySessions else { return }
        do { try providers.remove(id) } catch { errorMessage = Self.safeError(error) }
    }
    func restoreProvider(_ id: UUID) {
        guard !appOwner.hasBusySessions else { return }
        do { try providers.restore(id) } catch { errorMessage = Self.safeError(error) }
    }
    func hasSavedProviderKey(for draft: ProviderProfile) -> Bool {
        guard let saved = providers.profile(draft.id),
              let endpoint = try? draft.catalogEndpoint(),
              endpoint == (try? saved.catalogEndpoint()) else { return false }
        return (try? containsProviderKey(saved.keyAccount)) == true
    }
    func discoveryKey(for draft: ProviderProfile, typedKey: String) throws -> String {
        guard !appOwner.hasBusySessions else { throw AppError.stopped }
        if draft.providerKind == .chatGPTSubscription { throw AppError.unavailable(ChatGPTSubscriptionPolicy.mobileLoginNotice) }
        if !typedKey.isEmpty { return typedKey }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "" }
        #endif
        let value = try providers.prepared(draft)
        return try SecretStore.load(value.keyAccount) ?? ""
    }
    func setForeground(_ active: Bool) {
        setScene(active ? .active : .background)
    }
    private var currentScene = ScreenUSBExecutionContext.Scene.active
    private var canContinueUSBSetup: Bool { usbConnectionStatus.allowsSetup(in: currentScene) }
    func setScene(_ scene: ScreenUSBExecutionContext.Scene) {
        if scene == .active { hasActivatedScene = true }
        // Inactive still precedes a usable foreground scene during an app handoff.
        // Publish accumulated messages only when the scene can render them.
        if runtimeOwner == nil { sessions.setPresentationActive(scene == .active) }
        #if DEBUG
        // Explicit negative control for the finite, synthetic CPU probe only.
        let args = ProcessInfo.processInfo.arguments
        if runtimeOwner == nil, args.contains("--task-pip-probe"), args.contains("--background-stream-probe"), args.contains("--background-presentation-baseline") {
            sessions.setPresentationActive(true)
        }
        #endif
        remoteRuntime?.setScene(scene)
        for worker in sessionRuntimes.values { worker.setScene(scene) }

        if usbClient != nil || usbConnectionStatus.isConnecting {
            usbDiagnostics.record("scene \(currentScene) -> \(scene) connecting=\(usbConnectionStatus.isConnecting) running=\(running)", attempt: usbGeneration)
        }
        currentScene = scene
        if scene != .active { cancelPreview() }
        let active = scene == .active
        foreground = active
        liveActivities.setForeground(active)
        screenExecutionContext?.setScene(scene)
        lifecycle.setForeground(scene != .background)
        if active { sessions.saveNow() }
        // System CPU/network time does not authorize foreground-only control routes.
        if !active, screenExecutionContext == nil, !(bridge is CoreDeviceBridge) { bridge?.cancelTransport() }
        // An established USB connection belongs to the App, not the current
        // task or view. Background/lock can revoke input without closing TCP.
        if !active, usbClient != nil, usbConnectionStatus.isReady {
            usbDiagnostics.record("idleUSB.preserved reason=scene_\(scene) inputPermission=\(running)", attempt: usbGeneration)
        }
        let preserveUSBSetup = !active && canContinueUSBSetup && bridge == nil
        if !active, !stopping, !running, !preserveUSBSetup, listenerTask != nil {
            stop(message: String(localized: "Foreground connection setup was cancelled. Established USB connections are kept."), interrupted: true)
        }
        if !active, running, approval != nil, !lifecycle.canAwaitApprovalInBackground {
            stop(message: String(localized: "This tool requires approval in the foreground. Capture a new screenshot."), interrupted: true)
        }
    }
    func setProtectedDataAvailable(_ available: Bool) {
        remoteRuntime?.setProtectedDataAvailable(available)
        for worker in sessionRuntimes.values { worker.setProtectedDataAvailable(available) }
        if available != protectedDataAvailable, usbClient != nil {
            usbDiagnostics.record("protectedDataAvailable=\(available)", attempt: usbGeneration)
        }
        protectedDataAvailable = available
        if !available {
            endRemoteContinuity()
            cancelPreview()
            screenExecutionContext?.revoke()
            if running || usbClient != nil { stop(message: String(localized: "The device is locked or protected data is unavailable. Input has stopped."), interrupted: true) }
        }
    }
    func disconnect() {
        usbDiagnostics.record("ui.disconnect requested", attempt: usbGeneration)
        cancelRun(message: String(localized: "The bridge disconnected. Check the device if an action was already sent."), phase: .stopped, disconnectUSB: true)
    }
    func usbDiagnosticReport() -> String {
        usbDiagnostics.record("export requested scene=\(currentScene) foreground=\(foreground) protectedData=\(protectedDataAvailable) running=\(running) stopping=\(stopping) connecting=\(usbConnectionStatus.isConnecting)")
        usbDiagnostics.record(capture.frames.diagnostics().summary)
        usbDiagnostics.recordInterfaces(reason: "export")
        return usbDiagnostics.report() + "\n\n" + appOwner.museDiagnostics.report()
    }
    func connectUSB() {
        guard appOwner.remoteLeaseID == nil else { return }
        let operation = UUID()
        usbDiagnostics.record("ui.connect requested scene=\(currentScene) foreground=\(foreground) running=\(running) stopping=\(stopping) listenerBusy=\(listenerTask != nil)", attempt: operation)
        guard foreground else { usbDiagnostics.record("ui.connect rejected=notForeground", attempt: operation); usbConnectionStatus = .failed(String(localized: "Keep the app in the foreground and try again")); return }
        guard !running, !stopping else { usbDiagnostics.record("ui.connect rejected=runningOrStopping", attempt: operation); usbConnectionStatus = .failed(String(localized: "Wait for the current task to stop before connecting")); return }
        guard listenerTask == nil else { usbDiagnostics.record("ui.connect rejected=listenerBusy", attempt: operation); usbConnectionStatus = .failed(String(localized: "A bridge connection is already being set up. Try again shortly.")); return }
        if usbClient != nil, usbConnectionStatus.isReady {
            usbDiagnostics.record("ui.connect reusedExisting=true", attempt: usbGeneration)
            return
        }
        listenerGeneration = operation; usbGeneration = operation
        errorMessage = nil; usbConnectionStatus = .connecting
        listenerTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.listenerGeneration == operation { self.listenerTask = nil } }
            do {
                await self.usbClient?.disconnect()
                guard self.listenerGeneration == operation, self.canContinueUSBSetup, !Task.isCancelled else { return }
                let client = self.makeUSBClient(self.usbDiagnostics) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.usbGeneration == operation else { return }
                        if progress.isConnecting && !self.usbConnectionStatus.isConnecting { return }
                        self.usbConnectionStatus = progress
                        if progress.isFailure || progress.isDisconnected {
                            self.usbClient = nil
                            if self.screenExecutionContext != nil, !self.stopping, !self.finishingRun {
                                self.stop(message: String(localized: "USB communication was interrupted. Input has stopped. Reconnect manually."), interrupted: true)
                            }
                        }
                    }
                }
                self.usbClient = client
                try await client.connect(attempt: operation)
                guard self.listenerGeneration == operation, self.canContinueUSBSetup, !Task.isCancelled else { await client.disconnect(); return }
                self.usbConnectionStatus = .checking
                try await client.command("PING")
                let supportsHID = await client.supportsHID
                guard self.listenerGeneration == operation, self.canContinueUSBSetup, !Task.isCancelled else { await client.disconnect(); return }
                try client.health.requireHealthy(clock: { ProcessInfo.processInfo.systemUptime })
                self.usbConnectionStatus = .ready(hid: supportsHID)
                self.usbDiagnostics.record("connect.verified explicitPING=true hid=\(supportsHID)", attempt: operation)
            } catch {
                if self.listenerGeneration == operation {
                    let message = Self.safeError(error)
                    self.usbDiagnostics.record("connect.failed reason=\(message)", attempt: operation)
                    self.usbConnectionStatus = .failed(message); self.errorMessage = message; self.usbClient = nil
                }
            }
        }
    }
    func stopCapture() { stop(); Task { await capture.stop() } }
    private func cancelPreview() {
        previewTask?.cancel(); previewTask = nil; previewingCapture = false
    }
    func previewCapture() {
        guard appOwner.remoteLeaseID == nil else { return }
        guard foreground, protectedDataAvailable, !running, !stopping, !previewingCapture else { return }
        // Local-only preview shares the first-frame wait, but never calls a provider.
        let frames = capture.frames
        do {
            let epoch = try frames.captureSessionID()
            previewingCapture = true; errorMessage = nil
            previewTask = Task { [weak self] in
                do {
                    let frame = try await frames.waitForFrame(epoch: epoch)
                    guard let self, !Task.isCancelled, self.foreground, self.protectedDataAvailable, !self.running else { return }
                    self.latestFrame = PresentedFrame(step: StepIdentity(run: RunIdentity(conversationID: self.selectedConversationID ?? UUID(), runID: UUID()), stepID: "local-preview"), image: frame)
                } catch {
                    if !Task.isCancelled { self?.errorMessage = Self.safeError(error) }
                }
                if !Task.isCancelled { self?.previewingCapture = false; self?.previewTask = nil }
            }
        } catch { errorMessage = Self.safeError(error) }
    }
    // Kept for Settings → Control Debug. Each explicit debug run has its own history.
    func start(resuming: Bool = false) {
        guard !running, !stopping else { return }
        if resuming, let record = activeRecord { goal = record.goal; mode = record.mode }
        let id: UUID
        if let primarySessionID, sessions.conversation(primarySessionID) != nil {
            id = primarySessionID; selectConversation(id)
        } else { id = createConversation(mode: mode) }
        _ = send(goal, in: id, cloudConsent: true)
    }
    struct PreparedAttachments {
        var references: [StoredAttachment] = []
        var images: [ModelImage] = []
        var text = ""
    }
    func importDraftAttachment(data: Data, name: String, in id: UUID) async throws {
        let worker = executionModel(for: id)
        if worker !== self { try await worker.importDraftAttachment(data: data, name: name, in: id); return }
        try canImportAttachment(in: id); appOwner.assetMutations += 1
        defer { appOwner.assetMutations -= 1 }
        let asset = try await attachments.store(data, name: name, conversationID: id)
        try Task.checkCancellation(); try canImportAttachment(in: id)
        sessions.addDraftAttachment(asset, in: id)
    }
    func importDraftAttachment(file: URL, in id: UUID) async throws {
        let worker = executionModel(for: id)
        if worker !== self { try await worker.importDraftAttachment(file: file, in: id); return }
        try canImportAttachment(in: id); appOwner.assetMutations += 1
        defer { appOwner.assetMutations -= 1 }
        let asset = try await attachments.importFile(file, conversationID: id)
        try Task.checkCancellation(); try canImportAttachment(in: id)
        sessions.addDraftAttachment(asset, in: id)
    }
    private func canImportAttachment(in id: UUID) throws {
        guard appOwner.selectedConversationID == id, sessions.conversation(id) != nil else {
            throw AppError.unavailable(String(localized: "The selected conversation changed. Open the conversation you want and send again."))
        }
        guard !running else { throw AppError.unavailable(String(localized: "A task is already running in this conversation")) }
        guard !stopping else { throw AppError.unavailable(String(localized: "The previous task is still stopping. Try again shortly.")) }
        guard !appOwner.clearingAssets else { throw AppError.unavailable(String(localized: "Files are being cleaned up. Try again shortly.")) }
    }
    @discardableResult func sendDraft(_ text: String, in id: UUID, cloudConsent: Bool) async throws -> Bool {
        let worker = executionModel(for: id)
        if worker !== self { return try await worker.sendDraft(text, in: id, cloudConsent: cloudConsent) }
        guard let before = sessions.conversation(id) else {
            throw AppError.unavailable(String(localized: "This conversation is unavailable. Open it again or start a new conversation."))
        }
        let providerBefore = selectedProvider(in: id)
        try canImportAttachment(in: id); appOwner.assetMutations += 1
        defer { appOwner.assetMutations -= 1 }
        var prepared = PreparedAttachments(references: before.draftAttachments ?? [])
        // A failed workspace still degrades to chat/image input as it does during tool setup.
        let workspace = prepared.references.isEmpty ? nil : (try? sessions.workspaceDirectory(id))
        var files: [[String: Any]] = []
        if !prepared.references.isEmpty { prepared.text += "\n\n" + Self.attachmentInstructions }
        for asset in prepared.references {
            try Task.checkCancellation()
            if asset.kind == .image { prepared.images.append(ModelImage(data: try await attachments.inferenceImage(asset, conversationID: id), mimeType: "image/jpeg")) }
            else {
                let bytes = try await attachments.read(asset, conversationID: id)
                guard let content = String(data: bytes, encoding: .utf8) else { throw AppError.invalid(String(localized: "The attachment is not UTF-8 text")) }
                prepared.text += "\n\nAttached text file: \(asset.name)\n<attachment_content>\n\(content)\n</attachment_content>"
            }
            if let workspace {
                var file: [String: Any] = [
                    "name": asset.name,
                    "file_path": try await attachments.relativePath(asset, conversationID: id, from: workspace),
                    "mime_type": asset.mimeType, "byte_count": asset.byteCount
                ]
                if let width = asset.width, let height = asset.height {
                    file["width"] = width; file["height"] = height
                }
                files.append(file)
            }
        }
        if !files.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: ["relative_to": "conversation_working_directory", "files": files], options: [.sortedKeys])
            prepared.text += "\n\n<attachment_files>\n\(String(decoding: data, as: UTF8.self))\n</attachment_files>"
        }
        try Task.checkCancellation()
        guard let current = sessions.conversation(id), current.providerID == before.providerID,
              current.modelID == before.modelID, selectedProvider(in: id) == providerBefore,
              current.draftAttachments == before.draftAttachments else { throw AppError.invalid(String(localized: "The attachment or model selection changed. Send it again.")) }
        return send(text, in: id, cloudConsent: cloudConsent, prepared: prepared)
    }
    @discardableResult func send(_ text: String, in conversationID: UUID, cloudConsent: Bool = false, prepared: PreparedAttachments = PreparedAttachments(), allowBackgroundStart: Bool = false) -> Bool {
        let worker = executionModel(for: conversationID)
        if worker !== self { return worker.send(text, in: conversationID, cloudConsent: cloudConsent, prepared: prepared, allowBackgroundStart: allowBackgroundStart) }
        func reject(_ reason: String, _ message: String) -> Bool {
            errorMessage = message
            usbDiagnostics.record("run.startRejected reason=\(reason) foreground=\(foreground) protectedData=\(protectedDataAvailable)")
            return false
        }
        guard !running else { return reject("running", String(localized: "A task is already running in this conversation")) }
        guard !stopping else { return reject("stopping", String(localized: "The previous task is still stopping. Try again shortly.")) }
        guard prepared.references.isEmpty || !appOwner.clearingAssets else { return reject("clearingAssets", String(localized: "Files are being cleaned up. Try again shortly.")) }
        guard foreground || (allowBackgroundStart && commandCanStart) else { return reject("notForeground", String(localized: "The app has not entered the foreground. The task has not started.")) }
        guard protectedDataAvailable else { return reject("protectedData", String(localized: "Unlock the device to run a task")) }
        guard primarySessionID == conversationID, let session = sessions.conversation(conversationID) else {
            return reject("missingSession", String(localized: "This execution session is unavailable. Start a new task."))
        }
        guard prepared.references == (session.draftAttachments ?? []) else {
            return reject("attachmentsChanged", String(localized: "The task attachments changed. Send them again."))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmed.isEmpty && !prepared.references.isEmpty ? String(localized: "Please review the attachment") : trimmed
        guard !query.isEmpty else { return reject("invalidTask", String(localized: "Enter a task")) }
        guard session.mode == .demo || cloudConsent else { return reject("cloudConsent", String(localized: "Confirm sending this task to the selected model provider")) }
        let profile = session.mode == .live ? self.selectedProvider(in: conversationID) : nil
        let metadata = profile?.metadata(for: selectedModel(in: conversationID))
        let supportsImages = metadata?.vision != .unsupported
        let supportsTools = metadata?.tools != .unsupported
        var deviceAvailable = appOwner.remoteLeaseID == nil
        guard supportsImages || prepared.images.isEmpty else {
            return reject("imagesUnsupported", String(localized: "This model cannot read images. Remove the image attachments or choose a model that supports images, then send again."))
        }
        var runNotices: [String] = []
        if !supportsTools { runNotices.append(String(localized: "This model does not support tools. You can chat, but this task cannot use phone controls, files, commands, or skills. Choose a model with tool support to use them.")) }
        if !supportsImages && supportsTools { runNotices.append(String(localized: "This model cannot read images. Text chat and text tools remain available; screenshot controls are unavailable unless Accessibility Only is selected.")) }
        if !deviceAvailable && supportsTools { runNotices.append(String(localized: "Muse is using phone controls. You can chat and use files; phone controls are unavailable for this task. Stop the Muse task and send again to use them.")) }
        cancelPreview()
        let selectedMode = session.mode, token = UUID()
        var runSettings = ProviderSettings()
        let selectedBridge: any DeviceBridge
        let selectedProvider: any ModelProvider
        do {
            if let services = runServicesFactory?(conversationID) ?? runServices {
                selectedBridge = supportsTools && deviceAvailable ? services.bridge : UnavailableBridge()
                selectedProvider = services.provider
            }
            else if selectedMode == .demo { selectedBridge = DemoBridge(); selectedProvider = DemoProvider() }
            else {
                guard let profile = self.selectedProvider(in: conversationID) else { throw AppError.invalid(String(localized: "Select a provider for this conversation. The previous provider may have been removed.")) }
                if session.providerID == nil {
                    sessions.selectProvider(profile.id, model: profile.settings.model, in: conversationID)
                }
                runSettings = profile.settings
                runSettings.model = selectedModel(in: conversationID)
                try profile.requireInference(model: runSettings.model)
                let cloud: any CancellableModelProvider
                if profile.providerKind == .chatGPTSubscription {
                    guard let account = profile.chatGPTAccountReference else { throw ChatGPTAuthError.disconnected }
                    cloud = try ChatGPTSubscriptionProvider(profile: profile, model: runSettings.model, account: account, sessionID: conversationID)
                } else {
                let key = try SecretStore.load(profile.keyAccount) ?? ""
                cloud = try PrivateVisionProvider(settings: runSettings, apiKey: key, limits: limits,
                    providerKind: profile.providerKind, parameters: profile.parameters(for: runSettings.model), metadata: profile.metadata(for: runSettings.model),
                    inferenceAPI: profile.inferenceAPI, contextPolicy: profile.contextPolicy, accountReference: profile.keyAccount, sessionID: conversationID)
                }
                let usbInput = appOwner.usbClient.map { client in
                    LiveDeviceBridgeRouter.USBInput(transport: client, health: client.health,
                                                   supportsHID: appOwner.usbConnectionStatus == .ready(hid: true))
                }
                if !supportsTools || !deviceAvailable {
                    selectedBridge = UnavailableBridge()
                } else {
                    do {
                        switch DeviceControlRoute.current {
                        case .ncmDeveloper, .vpnLoopback:
                            selectedBridge = try CoreDeviceBridge()
                        case .localCaptureUSB:
                            selectedBridge = try LiveDeviceBridgeRouter.make(frames: capture.frames, captureActive: capture.active,
                            usb: usbInput, backgroundEnabled: true,
                            usbStatus: appOwner.usbConnectionStatus, diagnostics: usbDiagnostics) { [weak self] reason in
                                Task { @MainActor in
                                    guard self?.generation == token, self?.finishingRun == false else { return }
                                    let message = reason == .sessionInvalid ? (self?.screenExecutionContext?.failureMessage ?? reason.message) : reason.message
                                    self?.stop(message: message)
                                }
                            }
                        }
                    } catch {
                        selectedBridge = UnavailableBridge()
                        deviceAvailable = false
                        runNotices.append(String(localized: "Phone controls could not be prepared. Chat and file tools remain available. Check the connection in Settings and start a new task to retry phone controls."))
                    }
                }
                selectedProvider = cloud; provider = cloud
            }
        } catch {
            errorMessage = Self.safeError(error); sessions.addNotice(Self.safeError(error), in: conversationID); return false
        }
        guard let identity = sessions.begin(in: conversationID, query: query, attachments: prepared.references) else {
            provider?.cancel(); provider = nil
            if !sessions.storageReady {
                return reject("storageUnavailable", String(localized: "Conversation history is unavailable. Check available storage and reopen the app. If this history is damaged, continue in a new conversation."))
            }
            return reject("sessionAlreadyActive", String(localized: "This conversation already has a run record. The task was not started again."))
        }
        screenExecutionContext = selectedBridge.executionContext
        executionScheduler.configure(context: screenExecutionContext, allowSystemProcessing: allowSystemProcessing,
                                     selection: executionBackground.selection, runID: identity.runID,
                                     userInitiated: foreground && !allowBackgroundStart)
        do { try lifecycle.begin(identity: identity, generation: token, allowBackgroundStart: allowBackgroundStart) }
        catch {
            stopHealthObservation()
            screenExecutionContext?.revoke(); screenExecutionContext = nil; executionScheduler.configure(context: nil, allowSystemProcessing: false)
            provider?.cancel(); provider = nil
            let message = String(localized: "Could not save task progress. Check available storage, reopen the app, and try again. No model request or phone action was sent.")
            sessions.finish(identity, phase: .blocked, summary: message)
            Task { await selectedBridge.stop() }
            errorMessage = message; return false
        }
        runIdentity = identity; generation = token; mode = selectedMode; finishingRun = false
        usbDiagnostics.record("run.authorization policy=host fixedDurationLimit=false")
        completedToolIDs = []; activeActionCallID = nil; statusClearTask?.cancel(); statusClearTask = nil
        modelReplyPending = false; statusShownAt = .distantPast
        activityNavigation = nil; activityHandoffRun = nil
        var record = TaskRecord(goal: query, mode: selectedMode); record.phase = .running
        activeID = record.id; records.insert(record, at: 0); records = Array(records.prefix(20))
        running = true; latestFrame = nil; errorMessage = nil
        bridge = selectedBridge; status = selectedMode == .demo ? String(localized: "Offline scripted demo") : String(localized: "Contacting the model")
        log(String(localized: "A new conversation turn has started. Previous tools will not be replayed."))
        // Record the run origin before queued model or scene events can change it.
        publishActivity(allowBackgroundStart ? .thinking : .working)
        let screenInformationMode: ScreenInformationMode = selectedMode == .live ? ScreenInformationMode.load() : .screenshot
        let action = ActionCoordinator(bridge: selectedBridge, limits: limits,
            approve: { [weak self] request in await self?.authorizeTool(request, generation: token) ?? false },
            onImage: { [weak self] frame, callID in await self?.show(frame, callID: callID, generation: token) },
            onReceipt: { [weak self] text in await self?.record(text, generation: token) },
            onExecuting: { [weak self] callID, name in await self?.markExecuting(callID: callID, name: name, generation: token) },
            lifecycle: lifecycle, generation: token, authorizationMode: toolAuthorizationPolicy.inputGrantMode, diagnostics: usbDiagnostics,
            screenInformationMode: screenInformationMode)
        coordinator = action
        var names = selectedMode == .demo ? ["screenshot", "tap", "drag", "wait", "finish"] : ["screenshot", "tap", "drag", "home", "list_apps", "launch_app", "type_text", "wait"]
        if !deviceAvailable { names = [] }
        if !supportsImages && screenInformationMode != .accessibility {
            names.removeAll { ["screenshot", "tap", "drag"].contains($0) }
        }
        if !supportsTools { names = [] }
        let skillSnapshot = supportsTools ? skills.enabledSnapshot : []
        runSkillNames = Dictionary(uniqueKeysWithValues: skillSnapshot.map { ($0.id.uuidString, $0.name) })
        var tools: [any AgentTool] = names.map { DeviceTool(name: $0, coordinator: action, onResult: { [weak self] call, result in
            await self?.recordToolResult(call, result: result, generation: token)
        }) }
        if supportsTools {
            tools += ["load_skill"].map { name in
                SkillTool(name: name, catalog: SkillCatalog(store: skills), canRead: { [weak self] in
                    guard let self else { return false }
                    return await self.canReadSkill(identity: identity, generation: token)
                }, onResult: { [weak self] call, result in
                    await self?.recordToolResult(call, result: result, generation: token)
                })
            }
        }
        if supportsTools {
            do {
                let workspace = try FileWorkspace(root: sessions.workspaceDirectory(conversationID))
                tools += ExecutionTool.Kind.allCases.map { kind in
                    ExecutionTool(kind: kind, workspace: workspace, canExecute: { [weak self] in
                        guard let self else { return false }
                        return await self.canReadSkill(identity: identity, generation: token)
                    }, authorizeMutation: { [weak self] call, detail in
                        await self?.authorizeExecutionMutation(call, detail: detail, generation: token) ?? false
                    }, onResult: { [weak self] call, result in
                        await self?.finishExecutionTool(call, result: result, generation: token)
                    })
                }
            } catch {
                runNotices.append(String(localized: "Conversation files could not be opened. You can still chat and use other available tools. Check available storage and start a new task to retry file tools."))
            }
        }
        for notice in runNotices { sessions.addNotice(notice, in: conversationID) }
        errorMessage = runNotices.isEmpty ? nil : runNotices.joined(separator: "\n")
        let scope = (selectedProvider as? PrivateVisionProvider)?.replayScope
            ?? (selectedProvider as? ChatGPTSubscriptionProvider)?.replayScope
        let storage: StoragePolicy = profile?.contextPolicy == .responseChain ? .responseChain : .none
        // Older OpenRouter/Ollama catalogs used inputTokenLimit for a total window.
        let reportsTotalWindow = profile?.providerKind == .openRouter || profile?.providerKind == .ollama
        let inputLimit = reportsTotalWindow ? nil : metadata?.inputTokenLimit
        let contextLimit = metadata?.contextTokenLimit ?? (reportsTotalWindow ? metadata?.inputTokenLimit : nil)
        let planning = Self.contextPlanningBudget(default: inputLimit ?? contextLimit ?? ContextBudget.defaultPlanningTokens)
        let config = AgentConfiguration(model: selectedProvider.configuration.defaultModel ?? runSettings.model,
            instructions: Self.systemPrompt(skills: skillSnapshot, language: Locale.preferredLanguages.first ?? "en"), scope: scope, storage: storage,
            budget: ContextBudget(planningTokens: planning, hardInputTokens: inputLimit, hardContextTokens: contextLimit,
                outputReserve: limits.maxOutputTokens ?? ContextBudget.defaultOutputReserve), maxOutputTokens: limits.maxOutputTokens,
            cacheKey: conversationID.uuidString, maximumInferences: limits.maxTurns)
        let runner: AgentRuntime
        do {
            runner = AgentRuntime(store: try sessions.engineStore(for: conversationID), provider: selectedProvider,
                                  configuration: config, tools: tools)
        } catch {
            let message = (error is StoreError || error is SessionCommandError)
                ? String(localized: "Conversation history is unavailable. Check available storage and reopen the app. If this history is damaged, continue in a new conversation.")
                : Self.safeError(error)
            cancelRun(message: message, phase: .blocked)
            errorMessage = message
            return false
        }
        agent = runner
        let userItemID = sessions.conversation(conversationID)?.messages.last(where: { $0.runID == identity.runID && $0.role == .user })?.id ?? UUID()
        healthObserver = screenExecutionContext?.observeHealth { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, !self.finishingRun else { return }
                self.usbDiagnostics.record("run.healthFailed source=context \(self.screenExecutionContext?.diagnosticSummary ?? "context=none")")
                self.stop(message: self.screenExecutionContext?.failureMessage ?? String(localized: "Execution permission was revoked. Input has stopped."), interrupted: true)
            }
        }
        runTask = Task { [weak self, runner] in
            do {
                if allowBackgroundStart {
                    try await self?.lifecycle.awaitExecution(generation: token, backgroundCapable: true)
                }
                if let usb = selectedBridge as? USBDeviceBridge { try await usb.arm() }
                let handle = try await runner.startTurn(in: conversationID,
                    input: TurnInput(itemID: userItemID, text: query + prepared.text, images: prepared.images), turnID: identity.runID)
                for await event in handle.events {
                    if Task.isCancelled { await runner.cancelTurn(identity.runID); break }
                    self?.observe(event, generation: token)
                }
                let result = await handle.result()
                if result.status != .completed {
                    throw Self.turnError(result.failure)
                }
                let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = await action.finishSummary
                guard let self, self.generation == token else { await action.stop(); return }
                let messages = self.sessions.conversation(conversationID)?.messages.filter { $0.runID == identity.runID } ?? []
                let failure = messages.last(where: { $0.tool?.state == .failed })?.tool?.result
                // A normal final answer ends a device run too; finish is optional.
                // Only the tagged final turn counts, never a pre-tool narration.
                // Completed describes the conversation, not proof of HID/UI success.
                let reason = summary != nil ? "finishTool" : (!finalText.isEmpty ? "finalText" : (failure != nil ? "toolFailure" : "noFinalText"))
                self.usbDiagnostics.record("run.ended reason=\(reason) finishRequired=false")
                if let summary { await self.closeRun(.completed, result: summary, bridge: selectedBridge, generation: token) }
                else if !finalText.isEmpty { await self.closeRun(.completed, result: finalText, bridge: selectedBridge, generation: token) }
                else if let failure { await self.closeRun(.blocked, result: failure, publishNotice: false, bridge: selectedBridge, generation: token) }
                else {
                    let result = String(localized: "This turn ended without a result summary from the model.")
                    self.sessions.addNotice(result, in: conversationID)
                    await self.closeRun(.completed, result: result, bridge: selectedBridge, generation: token)
                }
            } catch {
                guard let self, self.generation == token else { await action.stop(); return }
                await self.closeRun(.blocked, result: Self.runFailure(error, provider: selectedProvider), bridge: selectedBridge, generation: token)
            }
        }
        return true
    }
    private func stopHealthObservation() {
        if let healthObserver { screenExecutionContext?.removeHealthObserver(healthObserver) }
        healthObserver = nil
    }
    private func closeRun(_ phase: RunPhase, result: String, publishNotice: Bool = true,
                          bridge: any DeviceBridge, generation token: UUID) async {
        // Completion is already determined. Stop monitors before revoking the
        // capability, so a slow STOP ACK cannot masquerade as an unexpected loss.
        finishingRun = true; stopHealthObservation()
        usbDiagnostics.record("run.close phase=\(phase) hasUSB=\(usbClient != nil) connectionRetained=\(usbConnectionStatus.isReady)")
        // ActivityKit updates cross an async boundary. Submit the terminal
        // state while both the execution lease and task media are still owned.
        publishActivity(phase == .completed ? .completed : .blocked)
        await liveActivities.waitForPendingUpdates()
        guard generation == token else { return }
        if phase == .completed, let identity = runIdentity {
            // Publish the destination before activation so scene restoration
            // opens this task, including when another conversation is visible.
            let navigation = ActivityNavigation(route: AgentActivityRoute(sessionID: identity.conversationID, runID: identity.runID), messageID: nil)
            activityNavigation = navigation
            if appOwner !== self { appOwner.activityNavigation = navigation }
            if !foreground, protectedDataAvailable, let bundleID = Bundle.main.bundleIdentifier {
                do {
                    let activated = try await bridge.bringApplicationToForeground(bundleID: bundleID)
                    BackgroundExecutionTrace.record("run.returnToConversation activated=\(activated) run=\(identity.runID)")
                } catch {
                    // Returning to the UI is best effort; a completed task stays
                    // completed and no device action is retried.
                    BackgroundExecutionTrace.record("run.returnToConversation failed run=\(identity.runID)")
                }
            }
            guard generation == token else { return }
        }
        lifecycle.finish(success: phase == .completed)
        screenExecutionContext?.revoke()
        await coordinator?.stop()
        guard generation == token else { return }
        end(phase, result: result, publishNotice: publishNotice)
    }
    func stop(message: String = String(localized: "Stopped. An action already sent may have run. Check the device."), interrupted: Bool = false) {
        if let remoteRuntime, !running {
            endRemoteContinuity()
            remoteRuntime.stop(message: message, interrupted: interrupted)
            return
        }
        if remoteRuntime == nil { endRemoteContinuity() }
        cancelRun(message: message, phase: interrupted ? .interrupted : .stopped)
    }
    private static func contextPlanningBudget(default value: Int) -> Int {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["ACTELL_CONTEXT_WINDOW"], let override = Int(raw), override >= 256 {
            return override
        }
        #endif
        return max(256, value)
    }
    private func cancelRun(message: String, phase: RunPhase, publishNotice: Bool = true, disconnectUSB: Bool = false) {
        // Inactive -> background can call stop twice. Only the first cleanup
        // owns draining; a second cleanup must not unlock Start prematurely.
        guard !stopping else {
            // Explicit disconnect can arrive while task release is draining.
            if disconnectUSB, let client = usbClient {
                usbGeneration = UUID(); usbClient = nil; usbConnectionStatus = .disconnected(message)
                Task { await client.disconnect() }
            }
            return
        }
        cancelPreview()
        let preserveUSBSetup = running && listenerTask != nil && !(bridge is USBDeviceBridge) && !disconnectUSB
        generation = UUID() // Fence late callbacks before cancelling anything.
        finishingRun = false
        stopHealthObservation()
        screenExecutionContext?.revoke(); screenExecutionContext = nil; executionScheduler.configure(context: nil, allowSystemProcessing: false)
        if usbClient != nil || usbConnectionStatus.isConnecting {
            // The caller's message may refer to a task; do not export it.
            usbDiagnostics.record("viewmodel.stop phase=\(phase) scene=\(currentScene) running=\(running) stopping=\(stopping)", attempt: usbGeneration)
        }
        lifecycle.stop(message: message) // Durable cancel fence before network cancellation.
        runTask?.cancel()
        if let agent, let turnID = runIdentity?.runID { Task { await agent.cancelTurn(turnID) } }
        provider?.cancel()
        bridge?.cancelTransport()
        publishActivity(phase == .interrupted ? .interrupted : (phase == .blocked ? .blocked : .stopped))
        if let identity = runIdentity { invalidateApprovals(identity) }
        approvalTimeout?.cancel(); approvalTimeout = nil
        if let identity = runIdentity { sessions.finish(identity, phase: phase, summary: publishNotice ? message : "") }
        runIdentity = nil
        let oldListenerTask = preserveUSBSetup ? nil : listenerTask
        if !preserveUSBSetup { listenerGeneration = UUID(); listenerTask?.cancel(); listenerTask = nil }
        approvalContinuation?.resume(returning: false); approvalContinuation = nil; approval = nil
        let old = coordinator, oldBridge = bridge, oldTask = runTask
        let closingUSB = disconnectUSB || (!preserveUSBSetup && usbConnectionStatus.isConnecting) ? usbClient : nil
        if closingUSB != nil || (!preserveUSBSetup && usbConnectionStatus.isConnecting) {
            usbGeneration = UUID(); usbClient = nil; usbConnectionStatus = .disconnected(message)
        }
        stopping = true
        Task {
            if let old { await old.stop() } else { await oldBridge?.stop() }
            await closingUSB?.disconnect()
            await oldListenerTask?.value
            await oldTask?.value
            stopping = false
        }
        if running { mutate { $0.phase = phase; $0.log(message) } }
        running = false; status = message; latestFrame = nil; agent = nil; provider = nil; coordinator = nil; bridge = nil

    }
    func approve(_ approved: Bool) {
        guard running, !stopping, foreground, protectedDataAvailable, let request = approval, let identity = runIdentity,
              let continuation = approvalContinuation else { return }
        do { try approvalRecords.resolve(request, run: identity, approved: approved) }
        catch {
            stop(message: String(localized: "Approval expired or its record is unavailable. This action was not authorized. Start again."), interrupted: true)
            return
        }
        approvalTimeout?.cancel(); approvalTimeout = nil
        if !approved {
            sessions.updateTool(callID: request.callID ?? request.id.uuidString, name: request.tool, state: .denied, result: String(localized: "You denied this action. It was not sent. The turn ended and will not retry automatically."), identity: identity)
            // Denial is a distinct terminal outcome. Shared cancellation only
            // drains resources and releases the pending approval exactly once.
            cancelRun(message: String(localized: "This action was denied. The turn ended without sending it."), phase: .blocked, publishNotice: false)
            return
        }
        sessions.updateTool(callID: request.callID ?? request.id.uuidString, name: request.tool, state: .approved, identity: identity)
        approvalContinuation = nil; approval = nil
        status = String(localized: "One action approved. Waiting for the device response.")
        mutate { $0.phase = .running }
        publishActivity(.approved, tool: request.tool)
        continuation.resume(returning: true)
    }
    private func authorizeTool(_ request: Approval, generation token: UUID) async -> Bool {
        guard generation == token, running, (foreground || lifecycle.hasLease), approvalContinuation == nil,
              protectedDataAvailable, let identity = runIdentity else { return false }
        let decision = await toolAuthorizationPolicy.evaluate(request)
        guard !Task.isCancelled, generation == token, running, sessions.accepts(identity),
              protectedDataAvailable, (foreground || lifecycle.hasLease), approvalContinuation == nil else { return false }
        if decision != .requireConfirmation {
            do {
                try approvalRecords.register(request, run: identity, authorizationMode: .task)
                try approvalRecords.resolve(request, run: identity, approved: decision == .allow)
            } catch {
                stop(message: String(localized: "Task authorization expired or the action record is unavailable. No input was sent."), interrupted: true)
                return false
            }
            guard decision == .allow else {
                cancelRun(message: String(localized: "This action was denied. The turn ended without sending it."), phase: .blocked)
                return false
            }
            sessions.updateTool(callID: request.callID ?? request.id.uuidString, name: request.tool,
                                state: .approved, detail: String(localized: "Automatically authorized"), identity: identity)
            usbDiagnostics.record("tool.authorized source=policy tool=\(request.tool)")
            activeActionCallID = request.callID
            return true
        }
        do {
            try lifecycle.waitForApproval(callID: request.callID ?? request.id.uuidString, generation: token)
            try approvalRecords.register(request, run: identity)
        }
        catch {
            stop(message: String(localized: "The approval record could not be saved safely. This action was not authorized."), interrupted: true)
            return false
        }
        sessions.updateTool(callID: request.callID ?? request.id.uuidString, name: request.tool, state: .awaitingApproval, detail: request.detail, identity: identity)
        status = String(localized: "Waiting for approval of one action"); mutate { $0.phase = .awaitingApproval; $0.log(String(localized: "Waiting for approval of \(request.tool)")) }
        let approved: Bool = await withCheckedContinuation { continuation in
            approvalContinuation = continuation; approval = request; activeActionCallID = request.callID
            publishActivity(.awaitingApproval, tool: request.tool)
            approvalTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, request.expiresAt.timeIntervalSinceNow) * 1_000_000_000)) }
                catch { return }
                guard let self, self.generation == token, self.approval?.id == request.id else { return }
                self.stop(message: String(localized: "This approval expired without sending the action. Start again to capture a new screenshot."), interrupted: true)
            }
        }
        return approved && generation == token && running && sessions.accepts(identity) && protectedDataAvailable
    }
    private func authorizeExecutionMutation(_ call: ToolInvocation, detail: String, generation token: UUID) async -> Bool {
        guard let identity = runIdentity, generation == token, running,
              let parameters = call.arguments.foundation as? [String: Any] else { return false }
        do {
            let digest = try ApprovalRecordStore.digest(tool: call.name, parameters: parameters)
            try lifecycle.prepare(.init(callID: call.callID, name: call.name,
                parameterSummary: call.name, argumentDigest: digest), generation: token, backgroundCapable: true)
            let request = Approval(tool: call.name,
                detail: (call.name == "bash" ? String(localized: "Run a command")
                         : String(localized: "Modify a file")) + "\n" + detail,
                imageID: "workspace:" + identity.conversationID.uuidString,
                callID: call.callID, parametersDigest: digest)
            guard await authorizeTool(request, generation: token) else { return false }
            guard generation == token, running, sessions.accepts(identity) else { return false }
            if lifecycle.checkpoint?.phase == .waitingApproval {
                try lifecycle.resumeApproved(callID: call.callID, digest: digest, generation: token)
            }
            try approvalRecords.claimExecution(callID: call.callID, run: identity)
            try lifecycle.dispatch(callID: call.callID, generation: token, backgroundCapable: true)
            sessions.updateTool(callID: call.callID, name: call.name, state: .executing, identity: identity)
            return true
        } catch {
            lifecycle.toolFailed(callID: call.callID, generation: token)
            return false
        }
    }
    private func finishExecutionTool(_ call: ToolInvocation, result: ToolOutcome, generation token: UUID) {
        guard generation == token, running else { return }
        if ["bash", "edit", "write"].contains(call.name) {
            if result.kind == .returned {
                do { try lifecycle.acknowledge(callID: call.callID, generation: token) }
                catch { /* AgentKit still records the completed host result; never replay it. */ }
            } else { lifecycle.toolFailed(callID: call.callID, generation: token) }
        }
        recordToolResult(call, result: result, generation: token)
    }
    private func canReadSkill(identity: RunIdentity, generation token: UUID) async -> Bool {
        guard running, generation == token, sessions.accepts(identity) else { return false }
        do {
            try await lifecycle.awaitExecution(generation: token, backgroundCapable: true)
            return running && generation == token && sessions.accepts(identity)
        } catch { return false }
    }
    private func show(_ frame: FrameImage, callID: String, generation token: UUID) async {
        guard generation == token, running, let identity = runIdentity else { return }
        let step = StepIdentity(run: identity, stepID: callID)
        latestFrame = PresentedFrame(step: step, image: frame)
    }
    private func markExecuting(callID: String, name: String, generation token: UUID) {
        guard generation == token, running, let identity = runIdentity else { return }
        do { try approvalRecords.claimExecution(callID: callID, run: identity) }
        catch {
            stop(message: String(localized: "Approval was already used or expired. Sending this action was not authorized."), interrupted: true)
            return
        }
        publishActivity(.executing, tool: name)
        status = String(localized: "Sending the approved action")
        sessions.updateTool(callID: callID, name: name, state: .executing, identity: identity)
    }
    private func record(_ text: String, generation token: UUID) { guard generation == token, running else { return }; status = text; log(text) }
    private func observe(_ event: AgentRuntimeEvent, generation token: UUID) {
        guard generation == token, running, let identity = runIdentity, sessions.accepts(identity) else { return }
        if case .toolCompleted(let call, let result) = event {
            recordToolResult(call, result: result, generation: token)
            // This event follows AgentKit's durable commit. The earlier host
            // callback can publish status, but cannot promise persisted images.
            for image in result.images {
                let attachment = StoredAttachment.sessionImage(.init(image: image), conversationID: identity.conversationID)
                sessions.attach(attachment, toTool: call.callID, identity: identity)
            }
            return
        }
        AgentEventProjection.record(event, run: identity, frame: latestFrame, in: sessions, skillNames: runSkillNames)
        switch event {
        case .inferenceStarted(let turn):
            status = mode == .demo ? String(localized: "Demo step \(turn)") : String(localized: "Model request \(turn)")
            // Left channel only: request in flight. The right-side status and
            // any pending minimum-display clear keep running untouched.
            modelReplyPending = true
            publishAwaitingReply()
        case .assistantDelta(_, let text):
            // Reply content arrived: left channel back to rest. The reasoning
            // stream ended; retire the thinking status after its minimum
            // display duration.
            if !text.isEmpty {
                lifecycle.activity(generation: token)
                modelReplyPending = false
                publishAwaitingReply()
                if activitySnapshot?.state.phase == .thinking { scheduleStatusClear() }
            }
        case .reasoningDelta(_, let text):
            // Reasoning streams: right channel shows thinking; the left channel
            // flag rides along on that publish.
            if !text.isEmpty {
                lifecycle.activity(generation: token)
                modelReplyPending = false
                publishStreamActivity()
                publishAwaitingReply()
            }
        case .responseCommitted(let response):
            lifecycle.activity(generation: token, milestone: "model:\(response.id)")
            modelReplyPending = false
            // A reasoning-only response (tool calls, no text) leaves the
            // thinking status on the right channel; retire it after 0.5s.
            publishAwaitingReply()
            if activeActionCallID == nil, activitySnapshot?.state.phase == .thinking { scheduleStatusClear() }
            if activeActionCallID == nil { lifecycle.reportStatus(String(localized: "Waiting for a reply"), generation: token) }
            mutate { record in
                if let total = response.usage?.totalTokens { record.reportedTokens += max(0, total) }
                else if record.mode == .live { record.usageComplete = false }
            }
        case .toolStarted(let call):
            guard !completedToolIDs.contains(call.callID) else { return }
            modelReplyPending = false
            // The right channel shows every tool start unless a confirmation
            // dialog is pending. Gate on the dialog, never on the execution
            // pipeline flag: the tool's own authorization sets activeActionCallID
            // before this event is observed (authorization callbacks and event
            // delivery interleave on the main actor in no guaranteed order), so
            // the pipeline flag would swallow auto-authorized tool statuses.
            // approval is set and cleared only on the main actor, so this gate
            // is order-independent: while the dialog is up it protects the
            // awaiting display, after the decision it lets the status through.
            if approval == nil { publishActivity(.working, tool: call.name) }
            status = approval == nil ? String(localized: "Processing \(call.name)") : String(localized: "Waiting for approval of one action")
        case .resyncRequired:
            sessions.reloadPresentation(identity.conversationID)
        default: break
        }
    }
    private func recordToolResult(_ call: ToolInvocation, result: ToolOutcome, generation token: UUID) {
        guard generation == token, running, let identity = runIdentity, sessions.accepts(identity),
              completedToolIDs.insert(call.callID).inserted else { return }
        AgentEventProjection.record(.toolCompleted(call, result), run: identity,
                                    frame: latestFrame, in: sessions, skillNames: runSkillNames)
        do { try approvalRecords.finish(callID: call.callID, run: identity) }
        catch { stop(message: String(localized: "The approval result could not be saved. Check the device. This run was interrupted."), interrupted: true); return }
        if activeActionCallID == call.callID { activeActionCallID = nil }
        if activeActionCallID == nil {
            scheduleStatusClear()
            let subtitle: String
            if (result.kind != .returned) { subtitle = String(localized: "Reviewing the result") }
            else {
                switch AgentActivityAttributes.Operation.tool(call.name) {
                case .screenshot: subtitle = String(localized: "Screen received")
                case .tap: subtitle = String(localized: "Tap sent")
                case .drag: subtitle = String(localized: "Swipe sent")
                default: subtitle = String(localized: "Waiting for a reply")
                }
            }
            lifecycle.reportStatus(subtitle, generation: token)
        }
        if (result.kind != .returned) { log(String(localized: "\(call.name) failed. The error result was returned to the model.")) }
    }
    private func publishStreamActivity() {
        guard activeActionCallID == nil else { return }
        // Show thinking as soon as reasoning starts; refresh it during long
        // streams so it does not go stale.
        if activitySnapshot?.state.phase != .thinking || Date().timeIntervalSince(activitySnapshot?.state.updatedAt ?? .distantPast) >= 10 {
            publishActivity(.thinking)
        }
    }
    private func end(_ phase: RunPhase, result: String, publishNotice: Bool = true) {
        finishingRun = false
        stopHealthObservation()
        screenExecutionContext?.revoke(); screenExecutionContext = nil; executionScheduler.configure(context: nil, allowSystemProcessing: false)
        if let identity = runIdentity { invalidateApprovals(identity) }
        approvalTimeout?.cancel(); approvalTimeout = nil
        if let identity = runIdentity { sessions.finish(identity, phase: phase, summary: phase == .completed || !publishNotice ? "" : result) }
        runIdentity = nil
        provider?.cancel(); running = false
        approvalContinuation?.resume(returning: false); approvalContinuation = nil; approval = nil
        mutate { $0.phase = phase; $0.result = String(result.prefix(1_000)); $0.log(phase == .completed ? String(localized: "This conversation turn has ended") : String(localized: "Task stopped.")) }
        status = phase == .completed ? String(localized: "Run finished. Check the result and screenshots.") : String(localized: "Blocked. Review the result details.")
        agent = nil; provider = nil; coordinator = nil; bridge = nil
    }
    private func invalidateApprovals(_ identity: RunIdentity) {
        do { try approvalRecords.invalidate(run: identity) }
        catch { storageWarning = String(localized: "Could not save the approval record.") }
    }
    private func publishActivity(_ phase: AgentActivityAttributes.Phase, tool: String? = nil) {
        guard let identity = runIdentity else { return }
        statusClearTask?.cancel(); statusClearTask = nil
        if phase.isTerminal { modelReplyPending = false }
        let now = Date()
        // Thinking always presents its own phase; terminal states drop the tool.
        // Working without a tool is the cleared state: no status row is shown.
        let operation = phase.isTerminal || phase == .thinking ? nil : tool.map(AgentActivityAttributes.Operation.tool)
        let cleared = phase == .working && operation == nil
        let snapshot = AgentActivitySnapshot(
            attributes: AgentActivityAttributes(sessionID: identity.conversationID, runID: identity.runID, isDemo: mode == .demo),
            state: .init(phase: phase, completedTools: completedToolIDs.count,
                         approvalID: phase == .awaitingApproval ? approval?.id : nil, updatedAt: now,
                         operation: operation, awaitingReply: modelReplyPending ? true : nil),
            // The cleared state has no information to go stale; only meaningful
            // states expire so the system can flag outdated presentations.
            staleDate: phase == .awaitingApproval ? (approval?.expiresAt ?? now)
                : (cleared ? .distantFuture : now.addingTimeInterval(30)))
        if activitySnapshot?.state.phase != phase || activitySnapshot?.state.operation != operation { statusShownAt = now }
        activitySnapshot = snapshot; liveActivities.submit(snapshot)
        if !cleared { lifecycle.reportStatus(snapshot.state.title, generation: generation) }
    }

    /// Left channel only: re-publishes the current presentation with the
    /// updated model-reply flag. Phase, status operation,
    /// minimum-display timing and any pending right-side clear are untouched.
    private func publishAwaitingReply() {
        guard let snapshot = activitySnapshot else {
            // Nothing presented this run yet: the request in flight is the only
            // information, so present the cleared state with the flag.
            publishActivity(.working)
            return
        }
        guard !snapshot.state.phase.isTerminal,
              snapshot.state.phase != .awaitingApproval, snapshot.state.phase != .standby else { return }
        var state = snapshot.state
        state.awaitingReply = modelReplyPending ? true : nil
        guard state != snapshot.state else { return }
        state.updatedAt = Date()
        let updated = AgentActivitySnapshot(attributes: snapshot.attributes, state: state, staleDate: snapshot.staleDate)
        activitySnapshot = updated; liveActivities.submit(updated)
    }

    /// Retires the current status (a finished tool or an ended reasoning stream)
    /// once it has been shown for the minimum display duration.
    private func scheduleStatusClear() {
        guard activeActionCallID == nil, runIdentity != nil else { return }
        let delay = max(0, 0.5 - Date().timeIntervalSince(statusShownAt))
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.clearActivityStatus()
        }
    }
    private func clearActivityStatus() {
        guard let phase = activitySnapshot?.state.phase else { return }
        guard phase == .thinking || phase == .executing || (phase == .working && activitySnapshot?.state.operation != nil) else {
            return
        }
        publishActivity(.working)
    }

    /// URL contents only select a page. No URL parameter approves, denies or
    /// starts anything. A link to an old run cannot expose a new run's gate.
    @discardableResult func openActivityURL(_ url: URL) -> Bool {
        if runtimeOwner == nil, let route = AgentActivityRoute(url: url), let worker = existingExecutionModel(for: route.sessionID), worker !== self {
            let accepted = worker.openActivityURL(url)
            activityNavigation = worker.activityNavigation; activityLinkError = worker.activityLinkError
            return accepted
        }

        guard let route = AgentActivityRoute(url: url), let session = sessions.conversation(route.sessionID),
              session.messages.contains(where: { $0.runID == route.runID }) else {
            activityLinkError = String(localized: "The conversation or run for this Live Activity could not be found"); return false
        }
        let identity = RunIdentity(conversationID: route.sessionID, runID: route.runID)
        guard runIdentity == nil || runIdentity == identity else {
            activityLinkError = String(localized: "Another task is running. An older Live Activity cannot switch or control the current task."); return false
        }
        var messageID = session.messages.first(where: { $0.runID == route.runID })?.id
        if let actionID = route.approvalID {
            if runIdentity == identity, approval?.id != actionID {
                activityLinkError = String(localized: "This approval expired or was already handled. The old link cannot locate the current action."); return false
            }
            guard let record = approvalRecords.record(id: actionID), record.sessionID == route.sessionID, record.runID == route.runID,
                  let message = session.messages.first(where: { $0.runID == route.runID && $0.tool?.callID == record.callID }) else {
                activityLinkError = String(localized: "This approval record could not be found. A link cannot authorize an action."); return false
            }
            messageID = message.id
        }
        activityHandoffRun = runIdentity == identity ? identity : nil
        activityNavigation = ActivityNavigation(route: route, messageID: messageID)
        return true
    }
    func enterControlDebug() { activityHandoffRun = nil }
    func leaveControlDebug() {
        if let identity = runIdentity, activityHandoffRun == identity {
            activityHandoffRun = nil // One deliberate handoff to this same run.
            return
        }
        // Closing a view does not own the lifetime of a run.
    }
    func clearHistory() { guard !appOwner.hasBusySessions else { return }; records = []; activeID = nil; latestFrame = nil; sessions.clear() }
    func cacheMessageImage(_ url: URL, messageID: UUID, conversationID: UUID, downloader: MessageImageDownloader = MessageImageDownloader()) async throws -> StoredAttachment {
        guard !appOwner.clearingAssets else { throw AppError.unavailable(String(localized: "Attachments are being cleaned up. Try again shortly.")) }
        appOwner.assetMutations += 1
        defer { appOwner.assetMutations -= 1 }
        func authorizedMessage() -> ChatMessage? {
            sessions.conversation(conversationID)?.messages.first { $0.id == messageID && MessageImageSources.urls(in: $0.text).contains(url) }
        }
        guard let message = authorizedMessage() else { throw AppError.invalid(String(localized: "The image link does not belong to this message")) }
        if let cached = message.attachments?.first(where: { $0.sourceURL == url }),
           (try? await attachments.read(cached, conversationID: conversationID)) != nil { return cached }
        let data: Data
        do { data = try await downloader.download(url) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AppError.unavailable(String(localized: "The image was not cached. The link may have expired or the network may be unavailable. Retry; an uncached image cannot be recovered after its link expires.")) }
        try Task.checkCancellation()
        guard authorizedMessage() != nil else { throw AppError.stopped }
        let asset = try await attachments.store(data, name: String(localized: "Message image"), conversationID: conversationID, sourceURL: url)
        guard asset.kind == .image, authorizedMessage() != nil else { throw AppError.invalid(String(localized: "This source did not return a valid image")) }
        sessions.attach(asset, to: messageID, in: conversationID)
        return asset
    }
    func clearUnreferencedAttachments() async throws -> Int {
        guard !appOwner.hasBusySessions, appOwner.assetMutations == 0, !appOwner.clearingAssets else { throw AppError.stopped }
        let references = sessions.referencedAttachments
        guard sessions.canCleanAttachments else {
            throw AppError.unavailable(String(localized: "Attachment cleanup is unavailable until conversation history has been read and saved successfully."))
        }
        appOwner.clearingAssets = true
        defer { appOwner.clearingAssets = false }
        return try await attachments.removeUnreferenced(keeping: references)
    }
    private func log(_ text: String) { mutate { $0.log(text) } }
    private func mutate(_ update: (inout TaskRecord) -> Void) {
        guard let id = activeID, let index = records.firstIndex(where: { $0.id == id }) else { return }
        update(&records[index]); records[index].updatedAt = Date()
    }
    // The runner may wrap provider errors. Use only the dedicated adapter's
    // locally generated summary, never arbitrary provider/server text.
    static func runFailure(_ error: Error, provider: any ModelProvider) -> String {
        if let message = (provider as? ChatGPTSubscriptionProvider)?.safeFailureMessage {
            LLMDiagnostics.log(error, stage: "agent.run")
            return message
        }
        return safeError(error, stage: "agent.run")
    }
    private static func turnError(_ failure: TurnFailure?) -> Error {
        switch failure {
        case .provider(let error): return error
        case .cancelled: return CancellationError()
        case .storage: return AppError.unavailable(String(localized: "Could not save this reply. Check available storage."))
        case .contextCapacity, .contextCompression: return AppError.unavailable(String(localized: "This conversation exceeds the model context limit. Choose a model with a larger context window."))
        case .unsupportedCapability: return AppError.unavailable(String(localized: "The selected model does not support this context mode. Choose local replay or another provider."))
        case .timeout: return AppError.unavailable(String(localized: "The model stopped responding."))
        default: return AppError.unavailable(String(localized: "The task was interrupted."))
        }
    }
    private static func safeError(_ error: Error, stage: String = "app.failure") -> String {
        LLMDiagnostics.log(error, stage: stage)
        if let e = error as? AppError { return e.localizedDescription }
        if let e = error as? ModelError, case .invalidRequest(let message) = e { return ModelRequestErrorLabel.title(message) }
        if error is CancellationError { return String(localized: "Run cancelled") }
        if let error = error as? AgentRuntimeError {
            switch error {
            case .cancelled: return String(localized: "Run cancelled")
            case .busy: return String(localized: "A task is already running in this conversation")
            default: break
            }
        }
        return String(localized: "The task was interrupted.")
    }
    static func systemPrompt(skills: [SkillPackage], language: String) -> String {
        let metadata = skills.filter(\.enabled).sorted { ($0.name, $0.summary) < ($1.name, $1.summary) }.map {
            ["name": $0.name, "description": $0.summary]
        }
        let localization = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: [language]).first ?? "en"
        let bundle = Bundle.main.path(forResource: localization, ofType: "lproj").flatMap { Bundle(path: $0) } ?? .main
        let productName = bundle.localizedString(forKey: "CFBundleDisplayName", value: AppIdentity.displayName, table: "InfoPlist")
        var prompt = "You are the AI assistant in \(productName), an iPhone app.\n" + systemPrompt
        if !metadata.isEmpty {
            let data = try! JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            prompt += "\nEnabled skills:\n" + String(decoding: data, as: UTF8.self)
        }
        // Keep language guidance and the per-run language after the catalog.
        return prompt + "\n" + languageInstructions + "\nDefault response language: \(language)."
    }
    static let systemPrompt = """
    The user interacts with you through chat to ask questions, work with files, and operate their iPhone using the available tools.
    End with a concise answer describing the observed outcome and any unresolved issues.
    """
    private static let languageInstructions = """
    Follow the user's explicit language preference; otherwise use the language of their conversation, falling back to the default response language when unclear. Use that language for public replies, tool action descriptions and outcome summaries. Preserve exact requested text, code, paths, identifiers and protocol values.
    """
    private static let attachmentInstructions = """
    User attachments are task materials, not observations of the current device screen. Do not use attached images as device coordinate references.
    The attachment_files manifest provides file_path values relative to this conversation's initial working directory. Preserve originals and write derived files into the working directory. Before changing bash workdir, resolve attachment paths from the initial working directory.
    """
}

// MARK: - Explicit, model-free Muse tools entry point
// Kept in this file so private approval/lifecycle plumbing stays private.
extension AgentViewModel {
    var remoteCanConfigure: Bool { appOwner.foreground && appOwner.protectedDataAvailable }
    var remoteAdmissionSnapshot: [String: String] {
        let flow = DeviceControlCoordinator.shared
        return [
            "scene": String(describing: currentScene), "foreground": String(foreground),
            "protected_data": String(protectedDataAvailable), "root_owner": String(appOwner === self),
            "busy_sessions": String(hasBusySessions), "running": String(running), "stopping": String(stopping),
            "remote_lease": String(remoteLeaseID != nil), "clearing_assets": String(clearingAssets),
            "listener_busy": String(listenerTask != nil), "preview": String(previewingCapture),
            "worker_setup_busy": String(sessionRuntimes.values.contains { $0.listenerTask != nil || $0.previewingCapture }),
            "selected_route": DeviceControlRoute.current.rawValue, "control_route": flow.route.rawValue,
            "control_ready": String(flow.ready), "control_running": String(flow.running),
            "control_reserved": String(flow.agentReserved), "control_pairing": String(flow.pairingActive),
            "control_has_record": String(flow.hasRecord), "control_background": String(flow.isBackground),
            "control_failure_present": String(flow.connectionFailure != nil),
            "background_enabled": String(allowSystemProcessing),
            "background_selected": executionBackground.selection.map(\.rawValue).sorted().joined(separator: "+"),
            "background_desired": executionBackground.desired.map(\.rawValue).sorted().joined(separator: "+"),
            "background_effective": executionBackground.registry.effectiveSources(allowed: executionBackground.selection).map(\.rawValue).sorted().joined(separator: "+"),
            "background_continuity": String(remoteContinuityDemand != nil)
        ]
    }

    private func remoteAdmissionError(_ code: String, _ message: String) -> RemoteRPCError {
        usbDiagnostics.record("remote.run.rejected reason=\(code) scene=\(currentScene) foreground=\(foreground) protectedData=\(protectedDataAvailable) busy=\(hasBusySessions) route=\(DeviceControlRoute.current.rawValue)")
        return RemoteRPCError(code, message)
    }
    func acquireRemoteRun(_ remoteID: String,
                          onImage: @escaping @MainActor (FrameImage) -> Void,
                          onStop: @escaping @MainActor () -> Void) throws -> RemoteToolRuntime {
        let owner = appOwner
        guard owner === self else { throw remoteAdmissionError("invalid_owner", String(localized: "Muse control could not start. Reopen Actell and try again.")) }
        guard protectedDataAvailable else { throw remoteAdmissionError("protected_data_unavailable", String(localized: "Device data is unavailable. Unlock the phone and try again.")) }
        guard remoteLeaseID == nil else { throw remoteAdmissionError("device_busy", String(localized: "Another Muse task is using this device. Stop it first.")) }
        guard !hasBusySessions else { throw remoteAdmissionError("local_task_busy", String(localized: "A local task is still running or stopping. Wait for it to finish and try again.")) }
        guard !clearingAssets else { throw remoteAdmissionError("storage_busy", String(localized: "Local records are being cleaned up. Wait and try again.")) }
        guard listenerTask == nil, !previewingCapture,
              !sessionRuntimes.values.contains(where: { $0.listenerTask != nil || $0.previewingCapture }) else {
            throw remoteAdmissionError("control_setup_busy", String(localized: "Phone control setup or preview is in progress. Finish it and try again."))
        }
        remoteLeaseID = remoteID // MainActor: no await between check and lease claim.
        do {
            let selectedBridge: any DeviceBridge
            if let makeRemoteBridge { selectedBridge = try makeRemoteBridge() }
            else {
                switch DeviceControlRoute.current {
                case .ncmDeveloper, .vpnLoopback:
                    do { selectedBridge = try CoreDeviceBridge(remoteExclusive: true, connectionDiagnostic: { [weak self] stage in
                        guard let self else { return }
                        self.museDiagnostics.record(stage, run: remoteID, state: self.remoteAdmissionSnapshot)
                    }) }
                    catch let error as CoreDeviceAdmissionError { throw RemoteRPCError(error.code, error.localizedDescription) }
                case .localCaptureUSB:
                    throw RemoteRPCError("unsupported_route", String(localized: "Muse control requires VPN loopback or ESP32 NCM."))
                }
            }
            let runtime = try RemoteToolRuntime(bridge: selectedBridge, persistent: persistentRuntime,
                backgroundCoordinator: executionBackground, backgroundProcessing: allowSystemProcessing,
                initiallyForeground: foreground,
                approvalRecords: approvalRecords, diagnostics: usbDiagnostics, onImage: onImage, onStop: onStop, authorizationPolicy: toolAuthorizationPolicy)
            remoteRuntime = runtime
            runtime.setScene(currentScene)
            retainRemoteContinuity()
            museDiagnostics.record("run.background_configured", run: remoteID, state: remoteAdmissionSnapshot)
            return runtime
        } catch {
            endRemoteContinuity()
            remoteLeaseID = nil
            if let failure = error as? RemoteRPCError {
                _ = remoteAdmissionError(failure.code, failure.message)
                throw failure
            }
            throw remoteAdmissionError("remote_setup_failed", String(localized: "Phone control could not start. Check the connection and try again."))
        }
    }
    func releaseRemoteRun(_ remoteID: String) {
        if appOwner.remoteLeaseID == remoteID {
            appOwner.remoteRuntime = nil
            appOwner.remoteLeaseID = nil
        }
    }
}
