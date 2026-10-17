// Ported safety/transaction regression tests from 2509d7098fc8a3af4c62bd8fc20e911df4aa4933.
import XCTest
import AVFoundation
import ProviderCore
@testable import PhoneAgent

@MainActor private final class FakeTaskAudioPlayback: TaskAudioPlayback {
    var onStopped: (() -> Void)?
    var canPlay = true
    var starts = 0
    var stops = 0
    var holdStart = false
    var pendingStarts: [CheckedContinuation<Bool, Never>] = []
    func start() async throws -> Bool {
        starts += 1
        if holdStart { return await withCheckedContinuation { pendingStarts.append($0) } }
        return canPlay
    }
    func stop() { stops += 1 }
    func interrupt() { onStopped?() }
}
@MainActor private final class FakeLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    var requiresRunPause = false
    private(set) var completions: [Bool] = []
    private(set) var reports: [Int] = []
    private(set) var subtitles: [String] = []
    // The protocol's concrete lease adapter also gates duplicate completion.
    func complete(success: Bool) { if completions.isEmpty { completions.append(success) } }
    func report(completed: Int, subtitle: String) { reports.append(completed); subtitles.append(subtitle) }
}
@MainActor private final class FakeScheduler: RunBackgroundScheduler {
    var reject = false
    var failures: [String: @MainActor () -> Void] = [:]
    var launches: [String: @MainActor (any RunBackgroundLease) -> Void] = [:]
    var identifiers: [String] = []
    var cancellations: [String] = []
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        identifiers.append(identifier); launches[identifier] = launched
        if reject { throw AppError.unavailable("rejected") }
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws {
        failures[identifier] = failed
        try submit(identifier: identifier, launched: launched)
    }
    func cancel(identifier: String) { cancellations.append(identifier) }
    func grant(_ lease: FakeLease = FakeLease()) -> FakeLease {
        launches[identifiers.last!]?(lease); return lease
    }
}
@MainActor private final class FailingJournal: RunCheckpointStorage {
    var checkpoint: RunCheckpoint?
    var fail = false
    func load() throws -> RunCheckpoint? { checkpoint }
    func save(_ checkpoint: RunCheckpoint) throws {
        if fail { throw AppError.unavailable("disk") }
        self.checkpoint = checkpoint
    }
}
@MainActor final class RunLifecycleTests: XCTestCase {
    private let identity = RunIdentity(conversationID: UUID(), runID: UUID())
    private let token = UUID()
    private func tool(_ id: String = "tap") -> RunCheckpoint.Tool {
        .init(callID: id, name: "tap", parameterSummary: "{\"x\":1,\"y\":2}", argumentDigest: "digest")
    }
    private func settlePlayback() async {
        for _ in 0..<20 { await Task.yield() }
    }
    func testAmbiguousContinuedCancellationPausesEvenWithOtherSourceInForeground() throws {
        for foreground in [true, false] {
            let registry = BackgroundExecutionRegistry(), primary = FakeScheduler(), owner = UUID()
            registry.update(owner: owner, active: true, mechanism: .location)
            let scheduler = CompositeRunScheduler(primary: primary, registry: registry, allowed: { [.systemTask, .location] })
            let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
            try lifecycle.begin(identity: identity, generation: token)
            let grant = primary.grant(); grant.requiresRunPause = true
            lifecycle.setForeground(foreground)
            var pauses = 0; lifecycle.onPause = { _ in pauses += 1 }
            grant.expirationHandler?()
            XCTAssertEqual(lifecycle.checkpoint?.phase, .paused); XCTAssertEqual(pauses, 1)
            XCTAssertTrue(registry.active, "another run/resident owns its own source")
            XCTAssertEqual(primary.identifiers.count, 1)
        }
    }
    func testForegroundExpiryDoesNotRenewAndBackgroundRejectionUsesOnlyOwnMask() throws {
        let primary = FakeScheduler(), lifecycle = RunLifecycleCoordinator(scheduler: FakeScheduler(), storage: MemoryRunCheckpointStore())
        let direct = RunLifecycleCoordinator(scheduler: primary, storage: MemoryRunCheckpointStore())
        try direct.begin(identity: identity, generation: token)
        primary.grant().expirationHandler?()
        XCTAssertEqual(primary.identifiers.count, 1); XCTAssertEqual(direct.checkpoint?.phase, .running)
        direct.setForeground(false); XCTAssertEqual(direct.checkpoint?.phase, .paused)
        _ = lifecycle
    }
    func testSystemGrantIsPerRunAndSuccessfulCompletionIsReportedOnce() throws {
        let registry = BackgroundExecutionRegistry(), system = FakeScheduler()
        let scheduler = CompositeRunScheduler(primary: system, registry: registry, allowed: { [.systemTask] })
        var a: (any RunBackgroundLease)?, b: (any RunBackgroundLease)?
        try scheduler.submit(identifier: "a", launched: { a = $0 })
        try scheduler.submit(identifier: "b", launched: { b = $0 })
        let grant = system.grant()
        XCTAssertFalse(a?.backgroundReady ?? true); XCTAssertTrue(b?.backgroundReady ?? false)
        scheduler.cancel(identifier: "a"); XCTAssertTrue(b?.backgroundReady ?? false)
        b?.complete(success: true); scheduler.cancel(identifier: "b")
        XCTAssertEqual(grant.completions, [true])
    }
    func testSceneChangesDoNotResetHandoffDeadline() async throws {
        let scheduler = CompositeRunScheduler(registry: BackgroundExecutionRegistry(), allowed: { [.location] }, handoffSeconds: 0.03)
        var lease: (any RunBackgroundLease)?; var expirations = 0
        try scheduler.submit(identifier: "bounded", launched: { lease = $0 })
        lease?.expirationHandler = { expirations += 1 }
        scheduler.setForeground(false); scheduler.setForeground(true)
        try await Task.sleep(for: .milliseconds(50))
        scheduler.setForeground(false)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(expirations, 1); XCTAssertFalse(lease?.backgroundReady ?? true)
        scheduler.setForeground(true); scheduler.setForeground(false)
        XCTAssertEqual(expirations, 1)
    }
    func testAllSixteenCombinationsRequestOnlySelectedSystemAndDoNotBorrowOtherSources() throws {
        for mask in 0..<16 {
            let registry = BackgroundExecutionRegistry(), system = FakeScheduler()
            let selection = Set(BackgroundMechanism.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            for mechanism in BackgroundMechanism.continuous { registry.publish(.init(mechanism: mechanism, owner: UUID())) }
            let scheduler = CompositeRunScheduler(primary: system, registry: registry, allowed: { selection })
            var lease: (any RunBackgroundLease)?
            try scheduler.submit(identifier: "combination", launched: { lease = $0 })
            XCTAssertEqual(system.identifiers.count, selection.contains(.systemTask) ? 1 : 0)
            XCTAssertEqual(lease?.backgroundReady, !selection.intersection(BackgroundMechanism.continuous).isEmpty)
            if selection.contains(.systemTask) { _ = system.grant(); XCTAssertTrue(lease?.backgroundReady == true) }
            scheduler.cancel(identifier: "combination"); XCTAssertFalse(lease?.backgroundReady ?? true)
        }
    }
    func testExplicitBackgroundStartRequiresLeaseBeforeDispatch() throws {
        let scheduler = FakeScheduler()
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        lifecycle.setForeground(false)
        XCTAssertThrowsError(try lifecycle.begin(identity: identity, generation: token))
        try lifecycle.begin(identity: identity, generation: token, allowBackgroundStart: true)
        XCTAssertEqual(scheduler.identifiers.count, 1)
        XCTAssertFalse(lifecycle.hasLease)
        let lease = scheduler.grant()
        try lifecycle.requireExecution(generation: token, backgroundCapable: true)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: token, backgroundCapable: false))
        lease.expirationHandler?()
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: token, backgroundCapable: true))
    }
    func testResidentPlaybackKeepsIdleAppAndNewBackgroundRunUntilDisabled() async throws {
        let activity = BackgroundExecutionRegistry(), audio = FakeTaskAudioPlayback()
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        XCTAssertFalse(media.backgroundResident)
        XCTAssertFalse(media.policy.running)
        media.setBackgroundResident(true)
        await settlePlayback()
        XCTAssertTrue(media.audioActive)
        XCTAssertTrue(activity.active)
        media.setForeground(false)
        let lifecycle = RunLifecycleCoordinator(scheduler: CompositeRunScheduler(registry: activity, allowed: { [.audio] }), storage: MemoryRunCheckpointStore())
        lifecycle.setForeground(false)
        try lifecycle.begin(identity: identity, generation: token, allowBackgroundStart: true)
        try lifecycle.requireExecution(generation: token, backgroundCapable: true)
        media.setTaskRunning(true)
        media.setTaskRunning(false)
        XCTAssertEqual(audio.starts, 1)
        XCTAssertTrue(activity.active, "finishing a task must retain idle residency")
        media.setBackgroundResident(false)
        XCTAssertFalse(media.audioActive)
        XCTAssertFalse(activity.active)
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
    }
    func testSystemTaskOnlyNeverSynthesizesAudioForResidency() async {
        let activity = BackgroundExecutionRegistry(), audio = FakeTaskAudioPlayback()
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        media.setBackgroundMode(.systemTask)
        media.setTaskRunning(true)
        await settlePlayback()
        XCTAssertEqual(audio.starts, 0)
        XCTAssertFalse(activity.active)
        XCTAssertFalse(media.previewEnabled)
        media.setBackgroundResident(true)
        await settlePlayback()
        XCTAssertEqual(audio.starts, 0)
        XCTAssertFalse(activity.active)
        media.setTaskRunning(false)
        XCTAssertFalse(activity.active, "system-only is not an idle source")
        media.setBackgroundResident(false)
        XCTAssertFalse(activity.active)
        XCTAssertFalse(media.audioActive)
    }
    func testSystemTaskGrantAndExpirationWorkWithoutMediaPlayback() throws {
        let activity = BackgroundExecutionRegistry(), system = FakeScheduler()
        let scheduler = RunExecutionScheduler(continued: system, coordinator: testCoordinator(registry: activity))
        scheduler.configure(context: nil, allowSystemProcessing: true,
                            selection: [.systemTask])
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try lifecycle.begin(identity: identity, generation: token)
        XCTAssertTrue(lifecycle.hasLease, "pending aggregate is bounded and not background-ready")
        let grant = system.grant()
        lifecycle.setForeground(false)
        try lifecycle.requireExecution(generation: token, backgroundCapable: true)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: token, backgroundCapable: false))
        grant.expirationHandler?()
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: token, backgroundCapable: true))
    }
    func testDisablingResidencyPreservesRunningTaskAndReleasesAfterTaskEnds() async {
        let activity = BackgroundExecutionRegistry(), audio = FakeTaskAudioPlayback()
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        media.setBackgroundResident(true)
        await settlePlayback()
        media.setTaskRunning(true)
        media.setBackgroundResident(false)
        XCTAssertTrue(activity.active)
        XCTAssertTrue(media.policy.running)
        XCTAssertEqual(audio.starts, 1)
        media.setTaskRunning(false)
        XCTAssertFalse(activity.active)
        XCTAssertFalse(media.policy.running)
    }
    func testPendingResidentActivationCannotReviveDisabledResidency() async {
        let activity = BackgroundExecutionRegistry(), audio = FakeTaskAudioPlayback()
        audio.holdStart = true
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        media.setBackgroundResident(true)
        await settlePlayback()
        XCTAssertEqual(audio.pendingStarts.count, 1)
        XCTAssertFalse(activity.active)
        media.setBackgroundResident(false)
        audio.pendingStarts.removeFirst().resume(returning: true)
        await settlePlayback()
        XCTAssertFalse(media.audioActive)
        XCTAssertFalse(activity.active)
    }
    func testStopBeforeAudioStartIsScheduledNeverActivatesPlayback() async {
        let activity = BackgroundExecutionRegistry(), audio = FakeTaskAudioPlayback()
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        media.setBackgroundMode(.audio)
        media.setTaskRunning(true)
        media.setTaskRunning(false)
        await settlePlayback()
        XCTAssertEqual(audio.starts, 0)
        XCTAssertFalse(media.audioActive)
        XCTAssertFalse(activity.active)
    }
    func testDelayedAudioActivationCannotReviveStoppedOrNewerTask() async {
        let activity = BackgroundExecutionRegistry(), audio = FakeTaskAudioPlayback()
        audio.holdStart = true
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        media.setBackgroundMode(.audio)
        media.setTaskRunning(true); await settlePlayback()
        XCTAssertEqual(audio.pendingStarts.count, 1)
        XCTAssertFalse(activity.active, "pending activation grants no background execution")
        media.setTaskRunning(false)
        media.setTaskRunning(true); await settlePlayback()
        XCTAssertEqual(audio.pendingStarts.count, 2)
        audio.pendingStarts.removeFirst().resume(returning: true)
        await settlePlayback()
        XCTAssertFalse(activity.active, "old activation must not grant the new generation")
        audio.pendingStarts.removeFirst().resume(returning: true)
        await settlePlayback()
        XCTAssertTrue(activity.active)
        media.setTaskRunning(false)
        XCTAssertFalse(activity.active)
    }
    func testAudioPlaybackKeepsRunAfterSystemExpiryAndInterruptionRevokesIt() async throws {
        let activity = BackgroundExecutionRegistry(), primary = FakeScheduler(), audio = FakeTaskAudioPlayback()
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        media.setBackgroundMode(.audio)
        XCTAssertFalse(activity.active)
        media.setTaskRunning(true); await settlePlayback()
        XCTAssertTrue(media.audioActive); XCTAssertFalse(media.previewEnabled)
        XCTAssertTrue(activity.active)
        let lifecycle = RunLifecycleCoordinator(scheduler: CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) }), storage: MemoryRunCheckpointStore())
        try lifecycle.begin(identity: identity, generation: token)
        let system = primary.grant()
        lifecycle.setForeground(false); media.setForeground(false)
        system.expirationHandler?()
        XCTAssertTrue(lifecycle.hasLease)
        try lifecycle.requireExecution(generation: token, backgroundCapable: true)
        audio.interrupt()
        XCTAssertFalse(media.audioActive); XCTAssertFalse(activity.active)
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
        media.setForeground(true); media.setForeground(false)
        XCTAssertEqual(audio.starts, 1, "interruption must not automatically resume playback/run")
        media.setTaskRunning(false)
    }
    func testFailedAudioDoesNotGrantExecutionAndSelectionAppliesNextTask() async throws {
        let activity = BackgroundExecutionRegistry(), audio = FakeTaskAudioPlayback()
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        media.setBackgroundMode(.audio); audio.canPlay = false
        media.setTaskRunning(true); await settlePlayback()
        XCTAssertFalse(activity.active); XCTAssertFalse(media.audioActive)
        media.setBackgroundMode(.pictureInPicture)
        XCTAssertTrue(media.allowed.isEmpty, "deselection immediately vetoes this run; additions wait")
        media.setForeground(false); media.setForeground(true)
        XCTAssertEqual(audio.starts, 1)
        media.setTaskRunning(false)
        XCTAssertGreaterThan(audio.stops, 0)
        media.setBackgroundMode(.audio); audio.canPlay = true
        media.setTaskRunning(true); await settlePlayback()
        XCTAssertTrue(activity.active); XCTAssertEqual(audio.starts, 2)
        media.setTaskRunning(false)
        XCTAssertFalse(activity.active); XCTAssertFalse(media.audioActive)
        media.setForeground(false); media.setForeground(true)
        XCTAssertEqual(audio.starts, 2, "explicit stop must not restart on scene changes")
        media.setTaskRunning(false)
        XCTAssertFalse(activity.active)
    }
    func testAudioOwnerSupportsMultipleRunsAndLatePlaybackCannotReviveStoppedRun() async throws {
        let activity = BackgroundExecutionRegistry(), primary = FakeScheduler(), audio = FakeTaskAudioPlayback()
        let media = TestBackgroundMedia(registry: activity, audio: audio)
        media.setBackgroundMode(.audio); media.setTaskRunning(true); await settlePlayback()
        let scheduler = CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) })
        var first: (any RunBackgroundLease)?, second: (any RunBackgroundLease)?
        try scheduler.submit(identifier: "audio-one", launched: { first = $0 })
        try scheduler.submit(identifier: "audio-two", launched: { second = $0 })
        var firstExpired = 0, secondExpired = 0
        first?.expirationHandler = { firstExpired += 1 }
        second?.expirationHandler = { secondExpired += 1 }
        scheduler.cancel(identifier: "audio-one")
        XCTAssertTrue(activity.active)
        XCTAssertEqual(firstExpired, 0); XCTAssertEqual(secondExpired, 0)
        scheduler.setForeground(false)
        media.setTaskRunning(false)
        XCTAssertFalse(activity.active)
        XCTAssertEqual(firstExpired, 0); XCTAssertEqual(secondExpired, 1)
        // A new task/playback generation cannot revive either old lease.
        media.setTaskRunning(true); await settlePlayback(); audio.interrupt()
        XCTAssertEqual(firstExpired, 0); XCTAssertEqual(secondExpired, 1)
        media.setTaskRunning(false)
        scheduler.cancel(identifier: "audio-two")

    }
    func testSilentPCMIsDecodableOneSecondMonoAudio() throws {
        let data = SilentTaskAudioPlayback.silentPCM()
        let player = try AVAudioPlayer(data: data)
        XCTAssertEqual(player.numberOfChannels, 1)
        XCTAssertEqual(player.duration, 1, accuracy: 0.01)
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 })
    }
    func testReturningToForegroundBeforePiPStopsPreservesTaskWithoutRenewingSystemRequest() throws {
        let activity = BackgroundExecutionRegistry(), owner = UUID(), primary = FakeScheduler()
        activity.update(owner: owner, active: true)
        let lifecycle = RunLifecycleCoordinator(scheduler: CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) }), storage: MemoryRunCheckpointStore())
        try lifecycle.begin(identity: identity, generation: token)
        lifecycle.setForeground(false)
        lifecycle.setForeground(true)
        activity.update(owner: owner, active: false)
        XCTAssertEqual(lifecycle.checkpoint?.phase, .running)
        XCTAssertEqual(primary.identifiers.count, 1)
        try lifecycle.requireExecution(generation: token, backgroundCapable: true)
        lifecycle.stop(message: "cleanup")
    }
    func testMediaPauseOrSuspensionDoesNotRevokeActualPiPExecutionReceipt() throws {
        let activity = BackgroundExecutionRegistry(), owner = UUID(), primary = FakeScheduler()
        let pip = StatusPiPController(registry: activity)
        let lifecycle = RunLifecycleCoordinator(scheduler: CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) }), storage: MemoryRunCheckpointStore())
        activity.update(owner: owner, active: true)
        try lifecycle.begin(identity: identity, generation: token)
        lifecycle.setForeground(false)
        pip.setSystemPlayback(false, suspended: true)
        pip.setSystemPlayback(false, suspended: false)
        XCTAssertTrue(activity.active)
        XCTAssertTrue(lifecycle.hasLease)
        try lifecycle.requireExecution(generation: token, backgroundCapable: true)
        activity.update(owner: owner, active: false)
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
    }
    func testTaskPiPOnlyStartsInBackgroundAndHonorsDismissalUntilReturn() {
        var policy = TaskPiPPolicy()
        policy.setForeground(false)
        XCTAssertFalse(policy.shouldStart)
        policy.setForeground(true); policy.setRunning(true)
        XCTAssertFalse(policy.shouldStart)
        policy.setForeground(false)
        XCTAssertTrue(policy.shouldStart)
        policy.dismissed = true
        XCTAssertFalse(policy.shouldStart)
        policy.setRunning(true)
        XCTAssertFalse(policy.shouldStart)
        policy.setForeground(true); policy.setForeground(false)
        XCTAssertTrue(policy.shouldStart)
        policy.setRunning(false)
        XCTAssertFalse(policy.shouldStart)
    }
    func testSystemExpirationKeepsBackgroundRunWhilePiPIsActive() throws {
        let activity = BackgroundExecutionRegistry(), owner = UUID(), primary = FakeScheduler()
        activity.update(owner: owner, active: true)
        let scheduler = CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) })
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try lifecycle.begin(identity: identity, generation: token)
        let grant = primary.grant()
        lifecycle.setForeground(false)
        grant.expirationHandler?()
        XCTAssertTrue(lifecycle.hasLease)
        XCTAssertEqual(lifecycle.checkpoint?.phase, .running)
        try lifecycle.requireExecution(generation: token, backgroundCapable: true)
        activity.update(owner: owner, active: false)
        XCTAssertFalse(lifecycle.hasLease)
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
        lifecycle.stop(message: "cleanup")
    }
    func testPiPClosingKeepsRunUntilSystemSourceAlsoExpires() throws {
        let activity = BackgroundExecutionRegistry(), owner = UUID(), primary = FakeScheduler()
        activity.update(owner: owner, active: true)
        let lifecycle = RunLifecycleCoordinator(scheduler: CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) }), storage: MemoryRunCheckpointStore())
        try lifecycle.begin(identity: identity, generation: token)
        let grant = primary.grant()
        lifecycle.setForeground(false)
        activity.update(owner: owner, active: false)
        XCTAssertTrue(lifecycle.hasLease)
        try lifecycle.requireExecution(generation: token, backgroundCapable: true)
        grant.expirationHandler?()
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
    }
    func testRejectedSystemRequestCanUseActualPiPButNotInlinePreview() throws {
        let primary = FakeScheduler(); primary.reject = true
        let activity = BackgroundExecutionRegistry(), owner = UUID()
        let scheduler = CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) })
        var deliveries = 0
        var pending: (any RunBackgroundLease)?
        try scheduler.submit(identifier: "preview", launched: { pending = $0 })
        XCTAssertFalse(pending?.backgroundReady ?? true)
        scheduler.cancel(identifier: "preview")
        XCTAssertEqual(deliveries, 0)
        activity.update(owner: owner, active: true)
        try scheduler.submit(identifier: "active", launched: { _ in deliveries += 1 })
        XCTAssertEqual(deliveries, 1)
        scheduler.cancel(identifier: "active")
        activity.update(owner: owner, active: false)
    }
    func testStoppingOneRunDoesNotRevokeOtherPiPBackedRun() throws {
        let activity = BackgroundExecutionRegistry(), owner = UUID(), primary = FakeScheduler()
        activity.update(owner: owner, active: true)
        let scheduler = CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) })
        var a: (any RunBackgroundLease)?, b: (any RunBackgroundLease)?
        try scheduler.submit(identifier: "a", launched: { a = $0 })
        try scheduler.submit(identifier: "b", launched: { b = $0 })
        var aExpired = 0, bExpired = 0
        a?.expirationHandler = { aExpired += 1 }; b?.expirationHandler = { bExpired += 1 }
        scheduler.cancel(identifier: "a")
        XCTAssertTrue(activity.active)
        scheduler.setForeground(false)
        activity.update(owner: owner, active: false)
        XCTAssertEqual(aExpired, 0); XCTAssertEqual(bExpired, 1)
        scheduler.cancel(identifier: "b")
    }
    func testLateGrantOrPiPRestartNeverRevivesStoppedRun() throws {
        let activity = BackgroundExecutionRegistry(), owner = UUID(), primary = FakeScheduler()
        activity.update(owner: owner, active: true)
        let scheduler = CompositeRunScheduler(primary: primary, registry: activity, allowed: { Set(BackgroundMechanism.allCases) })
        var deliveries = 0
        try scheduler.submit(identifier: "stopped", launched: { _ in deliveries += 1 })
        scheduler.cancel(identifier: "stopped")
        let late = primary.grant()
        XCTAssertEqual(late.completions, [false])
        activity.update(owner: owner, active: false)
        activity.update(owner: owner, active: true)
        XCTAssertEqual(deliveries, 1)
        activity.update(owner: owner, active: false)
    }
    func testAsynchronousSubmissionFailureAndOldCallbackCannotAffectNewRun() throws {
        let scheduler = FakeScheduler()
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try lifecycle.begin(identity: identity, generation: token)
        let old = scheduler.identifiers[0]
        scheduler.failures[old]?()
        XCTAssertFalse(lifecycle.hasLease)
        XCTAssertTrue(lifecycle.backgroundStatus.contains("仅前台"))
        XCTAssertTrue(scheduler.cancellations.contains(old))
        lifecycle.stop(message: "stop")
        let next = UUID()
        try lifecycle.begin(identity: identity, generation: next)
        let granted = scheduler.grant()
        scheduler.failures[old]?()
        lifecycle.setForeground(false)
        XCTAssertTrue(lifecycle.hasLease)
        XCTAssertEqual(lifecycle.checkpoint?.generation, next)
        XCTAssertTrue(granted.completions.isEmpty)
        lifecycle.stop(message: "cleanup")
    }
    func testDefaultMediaModesDoNotSubmitSystemRequests() throws {
        for mode in BackgroundMechanism.allCases where mode != .systemTask {
            let activity = BackgroundExecutionRegistry(), owner = UUID(), system = FakeScheduler()
            let scheduler = RunExecutionScheduler(continued: system, coordinator: testCoordinator(registry: activity))
            scheduler.configure(context: nil, allowSystemProcessing: true, selection: [mode])
            let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
            try lifecycle.begin(identity: identity, generation: token)
            XCTAssertTrue(lifecycle.hasLease)
            XCTAssertTrue(system.identifiers.isEmpty, mode.rawValue)
            activity.update(owner: owner, active: true, mechanism: mode)
            lifecycle.setForeground(false)
            try lifecycle.requireExecution(generation: token, backgroundCapable: true)
            activity.update(owner: owner, active: false, mechanism: mode)
            XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
            XCTAssertTrue(system.identifiers.isEmpty)
        }
    }
    func testMediaHandoffWaitsForActualPlaybackAndNeverReplaysAfterStop() async throws {
        let activity = BackgroundExecutionRegistry(), owner = UUID()
        let scheduler = CompositeRunScheduler(registry: activity, allowed: { [.audio] }, handoffSeconds: 0.3)
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try lifecycle.begin(identity: identity, generation: token)
        lifecycle.setForeground(false)
        var dispatched = false
        let waiter = Task { @MainActor in
            try await lifecycle.awaitExecution(generation: token, backgroundCapable: true)
            dispatched = true
        }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(dispatched)
        activity.update(owner: owner, active: true)
        try await waiter.value
        XCTAssertTrue(dispatched)
        lifecycle.stop(message: "stop")
        activity.update(owner: owner, active: false); activity.update(owner: owner, active: true)
        XCTAssertFalse(lifecycle.hasLease)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: token, backgroundCapable: true))
    }
    func testMediaStartTimeoutPausesWithoutGrantingToolExecution() async throws {
        let scheduler = CompositeRunScheduler(registry: BackgroundExecutionRegistry(), allowed: { [.audio] }, handoffSeconds: 0.04)
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try lifecycle.begin(identity: identity, generation: token)
        lifecycle.setForeground(false)
        do { try await lifecycle.awaitExecution(generation: token, backgroundCapable: true); XCTFail("no media") } catch {}
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused)
    }
    func testExecutionSourceIsExclusiveAndCancellationUsesOriginalOwner() throws {
        let continued = FakeScheduler(), scheduler = RunExecutionScheduler(continued: FakeScheduler())
        let routed = RunExecutionScheduler(continued: continued, coordinator: testCoordinator(registry: BackgroundExecutionRegistry()))
        routed.configure(context: nil, allowSystemProcessing: true,
                         selection: [.systemTask])
        try routed.submit(identifier: "system", launched: { _ in })
        XCTAssertEqual(continued.identifiers, ["system"])
        routed.configure(context: nil, allowSystemProcessing: false)
        XCTAssertThrowsError(try routed.submit(identifier: "foreground", launched: { _ in }))
        routed.cancel(identifier: "system")
        XCTAssertEqual(continued.cancellations, ["system"])
        XCTAssertThrowsError(try scheduler.submit(identifier: "default", launched: { _ in }))
    }
    func testColdRecoveryCancelsSystemRequestWithoutInMemoryOwner() throws {
        let store = MemoryRunCheckpointStore(), system = FakeScheduler()
        var saved = RunCheckpoint(runID: identity.runID, conversationID: identity.conversationID, generation: token)
        saved.segmentID = "test.phoneagent.backgroundRun.old-process"
        store.value = saved
        let scheduler = RunExecutionScheduler(continued: system)
        let restored = RunLifecycleCoordinator(scheduler: scheduler, storage: store, identifierPrefix: "test.phoneagent.backgroundRun")
        XCTAssertEqual(system.cancellations, [saved.segmentID!])
        XCTAssertTrue(system.identifiers.isEmpty)
        XCTAssertFalse(restored.hasLease)
        XCTAssertNil(restored.checkpoint?.segmentID)
        XCTAssertEqual(restored.checkpoint?.phase, .paused)
    }
    func testLegacyUSBCheckpointMigratesToCommonJournalWithoutResuming() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var old = RunCheckpoint(runID: identity.runID, conversationID: identity.conversationID, generation: token)
        var action = tool(); action.delivery = .dispatching; old.tools = [action]
        let legacy = directory.appendingPathComponent("usb-run-checkpoint-v1.json")
        let data = try JSONEncoder().encode(old); try data.write(to: legacy)
        let scheduler = FakeScheduler()
        let restored = RunLifecycleCoordinator(scheduler: scheduler, storage: try RunCheckpointStore(directory: directory))
        XCTAssertEqual(restored.checkpoint?.phase, .paused)
        XCTAssertEqual(restored.checkpoint?.tools[0].delivery, .outcomeUnknown)
        XCTAssertTrue(scheduler.identifiers.isEmpty); XCTAssertFalse(restored.hasLease)
        XCTAssertEqual(try Data(contentsOf: legacy), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run-checkpoint-v1.json").path))
    }
    func testSuccessfulSubmissionIsNotLeaseAndLateHandlerCannotResumePausedRun() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        XCTAssertFalse(c.hasLease)
        var pauses = 0; c.onPause = { _ in pauses += 1 }
        c.setForeground(false)
        let lease = scheduler.grant()
        XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertFalse(c.hasLease); XCTAssertEqual(pauses, 1)
        XCTAssertEqual(lease.completions, [false])
        XCTAssertTrue(scheduler.identifiers[0].contains(".backgroundRun."))
        XCTAssertFalse(scheduler.identifiers[0].contains("*"))
    }
    func testRejectedLeaseContinuesOnlyForeground() throws {
        let scheduler = FakeScheduler(); scheduler.reject = true
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token)
        try c.requireExecution(generation: token, backgroundCapable: true)
        XCTAssertTrue(c.backgroundStatus.contains("仅前台"))
        c.setForeground(false)
        XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertThrowsError(try c.requireExecution(generation: token, backgroundCapable: true))
    }
    func testLeaseAllowsBackgroundModelButNotUnverifiedTool() throws {
        let scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token)
        let lease = scheduler.grant(); c.setForeground(false)
        try c.requireExecution(generation: token, backgroundCapable: true)
        XCTAssertThrowsError(try c.prepare(tool(), generation: token, backgroundCapable: false))
        XCTAssertEqual(c.checkpoint?.tools.count, 0)
        XCTAssertEqual(lease.completions, [false])
    }
    func testActiveForegroundToolPausesEvenWithLease() throws {
        let scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token); _ = scheduler.grant()
        try c.prepare(tool(), generation: token, backgroundCapable: false)
        try c.dispatch(callID: "tap", generation: token, backgroundCapable: false)
        c.setForeground(false)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .outcomeUnknown)
    }
    func testNewRunDoesNotInheritPreviousForegroundOnlyTool() throws {
        let scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token); _ = scheduler.grant()
        try c.prepare(tool(), generation: token, backgroundCapable: false)
        c.stop(message: "stop")
        c.setForeground(true)
        let next = UUID(); try c.begin(identity: identity, generation: next); _ = scheduler.grant()
        c.setForeground(false)
        try c.requireExecution(generation: next, backgroundCapable: true)
        XCTAssertEqual(c.checkpoint?.phase, .running)
        c.stop(message: "cleanup")
    }
    func testExpirationStopAndDuplicateCallbacksCompleteOnceAndFenceNewRun() throws {
        let scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token)
        let oldID = scheduler.identifiers[0], lease = scheduler.grant()
        scheduler.launches[oldID]?(lease)
        let expire = lease.expirationHandler
        c.setForeground(false)
        var pauses = 0; c.onPause = { _ in pauses += 1 }
        expire?(); expire?(); c.stop(message: "stop"); c.finish(success: true)
        XCTAssertEqual(pauses, 1); XCTAssertEqual(lease.completions, [false])
        c.setForeground(true)
        let next = UUID(); try c.begin(identity: identity, generation: next)
        let fresh = scheduler.grant()
        expire?(); scheduler.launches[oldID]?(lease)
        c.activity(generation: token, milestone: "stale")
        c.pause(generation: token, message: "stale failure")
        XCTAssertTrue(c.hasLease); XCTAssertEqual(c.checkpoint?.generation, next)
        XCTAssertEqual(c.checkpoint?.milestones.count, 0); XCTAssertTrue(fresh.completions.isEmpty)
        c.stop(message: "cleanup"); XCTAssertEqual(fresh.completions, [false])
    }
    func testApprovalPersistsAndEndsSegmentThenExplicitApprovalStartsUniqueSegment() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token); let first = scheduler.grant()
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.waitForApproval(callID: "tap", generation: token)
        XCTAssertEqual(c.checkpoint?.phase, .waitingApproval)
        XCTAssertEqual(store.value?.pendingApproval, "tap"); XCTAssertEqual(first.completions, [true])
        c.setForeground(false); c.checkInactivity()
        XCTAssertThrowsError(try c.resumeApproved(callID: "tap", digest: "digest", generation: token))
        XCTAssertEqual(scheduler.identifiers.count, 1)
        c.setForeground(true)
        XCTAssertThrowsError(try c.resumeApproved(callID: "tap", digest: "changed", generation: token))
        try c.resumeApproved(callID: "tap", digest: "digest", generation: token)
        XCTAssertEqual(scheduler.identifiers.count, 2)
        XCTAssertEqual(Set(scheduler.identifiers).count, 2); XCTAssertFalse(c.hasLease)
        XCTAssertEqual(c.checkpoint?.segment, 2)
        c.stop(message: "cleanup")
    }
    func testTaskStatusSurvivesLateLeaseAndDoesNotAdvanceReceiptsOrReviveStoppedRun() throws {
        let scheduler = FakeScheduler()
        var clock = Date()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore(), inactivityTimeout: 10, now: { clock })
        try c.begin(identity: identity, generation: token)
        c.reportStatus("Viewing screen", generation: token)
        let lease = scheduler.grant()
        XCTAssertEqual(lease.subtitles, ["Viewing screen"])
        c.reportStatus("Tap sent", generation: token)
        c.reportStatus("Tap sent", generation: token)
        c.reportStatus("old run", generation: UUID())
        XCTAssertEqual(lease.subtitles, ["Viewing screen", "Tap sent"])
        XCTAssertEqual(lease.reports, [0, 0])
        XCTAssertTrue(c.checkpoint?.milestones.isEmpty == true)
        clock.addTimeInterval(11)
        c.reportStatus("Waiting for reply", generation: token)
        c.checkInactivity()
        XCTAssertEqual(c.checkpoint?.phase, .paused, "Presentation updates must not reset the inactivity timer")
        c.reportStatus("late event", generation: token)
        XCTAssertEqual(lease.subtitles.last, "Waiting for reply")
    }
    func testProgressFreezesWithoutRealReceiptsAndPausesOnConfigurableTimeout() throws {
        let scheduler = FakeScheduler(); var clock = Date()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore(), inactivityTimeout: 10, now: { clock })
        try c.begin(identity: identity, generation: token); let lease = scheduler.grant()
        c.activity(generation: token, milestone: "model:1")
        c.activity(generation: token, milestone: "model:1")
        c.activity(generation: token) // Actual text token: activity, not a completed unit.
        XCTAssertEqual(lease.reports, [0, 1])
        clock.addTimeInterval(11); c.checkInactivity()
        XCTAssertEqual(lease.reports, [0, 1]); XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertEqual(lease.completions, [false])
    }
    func testDispatchPersistedBeforeTransportAndDiskFailurePreventsSending() throws {
        let scheduler = FakeScheduler(), store = FailingJournal()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        XCTAssertEqual(store.checkpoint?.tools[0].delivery, .prepared)
        store.fail = true
        XCTAssertThrowsError(try c.dispatch(callID: "tap", generation: token, backgroundCapable: true))
        XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertEqual(store.checkpoint?.tools[0].delivery, .prepared)
    }
    func testDisconnectAndRecoveryNeverReplayUncertainInput() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.dispatch(callID: "tap", generation: token, backgroundCapable: true)
        XCTAssertEqual(store.value?.tools[0].delivery, .dispatching)
        // A fresh process has no lease. Persisted dispatching is ambiguous.
        let recovered = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        XCTAssertEqual(recovered.checkpoint?.tools[0].delivery, .outcomeUnknown)
        XCTAssertEqual(recovered.checkpoint?.phase, .paused)
        XCTAssertThrowsError(try recovered.dispatch(callID: "tap", generation: token, backgroundCapable: true))
        XCTAssertEqual(scheduler.identifiers.count, 1)
        c.toolFailed(callID: "tap", generation: token)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .outcomeUnknown)
        XCTAssertEqual(c.checkpoint?.phase, .running)
        XCTAssertThrowsError(try c.dispatch(callID: "tap", generation: token, backgroundCapable: true))
    }
    func testNewSystemActionsPersistUnknownOutcomeAndNeverResumeTheirDispatch() throws {
        for name in ["home", "launch_app", "type_text"] {
            let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
            let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
            try lifecycle.begin(identity: identity, generation: token)
            try lifecycle.prepare(.init(callID: name, name: name, parameterSummary: "{}", argumentDigest: "digest"), generation: token, backgroundCapable: true)
            try lifecycle.dispatch(callID: name, generation: token, backgroundCapable: true)
            lifecycle.toolFailed(callID: name, generation: token)
            XCTAssertEqual(lifecycle.checkpoint?.tools[0].delivery, .outcomeUnknown)
            XCTAssertEqual(lifecycle.checkpoint?.phase, .running)
            let recovered = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
            XCTAssertThrowsError(try recovered.dispatch(callID: name, generation: token, backgroundCapable: true))
        }
    }
    func testPreflightErrorAfterApprovalReturnsToRunningAndAllowsObservation() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        var paused = false
        c.onPause = { _ in paused = true }
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.waitForApproval(callID: "tap", generation: token)
        c.toolFailed(callID: "tap", generation: token)
        XCTAssertEqual(c.checkpoint?.phase, .running)
        XCTAssertNil(c.checkpoint?.pendingApproval)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .failed)
        XCTAssertFalse(paused)
        let observation = RunCheckpoint.Tool(callID: "new-screen", name: "screenshot", parameterSummary: "{}", argumentDigest: "screen")
        try c.prepare(observation, generation: token, backgroundCapable: true)
        try c.dispatch(callID: "new-screen", generation: token, backgroundCapable: true)
    }
    func testAcknowledgementIsNotVisualObservation() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.dispatch(callID: "tap", generation: token, backgroundCapable: true)
        try c.acknowledge(callID: "tap", generation: token)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .acknowledged)
        try c.prepare(tool("screen"), generation: token, backgroundCapable: true)
        try c.dispatch(callID: "screen", generation: token, backgroundCapable: true)
        try c.acknowledge(callID: "screen", generation: token, observation: true)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .observedResult)
        XCTAssertEqual(c.checkpoint?.lastConfirmedStep, "screen")
        c.finish(success: true)
    }
    func testFileCheckpointRoundTripPreservesApprovalWithoutExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RunCheckpointStore(directory: directory), scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.waitForApproval(callID: "tap", generation: token)
        let restored = RunLifecycleCoordinator(scheduler: scheduler, storage: try RunCheckpointStore(directory: directory))
        XCTAssertEqual(restored.checkpoint?.phase, .waitingApproval)
        XCTAssertNil(restored.checkpoint?.pendingApproval, "Old approval identity is evidence, never reusable authority")
        XCTAssertFalse(restored.hasLease); XCTAssertEqual(scheduler.identifiers.count, 1)
        XCTAssertThrowsError(try restored.resumeApproved(callID: "tap", digest: "digest", generation: token))
        try restored.begin(identity: RunIdentity(conversationID: identity.conversationID, runID: UUID()), generation: UUID())
        XCTAssertEqual(restored.checkpoint?.tools.count, 0)
        restored.stop(message: "cleanup")
        c.stop(message: "cleanup")
    }
}

