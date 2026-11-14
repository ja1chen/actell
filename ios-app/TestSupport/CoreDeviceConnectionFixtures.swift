import XCTest
import UIKit
import ProviderCore
@testable import PhoneAgent

@MainActor final class CoreDeviceConnectionSpy: CoreDeviceControlConnection {
    var ready = true
    var connectionFailure: String?
    var holdRelease = false
    var releaseGate: CheckedContinuation<Void, Never>?
    func awaitControlRelease() async {
        if holdRelease { await withCheckedContinuation { releaseGate = $0 } }
    }
    var running = false
    var agentReserved = false
    var controlSessionID = UUID()
    var activationError: AppError?
    var launchPID: Int32 = 7001
    var fallbackPIDs: [Int32?] = []
    var accessibilityData: Data?
    var accessibilityError: Error?
    func agentAccessibilityObservation(owner: UUID, session: UUID, fallbackPID: Int32?) async throws -> Data? {
        fallbackPIDs.append(fallbackPID)
        if let accessibilityError { throw accessibilityError }
        return accessibilityData
    }
    var launchedBundles: [String] = []
    var launchReleaseCounts: [Int] = []
    var systemActions: [String] = []
    var appQueries = 0
    var inputDelay: Duration?
    var taps = 0
    var drags: [UInt16] = []
    var releases = 0
    var reservations = 0
    var captures = 0
    var geometryToken: String?
    var logicalBounds: NativeDisplayBounds?
    var geometryError: Error?
    var geometryChecks = 0
    func agentInputGeometry(owner: UUID, session: UUID) async throws -> NativeInputDisplayGeometry {
        if let geometryError { throw geometryError }
        guard let geometryToken else { throw RemoteRPCError("geometry_unavailable", "No synthetic geometry") }
        return NativeInputDisplayGeometry(token: geometryToken, logicalBounds: logicalBounds)
    }
    func agentCaptureWithGeometry(owner: UUID, session: UUID) async throws -> (Data, String?) {
        (try await agentCapture(owner: owner, session: session), geometryToken)
    }
    func agentValidateGeometry(owner: UUID, session: UUID, token: String) async throws {
        geometryChecks += 1
        guard geometryToken == token else { throw AppError.invalid("Geometry changed") }
    }
    func agentTapWithGeometry(owner: UUID, session: UUID, x: UInt16, y: UInt16, geometry: String, validate: () throws -> Void) async throws {
        try await agentValidateGeometry(owner: owner, session: session, token: geometry)
        try validate(); taps += 1
    }
    func agentDragWithGeometry(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, geometry: String, validate: () throws -> Void) async throws {
        try await agentValidateGeometry(owner: owner, session: session, token: geometry)
        try validate(); drags = [fromX, fromY, toX, toY, durationMS]
    }
    var captureError: CoreDeviceControlError?
    var connectionStopID: UUID? = UUID()
    var allowsConnectionWait = false
    var connectionDelay: Duration?
    var connectionAttempts = 0
    var onConnect: (() -> Void)?
    private var connectionTask: Task<Void, Never>?
    func connectIfNeeded() throws {
        connectionAttempts += 1
        onConnect?()
        guard allowsConnectionWait else {
            if !ready { throw CoreDeviceControlError.unavailable(connectionFailure ?? "ESP32 未连接") }
            return
        }
        if let connectionDelay, connectionTask == nil {
            connectionTask = Task { @MainActor in
                try? await Task.sleep(for: connectionDelay)
                self.ready = true; self.controlSessionID = UUID()
            }
        }
    }
    var png: Data = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 20), format: {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
    }()).pngData { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 20)) }
    func agentApplications(owner: UUID, session: UUID) async throws -> Data {
        appQueries += 1
        return Data("[{\"name\":\"Fixture\",\"bundle_id\":\"example.fixture\"}]".utf8)
    }
    @discardableResult func agentSystemAction(owner: UUID, session: UUID, name: String, text: String, arguments: [String], validate: () throws -> Void) async throws -> NativeApplicationLaunch? {
        try validate(); systemActions.append(name)
        if name == "launch_app" {
            launchedBundles.append(text); launchReleaseCounts.append(releases)
            if let activationError { throw activationError }
            return NativeApplicationLaunch(bundleID: text, pid: launchPID)
        }
        return nil
    }
    func registerAgent(owner: UUID, session: UUID) { reservations += 1 }
    func agentCapture(owner: UUID, session: UUID) async throws -> Data { captures += 1; if let captureError { throw captureError }; return png }
    func agentTap(owner: UUID, session: UUID, x: UInt16, y: UInt16, validate: () throws -> Void) async throws { if let inputDelay { try await Task.sleep(for: inputDelay) }; try validate(); taps += 1 }
    func agentDrag(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, validate: () throws -> Void) async throws { try validate(); drags = [fromX, fromY, toX, toY, durationMS] }
    func releaseAgent(owner: UUID, session: UUID) { releases += 1 }
}

@MainActor final class CoreDeviceTestLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    func report(completed: Int, subtitle: String) {}
    func complete(success: Bool) {}
}
@MainActor final class CoreDeviceTestScheduler: RunBackgroundScheduler {
    let lease = CoreDeviceTestLease()
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws { launched(lease) }
    func cancel(identifier: String) {}
}

/// Manual monotonic clock: exercise ten-minute boundaries without real waits.
@MainActor final class MediaIdleClock {
    var instant = ContinuousClock.now
    var sleeps: [(Duration, CheckedContinuation<Void, Never>)] = []
    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { sleeps.append((duration, $0)) }
    }
    func fire(_ index: Int) { sleeps[index].1.resume() }
}
