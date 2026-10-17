import Foundation
import BackgroundTasks
import UIKit

@available(iOS 27.0, *)
@MainActor final class ContinuedProcessingScheduler: RunBackgroundScheduler {
    var diagnostic: ((String) -> Void)?
    private var leases: [String: ExecutionTransitionLease] = [:]
    private var submissions: [String: Task<Void, Never>] = [:]
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        try submit(identifier: identifier, launched: launched, failed: {})
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws {
        let transition = ExecutionTransitionLease()
        transition.begin()
        leases[identifier] = transition
        // The permitted Info.plist prefix is a wildcard, but both registration
        // and submission use this same concrete, unique per-segment identifier.
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: { [weak self] task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                transition.upgrade(to: ContinuedProcessingLease(task: continued))
                BackgroundExecutionTrace.record("execution.continuedGranted")
                self?.diagnostic?("continued processing granted")
                if transition.valid { launched(transition) }
            }
        }) else {
            transition.complete(success: false); leases.removeValue(forKey: identifier)
            throw AppError.unavailable(String(localized: "Could not register the background task"))
        }
        if transition.valid { launched(transition) }
        submissions[identifier] = Task { [weak self] in
            defer { self?.submissions.removeValue(forKey: identifier) }
            do {
                try Task.checkCancellation()
                try await Self.submitRequest(identifier: identifier)
                BackgroundExecutionTrace.record("execution.continuedRequestAccepted")
                self?.diagnostic?("continued processing request accepted")
                // Cancellation can race the asynchronous registration response.
                // Re-cancel after acceptance so an ended run leaves no request.
                if Task.isCancelled { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
            }
            catch {
                BackgroundExecutionTrace.record("execution.continuedRequestRejected code=\((error as NSError).code)")
                self?.diagnostic?("continued processing request rejected: \(error.localizedDescription)")
                if !Task.isCancelled { transition.complete(success: false); self?.cancel(identifier: identifier); failed() }
            }
        }
    }
    private nonisolated static func submitRequest(identifier: String) async throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: String(localized: "\(AppIdentity.displayName) is processing your task"), subtitle: String(localized: "Preparing task"))
        request.strategy = .fail
        request.requiredResources = [] // CPU/network only; no GPU entitlement.
        // iOS 27's asynchronous API reports errors missed by deprecated submit.
        // No UI/MainActor work runs while waiting for the scheduler's response.
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }
    func cancel(identifier: String) {
        leases.removeValue(forKey: identifier)?.complete(success: false)
        submissions.removeValue(forKey: identifier)?.cancel()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

@available(iOS 26.0, *)
@MainActor private final class ContinuedProcessingLease: RunBackgroundLease {
    var backgroundReady: Bool { !completed }
    var requiresRunPause: Bool { true }
    private let task: BGContinuedProcessingTask
    private var completed = false
    var expirationHandler: (() -> Void)?
    init(task: BGContinuedProcessingTask) {
        self.task = task
        // An adaptive agent does not know the final number of steps. Keep
        // Progress indeterminate; the subtitle describes the current operation.
        task.progress.totalUnitCount = -1
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, !self.completed else { return }
                BackgroundExecutionTrace.record("execution.continuedExpired completed=\(self.task.progress.completedUnitCount)")
                self.expirationHandler?()
                self.complete(success: false)
            }
        }
    }
    func report(completed: Int, subtitle: String) {
        guard !self.completed else { return }
        task.updateTitle(String(localized: "\(AppIdentity.displayName) is processing your task"), subtitle: subtitle)
    }
    func complete(success: Bool) {
        guard !completed else { return }; completed = true
        expirationHandler = nil; task.expirationHandler = nil
        if success {
            task.progress.totalUnitCount = max(1, task.progress.completedUnitCount)
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
        task.setTaskCompleted(success: success)
    }
}

/// A real finite UIKit grant covers the scheduler handoff. The same lease
/// upgrades to continued processing without losing the coordinator's expiry fence.
@MainActor final class ExecutionTransitionLease: RunBackgroundLease {
    private var token: UIBackgroundTaskIdentifier = .invalid
    private var continued: (any RunBackgroundLease)?
    private var completed = false
    private var progress: (Int, String)?
    var expirationHandler: (() -> Void)?
    var valid: Bool { !completed && (token != .invalid || continued?.backgroundReady == true) }
    var backgroundReady: Bool { valid }
    private(set) var requiresRunPause = false
    func begin() {
        guard !completed, token == .invalid else { return }
        token = UIApplication.shared.beginBackgroundTask(withName: "Actell execution") { [weak self] in
            Task { @MainActor in self?.expireTransition() }
        }
    }
    func upgrade(to lease: any RunBackgroundLease) {
        guard !completed, continued == nil else { lease.complete(success: false); return }
        continued = lease
        lease.expirationHandler = { [weak self] in self?.requiresRunPause = true; self?.expire() }
        endTransition()
        if let progress { lease.report(completed: progress.0, subtitle: progress.1) }
    }
    func expireTransition() {
        guard token != .invalid, continued == nil else { return }
        BackgroundExecutionTrace.record("execution.uikitExpired")
        expire()
    }
    func expire() {
        guard !completed else { return }
        expirationHandler?()
        complete(success: false)
    }
    private func endTransition() {
        guard token != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token); token = .invalid
    }
    func report(completed: Int, subtitle: String) {
        guard !self.completed else { return }
        progress = (completed, subtitle); continued?.report(completed: completed, subtitle: subtitle)
    }
    func complete(success: Bool) {
        guard !completed else { return }
        completed = true; expirationHandler = nil
        endTransition(); continued?.complete(success: success); continued = nil
    }
}