private actor BackgroundSpyBridge: DeviceBridge {
    private(set) var sent = 0
    private(set) var closed = false
    private var deviceSession = "fake-device-session"
    func changeDevice() { deviceSession = "different-device" }
    let uncertain: Bool
    init(uncertain: Bool = false) { self.uncertain = uncertain }
    func supportsBackgroundExecution(tool: String) async -> Bool { true }
    func approvalContext(imageID: String) async throws -> String { deviceSession }
    func screenshot() async throws -> FrameImage { .init(id: "fresh", png: Data(), width: 390, height: 844, capturedAt: Date(), isDemo: true) }
    func tap(x: Int, y: Int, imageID: String) async throws { sent += 1; if uncertain { throw AppError.unknownOutcome } }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { sent += 1 }
    func stop() async { closed = true }
}
private struct DisconnectedModel: ModelProvider {
    static let name = "disconnected-test-model"
    let configuration = ProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try await Task.sleep(nanoseconds: 100_000_000)
        throw ModelError.invalidRequest("测试模型网络断开；没有重试")
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { _ = try await complete(request); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
@MainActor final class BackgroundRunIntegrationTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw AppError.timeout
    }
    func testRealAgentLoopWaitingApprovalSurvivesBackgroundAndDenialNeverSends() async throws {
        let scheduler = FakeScheduler(), bridge = BackgroundSpyBridge()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  runServices: .init(provider: DemoProvider(), bridge: bridge), lifecycle: c)
        model.start(); let lease = scheduler.grant()
        try await waitUntil { model.approval != nil }
        XCTAssertEqual(c.checkpoint?.phase, .waitingApproval); XCTAssertEqual(lease.completions, [true])
        model.setForeground(false); model.approve(true)
        XCTAssertNotNil(model.approval); XCTAssertEqual(scheduler.identifiers.count, 1)
        model.setForeground(true); model.approve(false)
        try await waitUntil { !model.stopping }
        let sent = await bridge.sent, closed = await bridge.closed
        XCTAssertEqual(sent, 0); XCTAssertTrue(closed)
        XCTAssertEqual(c.checkpoint?.phase, .stopped)
    }
    func testUnknownDispatchReturnsToRealAgentAndCompletesWithoutReplay() async throws {
        let scheduler = FakeScheduler(), bridge = BackgroundSpyBridge(uncertain: true)
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  runServices: .init(provider: DemoProvider(), bridge: bridge), lifecycle: c)
        model.start(); _ = scheduler.grant()
        try await waitUntil { model.approval != nil }; model.approve(true)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertEqual(c.checkpoint?.phase, .completed)
        XCTAssertEqual(c.checkpoint?.tools.first(where: { $0.name == "tap" })?.delivery, .outcomeUnknown)
        XCTAssertTrue(c.checkpoint?.tools.contains(where: { $0.name == "screenshot" && $0.delivery == .observedResult }) == true)
        XCTAssertEqual(scheduler.identifiers.count, 2)
        let sent = await bridge.sent, closed = await bridge.closed
        XCTAssertEqual(sent, 1); XCTAssertTrue(closed)
        model.setForeground(false); model.setForeground(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        let stillSent = await bridge.sent; XCTAssertEqual(stillSent, 1)
    }
    func testModelNetworkLossPausesWithoutProgressAndClosesTransport() async throws {
        let scheduler = FakeScheduler(), bridge = BackgroundSpyBridge()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  runServices: .init(provider: DisconnectedModel(), bridge: bridge), lifecycle: c)
        model.start(); let lease = scheduler.grant(); model.setForeground(false)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertEqual(c.checkpoint?.milestones.count, 0)
        XCTAssertEqual(lease.completions, [false])
        let sent = await bridge.sent, closed = await bridge.closed
        XCTAssertEqual(sent, 0); XCTAssertTrue(closed)
    }
    func testChangedDeviceInvalidatesApprovalButAgentCanObserveAndFinish() async throws {
        let scheduler = FakeScheduler(), bridge = BackgroundSpyBridge()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  runServices: .init(provider: DemoProvider(), bridge: bridge), lifecycle: c)
        model.start(); _ = scheduler.grant()
        try await waitUntil { model.approval != nil }
        await bridge.changeDevice(); model.approve(true)
        try await waitUntil { !model.running && !model.stopping }
        let sent = await bridge.sent
        XCTAssertEqual(sent, 0); XCTAssertEqual(scheduler.identifiers.count, 1, "failed approval must not spend a new system segment budget")
        XCTAssertEqual(c.checkpoint?.phase, .completed)
        XCTAssertEqual(c.checkpoint?.tools.first(where: { $0.name == "tap" })?.delivery, .failed)
    }
    func testDemandsReleaseOnBackgroundTaskCompletionWithoutSwiftUIViewUpdates() async throws {
        let bridge = BackgroundSpyBridge(), registry = BackgroundExecutionRegistry(), audio = FakeTaskAudioPlayback()
        let media = StatusPiPController(registry: registry, audioPlayback: audio)
        let background = testCoordinator(registry: registry, media: media); background.applySelection([.audio])
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: .init(provider: DemoProvider(), bridge: bridge), backgroundCoordinator: background)
        media.observeTasks(in: model) // Presentation updates are not the owner of execution.
        model.start()
        try await waitUntil { media.audioActive }
        model.setForeground(false)
        model.stop(message: "test completion")
        try await waitUntil { !model.running && !model.stopping && !media.audioActive }
        XCTAssertTrue(background.desired.isEmpty); XCTAssertFalse(registry.active)
    }
    func testExpirationClosesFakeTransportAndCancelsModel() async throws {
        let scheduler = FakeScheduler(), bridge = BackgroundSpyBridge()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  runServices: .init(provider: DemoProvider(), bridge: bridge), lifecycle: c)
        model.start(); let lease = scheduler.grant()
        model.setForeground(false); XCTAssertTrue(model.running)
        lease.expirationHandler?()
        try await waitUntil { !model.running && !model.stopping }
        let closed = await bridge.closed, sent = await bridge.sent
        XCTAssertTrue(closed); XCTAssertEqual(sent, 0); XCTAssertEqual(lease.completions, [false])
        XCTAssertEqual(model.activeRecord?.phase, .interrupted)
    }
}

