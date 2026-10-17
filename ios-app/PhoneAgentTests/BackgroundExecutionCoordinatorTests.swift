import XCTest
import CoreLocation
@testable import PhoneAgent

@MainActor final class BackgroundExecutionCoordinatorTests: XCTestCase {
    func testMasksGenerationsAndObserverRemoval() {
        let registry = BackgroundExecutionRegistry()
        let owner = UUID(), old = BackgroundSourceToken(mechanism: .audio, owner: owner)
        let new = BackgroundSourceToken(mechanism: .audio, owner: owner)
        var changes = 0
        let observation = registry.observe { changes += 1 }
        registry.publish(old); registry.publish(new); registry.revoke(old)
        XCTAssertEqual(registry.effectiveSources(allowed: [.audio]), [.audio])
        XCTAssertTrue(registry.effectiveSources(allowed: [.location]).isEmpty)
        registry.removeObserver(observation); let count = changes
        registry.revoke(new); XCTAssertEqual(count, changes)
        XCTAssertFalse(registry.active)
    }
    func testEveryCombinationLosesOnlyItsOwnSources() {
        for mask in 0..<16 {
            let registry = BackgroundExecutionRegistry()
            let chosen = Set(BackgroundMechanism.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            let tokens = chosen.filter { $0 != .systemTask }.map { BackgroundSourceToken(mechanism: $0, owner: UUID()) }
            for token in tokens { registry.publish(token) }
            for (index, token) in tokens.enumerated() {
                registry.revoke(token)
                XCTAssertEqual(registry.effectiveSources(allowed: chosen).count, tokens.count - index - 1)
            }
        }
    }
    func testRunRevocationIsPermanentAndResidencyIsIndependent() {
        let coordinator = BackgroundExecutionCoordinator.testing(selection: [.audio, .location])
        let a = coordinator.acquireDemand(runID: UUID(), allowed: [.audio, .location])
        coordinator.applySelection([.audio])
        coordinator.applySelection([.audio, .location, .pictureInPicture])
        XCTAssertEqual(coordinator.allowed(a), [.audio])
        let b = coordinator.acquireDemand(runID: UUID(), allowed: [.location])
        coordinator.releaseDemand(a)
        XCTAssertEqual(coordinator.desired, [.location])
        coordinator.setResident(true)
        coordinator.releaseDemand(b)
        XCTAssertEqual(coordinator.desired, [.audio, .location, .pictureInPicture])
        coordinator.applySelection([.systemTask])
        XCTAssertTrue(coordinator.desired.isEmpty, "system-only residency must never synthesize audio")
        coordinator.setResident(false)
    }
}

@MainActor private final class CountingBackgroundAudio: TaskAudioPlayback {
    var onStopped: (() -> Void)?
    var starts = 0, stops = 0
    func start() async throws -> Bool { starts += 1; return true }
    func stop() { stops += 1 }
}
@MainActor final class BackgroundDemandIntegrationTests: XCTestCase {
    func testPersistedResidencyWaitsForActualForegroundScene() async {
        let registry = BackgroundExecutionRegistry(), audio = CountingBackgroundAudio()
        let domain = UUID().uuidString, defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = BackgroundSettingsStore(defaults: defaults, domain: domain)
        settings.set(.location, selected: false); settings.setResident(true)
        let coordinator = BackgroundExecutionCoordinator(settings: settings, registry: registry, nativeDrivers: false,
            mediaDriver: StatusPiPController(registry: registry, audioPlayback: audio))
        defer { defaults.removePersistentDomain(forName: domain) }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(audio.starts, 0); XCTAssertFalse(registry.active)
        coordinator.setForeground(true)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(audio.starts, 1); XCTAssertTrue(registry.active)
        coordinator.shutdown(); XCTAssertFalse(registry.active)
    }
    func testFinishingOneRunDoesNotStopOtherRunAndResidencyIsIndependent() async {
        let registry = BackgroundExecutionRegistry(), audio = CountingBackgroundAudio()
        let media = StatusPiPController(registry: registry, audioPlayback: audio)
        let coordinator = testCoordinator(registry: registry, media: media)
        coordinator.applySelection([.audio])
        let a = coordinator.acquireDemand(runID: UUID(), allowed: [.audio])
        let b = coordinator.acquireDemand(runID: UUID(), allowed: [.audio])
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(registry.active); XCTAssertEqual(audio.starts, 1)
        coordinator.releaseDemand(a); XCTAssertTrue(registry.active)
        coordinator.setResident(true); coordinator.releaseDemand(b); XCTAssertTrue(registry.active)
        coordinator.setResident(false); XCTAssertFalse(registry.active)
    }
    func testPiPPreviewAndStopNeverRevokeAudio() async {
        let registry = BackgroundExecutionRegistry(), audio = CountingBackgroundAudio()
        let media = StatusPiPController(registry: registry, audioPlayback: audio)
        media.setDemand([.audio])
        for _ in 0..<30 { await Task.yield() }
        media.setPreviewEnabled(true); media.stop(); media.setPreviewEnabled(false)
        XCTAssertTrue(media.audioActive); XCTAssertEqual(registry.effectiveSources(allowed: [.audio, .pictureInPicture]), [.audio])
        media.setDemand([]); XCTAssertFalse(registry.active)
    }
    func testDeselectImmediatelyRevokesAllOldRunsAndRecheckOnlyHelpsNextRun() async throws {
        let registry = BackgroundExecutionRegistry(), audio = CountingBackgroundAudio()
        let coordinator = testCoordinator(registry: registry, media: StatusPiPController(registry: registry, audioPlayback: audio))
        coordinator.applySelection([.audio])
        let scheduler = RunExecutionScheduler(coordinator: coordinator)
        scheduler.configure(context: nil, allowSystemProcessing: true, selection: [.audio])
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let generation = UUID()
        try lifecycle.begin(identity: .init(conversationID: UUID(), runID: UUID()), generation: generation)
        for _ in 0..<30 { await Task.yield() }
        lifecycle.setForeground(false)
        coordinator.applySelection([])
        XCTAssertEqual(lifecycle.checkpoint?.phase, .paused); XCTAssertFalse(registry.active)
        coordinator.applySelection([.audio]); XCTAssertTrue(coordinator.desired.isEmpty)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: generation, backgroundCapable: true))
    }
}


