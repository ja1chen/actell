import Foundation

/// SCK remains exclusive. Shared continuous receipts never bypass capture/USB validity.
@MainActor final class RunExecutionScheduler: RunBackgroundScheduler {
    private let screen = ScreenCaptureRunScheduler()
    private let continued: any RunBackgroundScheduler
    private let coordinator: BackgroundExecutionCoordinator
    private let foregroundOnly = ForegroundOnlyScheduler()
    private var selected: any RunBackgroundScheduler = ForegroundOnlyScheduler()
    private var owners: [String: any RunBackgroundScheduler] = [:]
    private var demand: UUID?
    private var foreground = true
    init(continued: any RunBackgroundScheduler = ContinuedProcessingScheduler(), coordinator: BackgroundExecutionCoordinator = .shared) {
        self.continued = continued; self.coordinator = coordinator
    }
    func configure(context: ScreenUSBExecutionContext?, allowSystemProcessing: Bool,
                   selection: Set<BackgroundMechanism> = [], runID: UUID = UUID(), userInitiated: Bool = false) {
        if let demand { coordinator.releaseDemand(demand); self.demand = nil }
        screen.context = context
        if let context { selected = context.backgroundEnabled ? screen : foregroundOnly }
        else if allowSystemProcessing {
            let token = coordinator.acquireDemand(runID: runID, allowed: selection, userInitiated: userInitiated)
            demand = token
            let scheduler = CompositeRunScheduler(primary: continued, registry: coordinator.registry,
                allowed: { [weak coordinator] in coordinator?.allowed(token) ?? [] },
                systemState: { [weak coordinator] in coordinator?.reportSystem($0, demand: token) })
            scheduler.setForeground(foreground); selected = scheduler
        } else { selected = foregroundOnly }
    }
    func endRun() {
        if let demand { self.demand = nil; coordinator.releaseDemand(demand) }
    }
    func setForeground(_ active: Bool) {
        foreground = active; selected.setForeground(active)
        for owner in owners.values { owner.setForeground(active) }
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        try submit(identifier: identifier, launched: launched, failed: {})
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws {
        owners[identifier] = selected
        try selected.submit(identifier: identifier, launched: launched, failed: failed)
    }
    func cancel(identifier: String) {
        if let owner = owners.removeValue(forKey: identifier) { owner.cancel(identifier: identifier) }
        else { continued.cancel(identifier: identifier) }
    }
}
