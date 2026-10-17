// Selectively ported from feature/background-runs @ 2509d7098fc8a3af4c62bd8fc20e911df4aa4933.
// Integration selects either a capture context or a system processing lease.
import Foundation
import Combine

/// A delivered execution capability, never a successful scheduler submission.
/// Sources include SCK/USB health, a delivered system task, and active AVKit PiP.
@MainActor protocol RunBackgroundLease: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    var backgroundReady: Bool { get }
    var requiresRunPause: Bool { get }
    func report(completed: Int, subtitle: String)
    func complete(success: Bool)
}
extension RunBackgroundLease { var backgroundReady: Bool { true }; var requiresRunPause: Bool { false } }

@MainActor protocol RunBackgroundScheduler {
    func endRun()
    func setForeground(_ active: Bool)
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws
    func cancel(identifier: String)
}
extension RunBackgroundScheduler {
    func endRun() {}
    func setForeground(_ active: Bool) {}
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws { try submit(identifier: identifier, launched: launched) }
}
@MainActor struct ForegroundOnlyScheduler: RunBackgroundScheduler {
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        throw AppError.unavailable(String(localized: "Background execution is unavailable on this system. Keep the app open to continue."))
    }
    func cancel(identifier: String) {}
}

struct RunCheckpoint: Codable, Equatable {
    enum Phase: String, Codable { case running, waitingApproval, paused, stopped, completed }
    enum Delivery: String, Codable { case prepared, dispatching, acknowledged, observedResult, outcomeUnknown, failed }
    struct Tool: Codable, Equatable, Sendable {
        let callID: String
        let name: String
        /// Whitelisted numeric arguments plus hashes; no purpose, text, images or credentials.
        let parameterSummary: String
        let argumentDigest: String
        var delivery: Delivery = .prepared
    }
    let runID: UUID
    let conversationID: UUID
    let generation: UUID
    var segment = 0
    var segmentID: String?
    var phase: Phase = .running
    var tools: [Tool] = []
    var pendingApproval: String?
    var lastConfirmedStep: String?
    var milestones: Set<String> = []
    var message = ""
}