@MainActor private final class SettingsPermissionLocation: LocationManaging {
    var authorization: CLAuthorizationStatus = .notDetermined
    var servicesEnabled = true, reducedAccuracy = true
    var onEvent: ((LocationEvent) -> Void)?
    var requests = 0, starts = 0
    func requestWhenInUse() { requests += 1 }
    func start() { starts += 1 }
    func stop() { onEvent = nil }
}

@MainActor final class BackgroundSettingsPermissionTests: XCTestCase {
    private func makeCoordinator(_ manager: SettingsPermissionLocation, gate: PermissionRequestGate) -> (BackgroundExecutionCoordinator, BackgroundSettingsStore, UserDefaults, String) {
        let name = "Background.Settings.Permission." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let settings = BackgroundSettingsStore(defaults: defaults, domain: name)
        let registry = BackgroundExecutionRegistry()
        let location = LocationBackgroundDriver(registry: registry, configured: true, factory: { manager }, gate: gate)
        let coordinator = BackgroundExecutionCoordinator(settings: settings, registry: registry, nativeDrivers: false, locationDriver: location, gate: gate)
        return (coordinator, settings, defaults, name)
    }

    func testToggleRequestsPermissionWithoutStartingLocationOrResidency() {
        let manager = SettingsPermissionLocation(), gate = PermissionRequestGate()
        let (coordinator, settings, defaults, name) = makeCoordinator(manager, gate: gate)
        defer { defaults.removePersistentDomain(forName: name) }
        coordinator.setForeground(true)
        XCTAssertFalse(settings.selection.contains(.location)); XCTAssertEqual(manager.requests, 0)
        coordinator.setLocationSelected(true)
        XCTAssertTrue(settings.selection.contains(.location)); XCTAssertEqual(manager.requests, 1)
        XCTAssertFalse(settings.residentEnabled); XCTAssertTrue(coordinator.desired.isEmpty)
        XCTAssertEqual(manager.starts, 0); XCTAssertFalse(coordinator.registry.active)
        manager.authorization = .authorizedWhenInUse; manager.onEvent?(.authorization)
        XCTAssertEqual(manager.starts, 0); XCTAssertFalse(coordinator.registry.active)
        coordinator.setLocationSelected(false); coordinator.setLocationSelected(true)
        XCTAssertEqual(manager.requests, 1, "already authorized does not request again")
    }

