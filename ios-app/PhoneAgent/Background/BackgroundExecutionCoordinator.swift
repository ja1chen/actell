import Foundation
import Combine

/// App-owned demands, independent from view lifetime and per-run system grants.
@MainActor final class BackgroundExecutionCoordinator: ObservableObject {
    static let shared = BackgroundExecutionCoordinator(settings: .shared)
    let registry: BackgroundExecutionRegistry
    let media: StatusPiPController?
    let location: LocationBackgroundDriver?
    @Published private(set) var selection: Set<BackgroundMechanism>
    @Published private(set) var resident = false
    @Published private(set) var systemStates: [UUID: BackgroundDriverState] = [:]
    @Published private(set) var locationExplanation = false
    private(set) var locationExplanationInSettings = false
    private var permissionToken: UUID?
    private let settings: BackgroundSettingsStore
    private let gate: PermissionRequestGate
    private var foreground = false
    private var protectedData = true
    private var demands: [UUID: Set<BackgroundMechanism>] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var reconciling = false
    private var reconcileAgain = false
    private var permissionDisabled = false
    init(settings: BackgroundSettingsStore, registry: BackgroundExecutionRegistry = .shared,
         nativeDrivers: Bool = true, locationDriver: LocationBackgroundDriver? = nil, mediaDriver: StatusPiPController? = nil, gate: PermissionRequestGate = .shared) {
        self.settings = settings; self.registry = registry; self.gate = gate; selection = settings.selection; resident = settings.residentEnabled
        media = mediaDriver ?? (nativeDrivers ? StatusPiPController(registry: registry) : nil)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        permissionDisabled = args.contains("--ui-testing") || args.contains(where: { $0.hasSuffix("-probe") }) || ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] == "1"
        // A dedicated simulator UI test may exercise the native prompt; normal fixtures and probes never do.
        if args.contains("--ui-testing") && args.contains("--background-fixture-native-permission") { permissionDisabled = false }
        if permissionDisabled {
            location = locationDriver ?? (nativeDrivers ? LocationBackgroundDriver(registry: registry, configured: true,
                factory: { FixtureLocationManager(denied: args.contains("--background-fixture-location-denied")) }, gate: gate) : nil)
        } else { location = locationDriver ?? (nativeDrivers ? LocationBackgroundDriver(registry: registry, gate: gate) : nil) }
        #else
        location = locationDriver ?? (nativeDrivers ? LocationBackgroundDriver(registry: registry, gate: gate) : nil)
        #endif
        if locationDriver != nil { permissionDisabled = false }
        location?.permissionAllowed = !permissionDisabled
        media?.setForeground(false) // A cold process is not an activated scene.
        settings.$configuration.sink { [weak self] in self?.applySelection($0.knownSelection) }.store(in: &subscriptions)
        settings.$residentEnabled.sink { [weak self] in self?.setResident($0) }.store(in: &subscriptions)
        media?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        location?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    static func testing(selection: Set<BackgroundMechanism>) -> BackgroundExecutionCoordinator {
        let name = "Background.Coordinator." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let settings = BackgroundSettingsStore(defaults: defaults, domain: name)
        let value = BackgroundExecutionCoordinator(settings: settings, registry: BackgroundExecutionRegistry(), nativeDrivers: false)
        defaults.removePersistentDomain(forName: name); value.applySelection(selection); return value
    }
    var desired: Set<BackgroundMechanism> {
        guard protectedData else { return [] }
        return demands.values.reduce(resident ? selection.intersection(BackgroundMechanism.continuous) : []) { $0.union($1.intersection(BackgroundMechanism.continuous)) }
    }
    var residentReady: Bool {
        protectedData && resident && !registry.effectiveSources(allowed: selection.intersection(BackgroundMechanism.continuous)).isEmpty
    }
    func acquireDemand(runID: UUID, allowed: Set<BackgroundMechanism>, userInitiated: Bool = false) -> UUID {
        let id = UUID(); demands[id] = allowed.intersection(selection)
        reconcile()
        if foreground { media?.retryFailedDrivers(); location?.retryIfFailed() }
        if userInitiated { offerLocationPermission() }
        return id
    }
    func allowed(_ token: UUID) -> Set<BackgroundMechanism> { demands[token] ?? [] }
    func releaseDemand(_ token: UUID) { demands.removeValue(forKey: token); systemStates.removeValue(forKey: token); reconcile() }
    func reportSystem(_ state: BackgroundDriverState, demand: UUID) {
        guard demands[demand] != nil else { return }; systemStates[demand] = state
    }
    func applySelection(_ next: Set<BackgroundMechanism>) {
        selection = next
        for id in demands.keys { demands[id]?.formIntersection(next) }
        // Observers must see the reduced run mask before a driver releases a receipt.
        registry.refresh(); reconcile()
    }
    func setResident(_ enabled: Bool) { resident = enabled; reconcile() }
    func setForeground(_ value: Bool, transitioning: Bool = false) {
        foreground = value
        if !value { dismissLocationExplanation() }
        if !transitioning { media?.setForeground(value) }; reconcile()
    }
    func setProtectedData(_ value: Bool) { protectedData = value; reconcile() }
    func shutdown() { demands.removeAll(); resident = false; dismissLocationExplanation(); reconcile() }
    private func reconcile() {
        if reconciling { reconcileAgain = true; return }
        reconciling = true
        repeat {
            reconcileAgain = false
            let wanted = desired
            media?.setDemand(wanted.intersection([.audio, .pictureInPicture]))
            location?.setDemand(wanted.contains(.location), foreground: foreground)
            if !wanted.contains(.location) { dismissLocationExplanation() }
        } while reconcileAgain
        reconciling = false
    }
    func offerLocationPermission(fromSettings: Bool = false) {
        guard foreground, protectedData, !permissionDisabled, desired.contains(.location),
              location?.authorization == .notDetermined, !locationExplanation,
              let token = gate.acquire() else { return }
        permissionToken = token; locationExplanationInSettings = fromSettings; locationExplanation = true
    }
    func acceptLocationExplanation() {
        locationExplanation = false
        guard let token = permissionToken else { return }; permissionToken = nil
        guard foreground, desired.contains(.location) else { gate.release(token); return }
        location?.requestPermission(gateToken: token)
    }
    func dismissLocationExplanation() {
        locationExplanation = false
        if let permissionToken { gate.release(permissionToken) }; permissionToken = nil
    }
    /// The settings toggle is an explicit foreground permission action, even without a run or residency.
    func setLocationSelected(_ selected: Bool) {
        settings.set(.location, selected: selected)
        guard selected, settings.selection.contains(.location), foreground, protectedData, !permissionDisabled else { return }
        location?.refreshAuthorization()
        guard location?.authorization == .notDetermined, let token = gate.acquire() else { return }
        location?.requestPermission(gateToken: token, forSelection: true)
    }
    func stateText(_ mechanism: BackgroundMechanism) -> String {
        switch mechanism {
        case .audio: return media?.audioState.title ?? BackgroundDriverState.idle.title
        case .pictureInPicture: return media?.pipState.title ?? BackgroundDriverState.idle.title
        case .location: return location?.state.title ?? BackgroundDriverState.idle.title
        case .systemTask:
            let states = Array(systemStates.values)
            if states.contains(.active) { return String(localized: "Background execution is available for this task") }
            return states.first?.title ?? BackgroundDriverState.idle.title
        }
    }
    static let locationPurpose = String(localized: "The app uses location services to help the current task continue when you switch apps. Your location is never saved or uploaded. This uses more battery and shows the system location indicator. You can decline and use other selected options. The system may still pause or stop the task.")
}
