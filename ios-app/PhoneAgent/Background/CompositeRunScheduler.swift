import Foundation

@MainActor final class CompositeRunScheduler: RunBackgroundScheduler {
    private let primary: (any RunBackgroundScheduler)?
    private let registry: BackgroundExecutionRegistry
    private let allowed: () -> Set<BackgroundMechanism>
    private let handoffSeconds: Double
    private let systemState: (BackgroundDriverState) -> Void
    private var foreground = true
    private var leases: [String: CompositeRunLease] = [:]
    init(primary: (any RunBackgroundScheduler)? = nil, registry: BackgroundExecutionRegistry = .shared,
         allowed: @escaping () -> Set<BackgroundMechanism>, handoffSeconds: Double = 5,
         systemState: @escaping (BackgroundDriverState) -> Void = { _ in }) {
        self.primary = primary; self.registry = registry; self.allowed = allowed; self.handoffSeconds = handoffSeconds; self.systemState = systemState
    }
    func setForeground(_ value: Bool) { foreground = value; for lease in Array(leases.values) { lease.setForeground(value) } }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        cancel(identifier: identifier)
        let lease = CompositeRunLease(registry: registry, allowed: allowed, foreground: foreground,
                                      handoffSeconds: handoffSeconds, systemState: systemState, cancelSystem: { [weak self] in self?.primary?.cancel(identifier: identifier) })
        leases[identifier] = lease
        launched(lease) // Pending capability is explicit: backgroundReady remains false.
        if allowed().contains(.systemTask), let primary {
            systemState(.starting)
            do {
                try primary.submit(identifier: identifier, launched: { [weak lease] grant in
                    guard let lease else { grant.complete(success: false); return }; lease.accept(grant)
                }, failed: { [weak lease] in lease?.systemEnded() })
            } catch { lease.systemEnded() }
        }
        lease.setForeground(foreground)
    }
    func cancel(identifier: String) { leases.removeValue(forKey: identifier)?.complete(success: false) }
}

@MainActor final class CompositeRunLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    private(set) var requiresRunPause = false
    var backgroundReady: Bool {
        !completed && ((!systemExhausted && allowed().contains(.systemTask) && primary?.backgroundReady == true) ||
            !registry.effectiveSources(allowed: allowed()).isEmpty)
    }
    private let registry: BackgroundExecutionRegistry
    private let allowed: () -> Set<BackgroundMechanism>
    private let cancelSystem: () -> Void
    private let systemState: (BackgroundDriverState) -> Void
    private let handoffSeconds: Double
    private var primary: (any RunBackgroundLease)?
    private var foreground: Bool
    private var completed = false, systemExhausted = false, systemCancelled = false
    private var observer: UUID?
    private var handoff: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private var wasReady = false
    private var progress: (Int, String)?
    init(registry: BackgroundExecutionRegistry, allowed: @escaping () -> Set<BackgroundMechanism>, foreground: Bool,
         handoffSeconds: Double, systemState: @escaping (BackgroundDriverState) -> Void = { _ in }, cancelSystem: @escaping () -> Void) {
        self.registry = registry; self.allowed = allowed; self.foreground = foreground
        self.handoffSeconds = handoffSeconds; self.cancelSystem = cancelSystem; self.systemState = systemState
        observer = registry.observe { [weak self] in self?.sourcesChanged() }
        wasReady = backgroundReady
    }
    func accept(_ grant: any RunBackgroundLease) {
        guard !completed, !systemExhausted, allowed().contains(.systemTask) else { grant.complete(success: false); return }
        if primary === grant { systemState(grant.backgroundReady ? .active : .starting); sourcesChanged(); return }
        primary?.complete(success: false); primary = grant
        systemState(grant.backgroundReady ? .active : .starting)
        grant.expirationHandler = { [weak self, weak grant] in
            guard let self, let grant, self.primary === grant else { return }
            if grant.requiresRunPause { self.requiresRunPause = true; self.expire() }
            else { self.systemEnded() }
        }
        if let progress { grant.report(completed: progress.0, subtitle: progress.1) }
        sourcesChanged()
    }
    func systemEnded() {
        guard !completed, !systemExhausted else { return }
        systemExhausted = true; systemState(.pausedBySystem)
        let old = primary; primary = nil; old?.expirationHandler = nil; old?.complete(success: false)
        cancelSystemOnce(); sourcesChanged()
    }
    private func cancelSystemOnce() {
        guard !systemCancelled else { return }; systemCancelled = true; cancelSystem()
    }
    private func sourcesChanged() {
        guard !completed else { return }
        if !allowed().contains(.systemTask), !systemExhausted { systemEnded(); return }
        let ready = backgroundReady
        if ready { handoff?.cancel(); handoff = nil }
        else if !foreground, wasReady { expire(); return }
        wasReady = ready
        if !foreground, !ready { scheduleHandoff() }
    }
    func setForeground(_ value: Bool) {
        guard !completed else { return }; foreground = value
        if value { handoff?.cancel(); handoff = nil }
        else if !backgroundReady { scheduleHandoff() }
    }
    private func scheduleHandoff() {
        guard handoff == nil, !completed else { return }
        if deadline == nil { deadline = .now.advanced(by: .seconds(handoffSeconds)) }
        guard let deadline else { return }
        handoff = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, !self.foreground, !self.backgroundReady else { return }
            self.expire()
        }
    }
    private func expire() {
        guard !completed else { return }
        let handler = expirationHandler; complete(success: false); handler?()
    }
    func report(completed: Int, subtitle: String) { progress = (completed, subtitle); primary?.report(completed: completed, subtitle: subtitle) }
    func complete(success: Bool) {
        guard !completed else { return }; completed = true; expirationHandler = nil
        handoff?.cancel(); handoff = nil
        if let observer { registry.removeObserver(observer) }; observer = nil
        let old = primary; primary = nil; old?.expirationHandler = nil; old?.complete(success: success)
        cancelSystemOnce(); systemState(.stopped)
    }
}

/// Bounded metadata only. Never pass position data, task content or credentials.
@MainActor enum BackgroundExecutionTrace {
    static func record(_ event: String) {
        let file = URL.documentsDirectory.appending(path: "background-execution-events.log")
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(Date().ISO8601Format()) \(event)")
        try? (lines.suffix(200).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