    func testLatePermissionAfterSwitchOffCannotStartOrReselectLocation() {
        let manager = SettingsPermissionLocation(), gate = PermissionRequestGate()
        let (coordinator, settings, defaults, name) = makeCoordinator(manager, gate: gate)
        defer { defaults.removePersistentDomain(forName: name) }
        coordinator.setForeground(true); coordinator.setLocationSelected(true)
        coordinator.setLocationSelected(false)
        XCTAssertNil(gate.acquire(), "visible permission request retains ownership")
        manager.authorization = .authorizedWhenInUse; manager.onEvent?(.authorization)
        XCTAssertFalse(settings.selection.contains(.location)); XCTAssertEqual(manager.starts, 0)
        let token = gate.acquire(); XCTAssertNotNil(token); if let token { gate.release(token) }
    }

    func testBackgroundDeniedAndBusyGateNeverPromptOrChainRequests() {
        let manager = SettingsPermissionLocation(), gate = PermissionRequestGate()
        let (coordinator, _, defaults, name) = makeCoordinator(manager, gate: gate)
        defer { defaults.removePersistentDomain(forName: name) }
        coordinator.setLocationSelected(true); XCTAssertEqual(manager.requests, 0)
        coordinator.setForeground(true); XCTAssertEqual(manager.requests, 0)
        coordinator.setLocationSelected(false)
        let other = gate.acquire()!
        coordinator.setLocationSelected(true); XCTAssertEqual(manager.requests, 0)
        gate.release(other); XCTAssertEqual(manager.requests, 0, "permission requests are never queued")
        for status in [CLAuthorizationStatus.denied, .restricted, .authorizedWhenInUse] {
            manager.authorization = status
            coordinator.setLocationSelected(false); coordinator.setLocationSelected(true)
            XCTAssertEqual(manager.requests, 0); XCTAssertEqual(manager.starts, 0)
        }
    }
}


@MainActor private final class ControlledPiP: StatusPiPControlling {
    var isPictureInPictureActive = false
    var isPictureInPicturePossible = true
    var isPictureInPictureSuspended = false
    var canStartPictureInPictureAutomaticallyFromInline = false
    var starts = 0, stops = 0, detached = false
    func startPictureInPicture() { starts += 1 }
    func stopPictureInPicture() { stops += 1 }
    func invalidatePlaybackState() {}
    func detachDelegate() { detached = true }
}

@MainActor final class PiPReturnLifecycleTests: XCTestCase {
    func testReturnDoesNotReuseDisplayLayerUntilPreviousControllerStops() async {
        let registry = BackgroundExecutionRegistry(), audio = CountingBackgroundAudio()
        let session = AudioSessionCoordinator(activate: { $0(true) }, deactivate: { $0() })
        var controllers: [ControlledPiP] = []
        let media = StatusPiPController(registry: registry, audioPlayback: audio, supported: true, audioSession: session,
            controllerFactory: { _, _ in let controller = ControlledPiP(); controllers.append(controller); return controller })
        media.setDemand([.pictureInPicture, .audio])
        await session.drain(); for _ in 0..<30 { await Task.yield() }
        guard let first = controllers.first else { XCTFail("controller must be prepared"); return }
        media.setForeground(false); first.isPictureInPictureActive = true
        media.didStartPictureInPicture(ObjectIdentifier(first))
        XCTAssertTrue(media.active)
        media.setForeground(true)
        XCTAssertEqual(controllers.count, 1, "old controller still owns the sample-buffer display layer while stopping")
        XCTAssertFalse(media.active); XCTAssertTrue(media.audioActive)
        media.didStartPictureInPicture(ObjectIdentifier(first)) // Late AVKit start after returning.
        XCTAssertFalse(media.active)
        first.isPictureInPictureActive = false
        media.didStopPictureInPicture(ObjectIdentifier(first))
        await session.drain(); for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(controllers.count, 2, "source may be reused only after the stop callback")
        XCTAssertTrue(first.detached); XCTAssertTrue(media.audioActive)
        media.setDemand([]); await session.drain()
    }