@MainActor final class ExecutionTransitionLeaseTests: XCTestCase {
    func testUpgradePreservesProgressExpiryAndCompletesOnce() {
        let handoff = ExecutionTransitionLease(), actual = FakeLease()
        var expirations = 0
        handoff.expirationHandler = { expirations += 1 }
        handoff.report(completed: 3, subtitle: "received")
        handoff.upgrade(to: actual)
        XCTAssertTrue(handoff.valid)
        XCTAssertEqual(actual.reports, [3])
        handoff.expireTransition() // Late UIKit expiry must not revoke the upgraded grant.
        XCTAssertTrue(handoff.valid)
        actual.expirationHandler?()
        XCTAssertEqual(expirations, 1)
        XCTAssertEqual(actual.completions, [false])
        XCTAssertFalse(handoff.valid)
        handoff.complete(success: true); handoff.expire()
        XCTAssertEqual(expirations, 1)
        XCTAssertEqual(actual.completions, [false])
    }
    func testGrantArrivingAfterCancellationCannotRestartExecution() {
        let handoff = ExecutionTransitionLease(), actual = FakeLease()
        handoff.complete(success: false)
        handoff.upgrade(to: actual)
        XCTAssertFalse(handoff.valid)
        XCTAssertEqual(actual.completions, [false])
    }
    func testIndependentLeasesDoNotExpireEachOther() {
        let first = ExecutionTransitionLease(), second = ExecutionTransitionLease()
        let a = FakeLease(), b = FakeLease()
        first.upgrade(to: a); second.upgrade(to: b)
        first.expire()
        XCTAssertFalse(first.valid); XCTAssertTrue(second.valid)
        XCTAssertEqual(a.completions, [false]); XCTAssertTrue(b.completions.isEmpty)
        second.complete(success: true)
        XCTAssertEqual(b.completions, [true])
    }
}
