import Foundation
import SwiftAgentKit

/// Executes authenticated device tools without a ConversationStore, Agent, model,
/// chat messages, task-history projection or Live Activity conversation links.
@MainActor final class RemoteToolRuntime {
    let lifecycle: RunLifecycleCoordinator
    private let scheduler: RunExecutionScheduler
    private let bridge: any DeviceBridge
    private let approvalRecords: ApprovalRecordStore
    private let diagnostics: USBDiagnosticsLog
    // Compatibility identity for shared one-use grants/checkpoints only. It is
    // never registered as a conversation or stored under the Sessions directory.
    private let identity = RunIdentity(conversationID: UUID(), runID: UUID())
    private let generation = UUID()
    private var action: ActionCoordinator?
    private var protectedDataAvailable = true
    private(set) var running = false
    private(set) var stopping = false
    private var cleanup: Task<Void, Never>?
    private var healthObserver: UUID?
    private var onStop: (@MainActor () -> Void)?

    init(bridge: any DeviceBridge, persistent: Bool, directory: URL? = nil,
         backgroundCoordinator: BackgroundExecutionCoordinator = .shared,
         backgroundProcessing: Bool? = nil, initiallyForeground: Bool = true,
         approvalRecords: ApprovalRecordStore, diagnostics: USBDiagnosticsLog,
         onImage: @escaping @MainActor (FrameImage) -> Void,
         onStop: @escaping @MainActor () -> Void) throws {
        self.bridge = bridge; self.approvalRecords = approvalRecords; self.diagnostics = diagnostics
        scheduler = RunExecutionScheduler(coordinator: backgroundCoordinator)
        let root = directory ?? URL.applicationSupportDirectory.appending(path: "PhoneAgent/Remote/Execution")
        lifecycle = RunLifecycleFactory.make(persistent: persistent, scheduler: scheduler, directory: root)
        scheduler.setForeground(initiallyForeground)
        lifecycle.setForeground(initiallyForeground)
        scheduler.configure(context: bridge.executionContext, allowSystemProcessing: backgroundProcessing ?? persistent,
                            selection: backgroundCoordinator.selection, runID: identity.runID, userInitiated: false)
        do { try lifecycle.begin(identity: identity, generation: generation, allowBackgroundStart: !initiallyForeground) }
        catch {
            bridge.executionContext?.revoke(); bridge.cancelTransport()
            scheduler.configure(context: nil, allowSystemProcessing: false)
            Task { await bridge.stop() }
            throw RemoteRPCError("checkpoint_unavailable", String(localized: "The Muse task could not be saved and has not started. Reopen Actell and try again."), underlying: error)
        }
        self.onStop = onStop; running = true
        lifecycle.onPause = { [weak self] message in self?.stop(message: message, interrupted: true) }
        action = ActionCoordinator(bridge: bridge, limits: AgentLimits(),
            approve: { [weak self] request in await self?.authorize(request) ?? false },
            onImage: { [weak self] frame, _ in
                await self?.receive(frame, callback: onImage)
            },
            onReceipt: { message in diagnostics.record("remote.receipt " + message) },
            onExecuting: { [weak self] callID, _ in await self?.claim(callID) },
            lifecycle: lifecycle, generation: generation,
            authorizationMode: MuseCompanionAuthorization.inputMode, diagnostics: diagnostics)
        healthObserver = bridge.executionContext?.observeHealth { [weak self] in
            Task { @MainActor in self?.stop(message: String(localized: "Phone control disconnected. Input has stopped."), interrupted: true) }
        }
    }
    private func authorize(_ request: Approval) -> Bool {
        // The shared action lifecycle checks execution readiness and dispatch;
        // this remote approval path adds no separate foreground/lease gate.
        guard running, !stopping, protectedDataAvailable else { return false }
        do {
            try bridge.executionContext?.requireHealthy()
            try approvalRecords.register(request, run: identity, authorizationMode: .task)
            try approvalRecords.resolve(request, run: identity, approved: true)
            return true
        } catch { stop(message: String(localized: "Muse authorization could not be saved. No input was sent."), interrupted: true); return false }
    }
    private func claim(_ callID: String) {
        guard running, !stopping else { return }
        do { try approvalRecords.claimExecution(callID: callID, run: identity) }
        catch { stop(message: String(localized: "Muse authorization expired. No input was sent."), interrupted: true) }
    }
    private func receive(_ frame: FrameImage, callback: @MainActor (FrameImage) -> Void) {
        if running, !stopping { callback(frame) }
    }
    func executeRemoteTool(name: String, arguments: [String: Any], callID: String,
                           imageID: String?, deadline: Date) async throws -> AgentToolResult {
        guard running, !stopping, protectedDataAvailable, let action else { throw AppError.stopped }
        let result = try await action.executeRemote(name: name, parameters: arguments, callID: callID,
                                                    expectedImageID: imageID, deadline: deadline)
        if running, !stopping { try approvalRecords.finish(callID: callID, run: identity) }
        return result
    }
    func remoteFailureCode() async -> String? { await action?.remoteFailureCode }
    func remoteDelivery(_ callID: String) -> RunCheckpoint.Delivery? {
        lifecycle.checkpoint?.tools.first(where: { $0.callID == callID })?.delivery
    }
    func setScene(_ scene: ScreenUSBExecutionContext.Scene) {
        bridge.executionContext?.setScene(scene)
        lifecycle.setForeground(scene != .background)
    }
    func setProtectedDataAvailable(_ available: Bool) {
        protectedDataAvailable = available
        if !available { stop(message: String(localized: "The device is locked or its data is unavailable. Muse input has stopped."), interrupted: true) }
    }
    func stop(message: String, interrupted: Bool = false) {
        guard running, !stopping else { return }
        running = false; stopping = true
        onStop?() // Fence the remote journal before transport cancellation.
        onStop = nil
        if let healthObserver { bridge.executionContext?.removeHealthObserver(healthObserver) }
        healthObserver = nil
        lifecycle.stop(message: message)
        bridge.executionContext?.revoke(); bridge.cancelTransport()
        scheduler.configure(context: nil, allowSystemProcessing: false)
        do { try approvalRecords.invalidate(run: identity) }
        catch { diagnostics.record("remote.approval.invalidate_failed") }
        let action = action, bridge = bridge
        cleanup = Task { [weak self] in
            if let action { await action.stop() } else { await bridge.stop() }
            self?.stopping = false
        }
    }
    func waitForRemoteRelease() async { await cleanup?.value }
}
