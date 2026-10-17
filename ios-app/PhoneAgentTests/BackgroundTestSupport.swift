import Foundation
@testable import PhoneAgent

// Compatibility support for existing safety tests; all execution uses the new registry.
@MainActor extension BackgroundExecutionRegistry {
    func update(owner: UUID, active: Bool, mechanism: BackgroundMechanism = .audio) {
        let token = BackgroundSourceToken(mechanism: mechanism, owner: owner, generation: owner)
        if active { publish(token) } else { revoke(token) }
    }
}
@MainActor func testCoordinator(registry: BackgroundExecutionRegistry, media: StatusPiPController? = nil) -> BackgroundExecutionCoordinator {
    let domain = "BackgroundHarness." + UUID().uuidString, defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = BackgroundSettingsStore(defaults: defaults, domain: domain)
    let coordinator = BackgroundExecutionCoordinator(settings: store, registry: registry, nativeDrivers: false, mediaDriver: media)
    defaults.removePersistentDomain(forName: domain)
    coordinator.applySelection(Set(BackgroundMechanism.allCases)); coordinator.setForeground(true)
    return coordinator
}
@MainActor final class TestBackgroundMedia {
    private let media: StatusPiPController
    private let coordinator: BackgroundExecutionCoordinator
    private var run: UUID?
    var audioActive: Bool { media.audioActive }
    var previewEnabled: Bool { media.previewEnabled }
    var backgroundResident: Bool { coordinator.resident }
    var policy: TaskPiPPolicy { var policy = media.policy; policy.running = !coordinator.desired.isEmpty; return policy }
    var allowed: Set<BackgroundMechanism> { run.map(coordinator.allowed) ?? [] }
    init(registry: BackgroundExecutionRegistry, audio: any TaskAudioPlayback) {
        media = StatusPiPController(registry: registry, audioPlayback: audio)
        coordinator = testCoordinator(registry: registry, media: media); coordinator.applySelection([.audio])
    }
    func setBackgroundMode(_ mechanism: BackgroundMechanism) { coordinator.applySelection([mechanism]) }
    func setBackgroundResident(_ value: Bool) { coordinator.setResident(value) }
    func setForeground(_ value: Bool) { coordinator.setForeground(value) }
    func setTaskRunning(_ value: Bool) {
        if value, run == nil { run = coordinator.acquireDemand(runID: UUID(), allowed: coordinator.selection) }
        if !value, let run { self.run = nil; coordinator.releaseDemand(run) }
    }
}
