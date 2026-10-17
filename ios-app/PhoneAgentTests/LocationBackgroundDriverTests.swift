import XCTest
import CoreLocation
@testable import PhoneAgent

@MainActor private final class FakeLocationManager: LocationManaging {
    var authorization: CLAuthorizationStatus = .authorizedWhenInUse
    var servicesEnabled = true, reducedAccuracy = true
    var onEvent: ((LocationEvent) -> Void)?
    var starts = 0, stops = 0, requests = 0
    func start() { starts += 1 }
    func stop() { stops += 1; onEvent = nil }
    func requestWhenInUse() { requests += 1 }
}
@MainActor final class LocationBackgroundDriverTests: XCTestCase {
    func testEvidenceRequiresFreshValidSampleAndStationaryDoesNotExpire() {
        let registry = BackgroundExecutionRegistry(), manager = FakeLocationManager()
        let now = Date(), driver = LocationBackgroundDriver(registry: registry, configured: true, factory: { manager }, clock: { now })
        XCTAssertEqual(manager.starts, 0)
        driver.setDemand(true, foreground: false); XCTAssertEqual(manager.starts, 0)
        driver.setDemand(true, foreground: true); XCTAssertEqual(manager.starts, 1); XCTAssertFalse(registry.active)
        for sample in [LocationEvidence(timestamp: now.addingTimeInterval(-1), accuracy: 1), .init(timestamp: now, accuracy: -1), .init(timestamp: now, accuracy: .infinity), .init(timestamp: now.addingTimeInterval(1), accuracy: 1)] {
            manager.onEvent?(.evidence([sample])); XCTAssertFalse(registry.active)
        }
        manager.onEvent?(.evidence([.init(timestamp: now, accuracy: 100)])); XCTAssertTrue(registry.active)
        driver.setDemand(true, foreground: false)
        XCTAssertTrue(registry.active); XCTAssertEqual(manager.starts, 1)
        manager.onEvent?(.unavailable); XCTAssertFalse(registry.active); XCTAssertEqual(manager.starts, 1)
        manager.onEvent?(.evidence([.init(timestamp: now, accuracy: 10)])); XCTAssertTrue(registry.active)
        manager.onEvent?(.paused); XCTAssertFalse(registry.active)
        driver.setDemand(true, foreground: false); XCTAssertEqual(manager.starts, 1)
        driver.setDemand(false, foreground: true)
    }
    func testOldCallbackAndAuthorizationAfterStopCannotReviveDemand() {
        let registry = BackgroundExecutionRegistry(), manager = FakeLocationManager()
        let now = Date(), driver = LocationBackgroundDriver(registry: registry, configured: true, factory: { manager }, clock: { now })
        driver.setDemand(true, foreground: true)
        let late = manager.onEvent
        driver.setDemand(false, foreground: true)
        late?(.evidence([.init(timestamp: now, accuracy: 1)])); XCTAssertFalse(registry.active)
        XCTAssertEqual(driver.state, .stopped)
    }
    func testPermissionGateNeverChainsAndBackgroundAuthorizationWaitsForForeground() {
        let registry = BackgroundExecutionRegistry(), manager = FakeLocationManager(), gate = PermissionRequestGate()
        manager.authorization = .notDetermined
        let driver = LocationBackgroundDriver(registry: registry, configured: true, factory: { manager }, gate: gate)
        driver.setDemand(true, foreground: true)
        XCTAssertEqual(manager.requests, 0)
        let other = gate.acquire()!; XCTAssertNil(gate.acquire()); gate.release(other)
        driver.requestPermission(gateToken: gate.acquire()!)
        XCTAssertEqual(manager.requests, 1); XCTAssertNil(gate.acquire())
        driver.setDemand(true, foreground: false)
        manager.authorization = .authorizedWhenInUse; manager.onEvent?(.authorization)
        XCTAssertEqual(manager.starts, 0); XCTAssertEqual(driver.state, .waitingForForeground)
        driver.setDemand(true, foreground: true); XCTAssertEqual(manager.starts, 1); XCTAssertFalse(registry.active)
        driver.setDemand(false, foreground: true)
    }
    func testPermissionCompletionFromEndedDemandCannotStartNewDemand() {
        let manager = FakeLocationManager(), gate = PermissionRequestGate()
        manager.authorization = .notDetermined
        let driver = LocationBackgroundDriver(registry: BackgroundExecutionRegistry(), configured: true, factory: { manager }, gate: gate)
        driver.setDemand(true, foreground: true); driver.requestPermission(gateToken: gate.acquire()!)
        driver.setDemand(false, foreground: true)
        XCTAssertNil(gate.acquire(), "visible system prompt still owns the gate")
        driver.setDemand(true, foreground: true)
        manager.authorization = .authorizedWhenInUse; manager.onEvent?(.authorization)
        XCTAssertEqual(manager.starts, 0, "old completion is not a new start command")
        driver.setDemand(false, foreground: true)
        let token = gate.acquire(); XCTAssertNotNil(token); if let token { gate.release(token) }
    }
    func testDeniedRestrictedDisabledAndMissingConfigurationNeverStartOrPrompt() {
        for authorization in [CLAuthorizationStatus.denied, .restricted, .notDetermined] {
            let manager = FakeLocationManager(); manager.authorization = authorization
            let driver = LocationBackgroundDriver(registry: BackgroundExecutionRegistry(), configured: true, factory: { manager })
            driver.setDemand(true, foreground: true)
            XCTAssertEqual(manager.starts, 0); XCTAssertEqual(manager.requests, 0)
        }
        let manager = FakeLocationManager()
        let invalid = LocationBackgroundDriver(registry: BackgroundExecutionRegistry(), configured: false, factory: { manager })
        invalid.setDemand(true, foreground: true); XCTAssertEqual(manager.starts, 0)
        manager.servicesEnabled = false
        let disabled = LocationBackgroundDriver(registry: BackgroundExecutionRegistry(), configured: true, factory: { manager })
        disabled.setDemand(true, foreground: true); XCTAssertEqual(manager.starts, 0)
    }
    func testRevocationRemovesOnlyLocationAndAllowOnceIsNotPersisted() {
        let registry = BackgroundExecutionRegistry(), manager = FakeLocationManager(), now = Date()
        let audio = BackgroundSourceToken(mechanism: .audio, owner: UUID()); registry.publish(audio)
        let driver = LocationBackgroundDriver(registry: registry, configured: true, factory: { manager }, clock: { now })
        driver.setDemand(true, foreground: true); manager.onEvent?(.evidence([.init(timestamp: now, accuracy: 1)]))
        manager.authorization = .denied; manager.onEvent?(.authorization)
        XCTAssertEqual(registry.effectiveSources(allowed: [.audio, .location]), [.audio])
        manager.authorization = .notDetermined
        let restart = LocationBackgroundDriver(registry: registry, configured: true, factory: { manager })
        restart.setDemand(true, foreground: true); XCTAssertEqual(manager.requests, 0)
        XCTAssertEqual(manager.starts, 1)
    }
}