@MainActor protocol RunCheckpointStorage {
    func load() throws -> RunCheckpoint?
    func save(_ checkpoint: RunCheckpoint) throws
    func loadRecoveries() throws -> [RunCheckpoint]
    func saveRecoveries(_ checkpoints: [RunCheckpoint]) throws
}
extension RunCheckpointStorage {
    func loadRecoveries() throws -> [RunCheckpoint] { try load().map { [$0] } ?? [] }
    func saveRecoveries(_ checkpoints: [RunCheckpoint]) throws {}
}
@MainActor final class RunCheckpointStore: RunCheckpointStorage {
    private let file: URL
    init(directory: URL? = nil) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PhoneAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excludedRoot = root
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(attributes)
        file = root.appendingPathComponent("run-checkpoint-v1.json")
    }
    func load() throws -> RunCheckpoint? { try loadRecoveries().first }
    func loadRecoveries() throws -> [RunCheckpoint] {
        let root = file.deletingLastPathComponent()
        var values: [RunCheckpoint] = []
        for source in [file, root.appendingPathComponent("usb-run-checkpoint-v1.json")] {
            if FileManager.default.fileExists(atPath: source.path) {
                values.append(try JSONDecoder().decode(RunCheckpoint.self, from: Data(contentsOf: source)))
            }
        }
        let archive = root.appendingPathComponent("run-recovery-v1.json")
        if FileManager.default.fileExists(atPath: archive.path) {
            values += try JSONDecoder().decode([RunCheckpoint].self, from: Data(contentsOf: archive))
        }
        return values
    }
    func saveRecoveries(_ checkpoints: [RunCheckpoint]) throws {
        let archive = file.deletingLastPathComponent().appendingPathComponent("run-recovery-v1.json")
        try JSONEncoder().encode(checkpoints).write(to: archive, options: [.atomic, .completeFileProtection])
    }
    func save(_ checkpoint: RunCheckpoint) throws {
        // This route stops on lock. The journal excludes text, screenshots and secrets.
        // Preserve full file protection; do not expand lock-screen access.
        try JSONEncoder().encode(checkpoint).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
@MainActor final class MemoryRunCheckpointStore: RunCheckpointStorage {
    var value: RunCheckpoint?
    func load() throws -> RunCheckpoint? { value }
    func save(_ checkpoint: RunCheckpoint) throws { value = checkpoint }
}

/// Owned by the App's model, independent of any conversation View's lifetime.
/// All lifecycle/journal mutations are serialized on MainActor; no await lies
/// between a durable dispatching transition and returning dispatch permission.
@MainActor final class RunLifecycleCoordinator: ObservableObject {
    @Published private(set) var checkpoint: RunCheckpoint?
    private(set) var recoveries: [RunCheckpoint] = []
    @Published private(set) var backgroundStatus = String(localized: "Background execution requires an active capture, audio, Picture in Picture, location, or a system background task.")
    private(set) var foreground = true
    private(set) var hasLease = false
    var canAwaitApprovalInBackground: Bool { checkpoint?.phase == .waitingApproval && activeToolBackgroundCapable }
    var onPause: ((String) -> Void)?
    private let scheduler: any RunBackgroundScheduler
    private let storage: any RunCheckpointStorage
    private let identifierPrefix: String
    private let now: () -> Date
    private let inactivityTimeout: TimeInterval?
    private var lastActivity = Date()
    private var lease: (any RunBackgroundLease)?
    private var activeToolBackgroundCapable = true
    private var watchdog: Task<Void, Never>?
    private var storageHealthy = true
    private var ownsRun = false

    init(scheduler: any RunBackgroundScheduler, storage: any RunCheckpointStorage,
         identifierPrefix: String = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun",
         inactivityTimeout: TimeInterval? = nil, now: @escaping () -> Date = Date.init) {
        self.scheduler = scheduler; self.storage = storage; self.identifierPrefix = identifierPrefix
        self.inactivityTimeout = inactivityTimeout.map { max(1, $0) }; self.now = now
        do {
            let originals = try storage.loadRecoveries()
            // Cancel every recovered system request before clearing its identifier.
            for id in Set(originals.compactMap(\.segmentID)) where id.hasPrefix(identifierPrefix + ".") {
                scheduler.cancel(identifier: id)
            }
            recoveries = RunCheckpoint.mergedRecoveries(originals).map { $0.recovered() }
            // Save the complete recovery set BEFORE rewriting the active journal.
            // A new run may overwrite that journal, never the old unknown actions.
            try storage.saveRecoveries(recoveries)
            checkpoint = recoveries.first
            if let saved = checkpoint { try storage.save(saved) }
            let pending = recoveries.filter { !$0.message.isEmpty }
            if !pending.isEmpty { backgroundStatus = pending.map(\.message).joined(separator: "\n") }

        } catch { storageHealthy = false; backgroundStatus = String(localized: "Your saved progress could not be read or written. The original file was kept and execution was disabled.") }
    }

    func begin(identity: RunIdentity, generation: UUID, allowBackgroundStart: Bool = false) throws {
        guard foreground || allowBackgroundStart, storageHealthy, !ownsRun else { throw AppError.stopped }
        activeToolBackgroundCapable = true
        checkpoint = RunCheckpoint(runID: identity.runID, conversationID: identity.conversationID, generation: generation)
        try persist(); ownsRun = true; requestSegment(allowBackgroundStart: allowBackgroundStart)
        guard storageHealthy else { throw AppError.unavailable(String(localized: "Could not save progress")) }
        lastActivity = now()
        watchdog?.cancel()
        if inactivityTimeout != nil { watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                self.checkInactivity()
            }
        } }
    }
    private func requestSegment(allowBackgroundStart: Bool = false) {
        guard foreground || allowBackgroundStart, checkpoint?.phase == .running else { return }
        checkpoint?.segment += 1
        let id = identifierPrefix + "." + UUID().uuidString
        checkpoint?.segmentID = id
        backgroundStatus = String(localized: "Checking background availability")
        do {
            try persist()
            try scheduler.submit(identifier: id, launched: { [weak self] lease in
                guard let self else { lease.complete(success: false); return }
                self.accept(lease, identifier: id)
            }, failed: { [weak self] in self?.submissionRejected(identifier: id) })
        } catch {
            scheduler.cancel(identifier: id)
            if checkpoint?.segmentID == id { checkpoint?.segmentID = nil }
            backgroundStatus = String(localized: "Background execution was not allowed. The task will pause when you leave the app.")
            saveOrPause()
        }
    }
    private func submissionRejected(identifier: String) {
        guard ownsRun, checkpoint?.phase == .running, checkpoint?.segmentID == identifier, !hasLease else { return }
        scheduler.cancel(identifier: identifier); checkpoint?.segmentID = nil
        backgroundStatus = String(localized: "The background request was not allowed. The task will pause when you leave the app.")
        saveOrPause()
        if !foreground { pause(String(localized: "The system did not allow background execution. The task was paused and previous actions will not be repeated.")) }
    }
    private func accept(_ incoming: any RunBackgroundLease, identifier: String) {
        if let lease, lease === incoming { return }
        guard checkpoint?.phase == .running, checkpoint?.segmentID == identifier, lease == nil else {
            incoming.complete(success: false); return
        }
        lease = incoming; hasLease = true
        incoming.expirationHandler = { [weak self] in
            guard self?.checkpoint?.segmentID == identifier, self?.hasLease == true else { return }
            guard let self else { return }
            if incoming.requiresRunPause {
                self.pause(String(localized: "The system background task expired or was canceled. Continue manually when ready."))
            } else if self.foreground {
                // Returning to the app closes PiP, not the foreground task.
                self.lease?.complete(success: false); self.lease = nil; self.hasLease = false
                self.scheduler.cancel(identifier: identifier)
                self.checkpoint?.segmentID = nil
                self.backgroundStatus = String(localized: "Background execution has ended. Keep the app open and continue manually.")
                self.saveOrPause()
            } else {
                self.pause(String(localized: "Background execution expired. Check your device, then continue manually."))
            }
        }
        backgroundStatus = incoming.backgroundReady ? String(localized: "Background execution is available. Device controls still need verification.") : String(localized: "Waiting for a background option to become available. No device action has been sent.")
        incoming.report(completed: checkpoint?.milestones.count ?? 0, subtitle: String(localized: "Waiting for a model response or tool result. The total number of steps is unknown."))
    }
    func setForeground(_ active: Bool) {
        foreground = active
        scheduler.setForeground(active)
        guard !active, checkpoint?.phase == .running else { return }
        if !hasLease { pause(String(localized: "Background execution was unavailable when you left the app. Continue manually when ready.")) }
        else if !activeToolBackgroundCapable { pause(String(localized: "This device connection has not been verified for background use. Return to the app to check it.")) }
    }
    /// Wait for an actual media receipt during the bounded foreground handoff.
    /// A pending lease is neither background permission nor permission to dispatch.
    func awaitExecution(generation: UUID, backgroundCapable: Bool) async throws {
        while !foreground, hasLease, lease?.backgroundReady == false,
              ownsRun, checkpoint?.generation == generation, checkpoint?.phase == .running {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try requireExecution(generation: generation, backgroundCapable: backgroundCapable)
    }
    func requireExecution(generation: UUID, backgroundCapable: Bool) throws {
        guard ownsRun, checkpoint?.generation == generation, checkpoint?.phase == .running, storageHealthy else { throw AppError.stopped }
        guard foreground || (hasLease && lease?.backgroundReady == true && backgroundCapable) else {
            pause(String(localized: "This step needs the app open or background execution. It was paused and will not be resent automatically."))
            throw AppError.stopped
        }
    }
    func prepare(_ tool: RunCheckpoint.Tool, generation: UUID, backgroundCapable: Bool) throws {
        try requireExecution(generation: generation, backgroundCapable: backgroundCapable)
        guard checkpoint?.tools.contains(where: { $0.callID == tool.callID }) == false else { throw AppError.stopped }
        activeToolBackgroundCapable = backgroundCapable
        checkpoint?.tools.append(tool)
        try persistOrPause()
    }
    func dispatch(callID: String, generation: UUID, backgroundCapable: Bool) throws {
        try requireExecution(generation: generation, backgroundCapable: backgroundCapable)
        guard let index = checkpoint?.tools.firstIndex(where: { $0.callID == callID }), checkpoint?.tools[index].delivery == .prepared else { throw AppError.stopped }
        checkpoint?.tools[index].delivery = .dispatching
        try persistOrPause() // Must succeed before the bridge is called.
    }
    func acknowledge(callID: String, generation: UUID, observation: Bool = false) throws {
        try requireExecution(generation: generation, backgroundCapable: activeToolBackgroundCapable)
        guard let index = checkpoint?.tools.firstIndex(where: { $0.callID == callID }), checkpoint?.tools[index].delivery == .dispatching else { throw AppError.stopped }
        checkpoint?.tools[index].delivery = observation ? .observedResult : .acknowledged
        if observation, let tools = checkpoint?.tools {
            // ObservedResult means a fresh screen was obtained after delivery,
            // not that the intended UI effect has been verified as successful.
            for i in tools.indices where tools[i].delivery == .acknowledged { checkpoint?.tools[i].delivery = .observedResult }
        }
        checkpoint?.lastConfirmedStep = callID; activeToolBackgroundCapable = true
        try persistOrPause()
        activity(generation: generation, milestone: "tool:" + callID)
    }
    func toolFailed(callID: String, generation: UUID) {
        guard ownsRun, checkpoint?.generation == generation,
              let i = checkpoint?.tools.firstIndex(where: { $0.callID == callID }) else { return }
        let wasWaiting = checkpoint?.phase == .waitingApproval && checkpoint?.pendingApproval == callID
        guard checkpoint?.phase == .running || wasWaiting else { return }
        let delivery = checkpoint?.tools[i].delivery
        if delivery == .dispatching {
            checkpoint?.tools[i].delivery = ["tap", "drag", "home", "launch_app", "type_text"].contains(checkpoint?.tools[i].name ?? "")
                ? .outcomeUnknown : .failed
        } else if delivery == .prepared {
            checkpoint?.tools[i].delivery = .failed
        }
        // Unknown delivery belongs to this call, not the Agent's entire run.
        // Persist it for recovery/no replay, then let the model observe/react.
        if wasWaiting { checkpoint?.pendingApproval = nil; checkpoint?.phase = .running }
        activeToolBackgroundCapable = true
        saveOrPause()
        if wasWaiting, checkpoint?.phase == .running { backgroundStatus = String(localized: "Permission was not granted. Keep the app open to continue.") }
    }
    func waitForApproval(callID: String, generation: UUID) throws {
        guard ownsRun, checkpoint?.generation == generation, checkpoint?.phase == .running,
              checkpoint?.tools.contains(where: { $0.callID == callID && $0.delivery == .prepared }) == true else { throw AppError.stopped }
        checkpoint?.pendingApproval = callID; checkpoint?.phase = .waitingApproval
        try persistOrPause()
        endSegment(success: true)
        backgroundStatus = String(localized: "Waiting for confirmation in the app. Execution is paused and no input will be sent.")
    }
    func resumeApproved(callID: String, digest: String, generation: UUID) throws {
        guard ownsRun, foreground, checkpoint?.generation == generation, checkpoint?.phase == .waitingApproval,
              checkpoint?.pendingApproval == callID,
              checkpoint?.tools.contains(where: { $0.callID == callID && $0.argumentDigest == digest && $0.delivery == .prepared }) == true else { throw AppError.stopped }
        checkpoint?.pendingApproval = nil; checkpoint?.phase = .running
        try persistOrPause(); lastActivity = now(); requestSegment()
    }
    func activity(generation: UUID, milestone: String? = nil) {
        guard ownsRun, checkpoint?.generation == generation, checkpoint?.phase == .running else { return }
        if let milestone, checkpoint?.milestones.contains(milestone) == true { return }
        lastActivity = now()
        if let milestone, checkpoint?.milestones.insert(milestone).inserted == true {
            saveOrPause()
            lease?.report(completed: checkpoint?.milestones.count ?? 0, subtitle: String(localized: "Received \(checkpoint?.milestones.count ?? 0) responses or tool results. The total number of steps is unknown."))
        }
    }
    func checkInactivity() {
        guard let inactivityTimeout, checkpoint?.phase == .running, now().timeIntervalSince(lastActivity) >= inactivityTimeout else { return }
        pause(String(localized: "No response for \(Int(inactivityTimeout)) seconds. Check your network, then continue manually."))
    }
    func pause(generation: UUID, message: String) {
        guard ownsRun, checkpoint?.generation == generation else { return }
        pause(message)
    }
    func pause(_ message: String) {
        BackgroundExecutionTrace.record("run.pause background=\(!foreground) hasLease=\(hasLease)")
        guard checkpoint?.phase == .running || checkpoint?.phase == .waitingApproval else { return }
        terminate(phase: .paused, message: message, success: false, cancelExecution: true)
    }
    func stop(message: String) {
        guard checkpoint?.phase == .running || checkpoint?.phase == .waitingApproval else { return }
        terminate(phase: .stopped, message: message, success: false)
    }
    func finish(success: Bool) {
        guard checkpoint?.phase == .running else { return }
        terminate(phase: success ? .completed : .paused, message: success ? String(localized: "Run finished") : String(localized: "Run interrupted. Check the result before continuing."), success: success)
    }
    private func terminate(phase: RunCheckpoint.Phase, message: String, success: Bool, cancelExecution: Bool = false) {
        if let tools = checkpoint?.tools {
            for i in tools.indices where tools[i].delivery == .dispatching { checkpoint?.tools[i].delivery = .outcomeUnknown }
        }
        checkpoint?.phase = phase; checkpoint?.message = message
        watchdog?.cancel(); watchdog = nil
        backgroundStatus = message
        try? persist()
        endSegment(success: success)
        scheduler.endRun()
        if cancelExecution { onPause?(message) }
        ownsRun = false
    }
    private func endSegment(success: Bool) {
        let old = lease; lease = nil; hasLease = false
        old?.expirationHandler = nil; old?.complete(success: success)
        if let id = checkpoint?.segmentID { scheduler.cancel(identifier: id) }
        checkpoint?.segmentID = nil
        try? persist()
    }
    private func persist() throws {
        guard storageHealthy, let checkpoint else { throw AppError.unavailable(String(localized: "Saved progress unavailable")) }
        do { try storage.save(checkpoint) }
        catch { storageHealthy = false; throw AppError.unavailable(String(localized: "Progress could not be saved. Execution was stopped to prevent further actions with unknown results.")) }
    }
    private func persistOrPause() throws {
        do { try persist() } catch { pause(String(localized: "Progress could not be saved. The task was paused and no further actions will be sent.")); throw error }
    }
    private func saveOrPause() { do { try persistOrPause() } catch {} }
}