    func testRetirementTimeoutDoesNotReleaseLayerAndOldCallbacksCannotStopNewPiP() async {
        let registry = BackgroundExecutionRegistry()
        let session = AudioSessionCoordinator(activate: { $0(true) }, deactivate: { $0() })
        var controllers: [ControlledPiP] = []
        let media = StatusPiPController(registry: registry, supported: true, audioSession: session,
            controllerFactory: { _, _ in let controller = ControlledPiP(); controllers.append(controller); return controller })
        media.setDemand([.pictureInPicture]); await session.drain()
        for _ in 0..<30 { await Task.yield() }
        guard let first = controllers.first else { XCTFail("controller must be prepared"); return }
        media.setForeground(false); first.isPictureInPictureActive = true
        media.didStartPictureInPicture(ObjectIdentifier(first)); media.setForeground(true)
        media.retirementTimedOut(ObjectIdentifier(first))
        media.setForeground(false); media.setForeground(true)
        XCTAssertEqual(controllers.count, 1); XCTAssertFalse(first.detached)
        XCTAssertFalse(registry.active)
        first.isPictureInPictureActive = false
        media.didStopPictureInPicture(ObjectIdentifier(first))
        await session.drain(); for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(controllers.count, 2)
        guard controllers.count == 2 else { media.setDemand([]); return }
        let second = controllers[1]
        media.setForeground(false); second.isPictureInPictureActive = true
        media.didStartPictureInPicture(ObjectIdentifier(second))
        XCTAssertTrue(media.active); XCTAssertTrue(registry.active)
        media.didStopPictureInPicture(ObjectIdentifier(first))
        media.failedToStartPictureInPicture(ObjectIdentifier(first))
        XCTAssertTrue(media.active); XCTAssertTrue(registry.active)
        media.setDemand([])
        second.isPictureInPictureActive = false; media.didStopPictureInPicture(ObjectIdentifier(second))
        await session.drain()
    }

    func testNativeUserStopDoesNotIssueAnotherStopOrWaitForSecondCallback() async {
        let session = AudioSessionCoordinator(activate: { $0(true) }, deactivate: { $0() })
        var controllers: [ControlledPiP] = []
        let media = StatusPiPController(registry: BackgroundExecutionRegistry(), supported: true, audioSession: session,
            controllerFactory: { _, _ in let controller = ControlledPiP(); controllers.append(controller); return controller })
        media.setDemand([.pictureInPicture]); await session.drain()
        for _ in 0..<30 { await Task.yield() }
        guard let first = controllers.first else { XCTFail("controller must be prepared"); return }
        media.setForeground(false); first.isPictureInPictureActive = true
        media.didStartPictureInPicture(ObjectIdentifier(first))
        first.isPictureInPictureActive = false
        media.didStopPictureInPicture(ObjectIdentifier(first))
        XCTAssertEqual(first.stops, 0, "didStop is already terminal; do not call native stop again")
        XCTAssertTrue(first.detached); XCTAssertFalse(media.active)
        media.setForeground(false)
        XCTAssertEqual(controllers.count, 1, "respect user dismissal in this background visit")
        media.setForeground(true)
        await session.drain(); for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(controllers.count, 2, "foreground return permits the next background visit")
        media.setDemand([]); await session.drain()
    }

    func testPendingStartReturnAndRepeatedTransitionsDoNotCreateOverlappingControllers() async {
        let session = AudioSessionCoordinator(activate: { $0(true) }, deactivate: { $0() })
        var controllers: [ControlledPiP] = []
        let media = StatusPiPController(registry: BackgroundExecutionRegistry(), supported: true, audioSession: session,
            controllerFactory: { _, _ in let controller = ControlledPiP(); controllers.append(controller); return controller })
        media.setDemand([.pictureInPicture]); await session.drain()
        for _ in 0..<30 { await Task.yield() }
        guard let first = controllers.first else { XCTFail("controller must be prepared"); return }
        media.setForeground(false); XCTAssertEqual(first.starts, 1)
        media.setForeground(true); media.setForeground(false); media.setForeground(true)
        XCTAssertEqual(controllers.count, 1)
        XCTAssertFalse(media.active)
        media.failedToStartPictureInPicture(ObjectIdentifier(first))
        await session.drain(); for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(controllers.count, 2)
        XCTAssertFalse(media.active)
        media.setDemand([]); await session.drain()
    }
}