// Recovery is evidence only. It can never restore a lease or an approval.
extension RunCheckpoint {
    var recoveryKey: String { "\(conversationID)/\(runID)/\(generation)" }
    func recovered() -> RunCheckpoint {
        var saved = self
        for i in saved.tools.indices where saved.tools[i].delivery == .dispatching {
            saved.tools[i].delivery = .outcomeUnknown
        }
        if saved.phase == .running { saved.phase = .paused }
        saved.segmentID = nil; saved.pendingApproval = nil
        if saved.tools.contains(where: { $0.delivery == .outcomeUnknown }) {
            saved.message = String(localized: "A previous action has an unknown result. Check your device first. The action will not be repeated.")
        } else if saved.phase == .waitingApproval {
            saved.message = String(localized: "The previous run was interrupted and its approvals have expired.")
        } else if saved.phase == .paused {
            saved.message = String(localized: "The previous run was interrupted. Sent actions will not be repeated automatically.")
        } else { saved.message = "" }
        return saved
    }
    static func mergedRecoveries(_ values: [RunCheckpoint]) -> [RunCheckpoint] {
        var merged: [RunCheckpoint] = []
        for value in values {
            guard let index = merged.firstIndex(where: { $0.recoveryKey == value.recoveryKey }) else {
                merged.append(value); continue
            }
            for tool in value.tools {
                if let i = merged[index].tools.firstIndex(where: { $0.callID == tool.callID && $0.argumentDigest == tool.argumentDigest }) {
                    // Any unresolved dispatch in either journal remains unknown.
                    if [.dispatching, .outcomeUnknown].contains(tool.delivery) {
                        merged[index].tools[i].delivery = .outcomeUnknown
                    }
                } else { merged[index].tools.append(tool) }
            }
            if [.running, .paused, .waitingApproval].contains(value.phase),
               [.completed, .stopped].contains(merged[index].phase) { merged[index].phase = .paused }
        }
        return merged
    }
}
