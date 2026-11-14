import XCTest
import UIKit
import ProviderCore
@testable import PhoneAgent

@MainActor final class RemoteCoreDeviceTests: XCTestCase {
    func testRemoteAdmissionReportsSpecificControlFailureWithoutReserving() throws {
        let connection = CoreDeviceConnectionSpy()
        for code in ["control_busy", "control_reserved"] {
            connection.ready = true
            connection.running = code == "control_busy"
            connection.agentReserved = code == "control_reserved"
            XCTAssertThrowsError(try CoreDeviceBridge(flow: connection, remoteExclusive: true)) { error in
                XCTAssertEqual((error as? CoreDeviceAdmissionError)?.code, code)
            }
            XCTAssertEqual(connection.reservations, 0)
        }
    }

    func testMuseStartsBackgroundDemandBeforeRecoveringControlConnection() async throws {
        let background = BackgroundExecutionCoordinator.testing(selection: [.audio])
        let connection = CoreDeviceConnectionSpy()
        connection.ready = false; connection.allowsConnectionWait = true
        connection.connectionDelay = .milliseconds(70)
        var stages: [String] = []
        connection.onConnect = { XCTAssertEqual(background.desired, [.audio]) }
        let model = AgentViewModel(loadPersistentState: false, backgroundCoordinator: background, makeRemoteBridge: {
            try CoreDeviceBridge(flow: connection, connectionTimeout: .seconds(1), remoteExclusive: true,
                                connectionDiagnostic: { stages.append($0) })
        })
        model.setForeground(false)
        let runtime = try model.acquireRemoteRun("recover", onImage: { _ in XCTFail("App listing must not capture") }, onStop: {})
        XCTAssertEqual(connection.connectionAttempts, 0)
        XCTAssertEqual(background.desired, [.audio])
        let receipt = BackgroundSourceToken(mechanism: .audio, owner: UUID())
        background.registry.publish(receipt)
        let result = try await runtime.executeRemoteTool(name: "list_apps", arguments: [:], callID: "apps", imageID: nil, deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(result.kind, .returned, result.content)
        XCTAssertEqual(connection.appQueries, 1)
        XCTAssertEqual(connection.reservations, 1)
        XCTAssertEqual(stages, ["control.connection_wait", "control.connection_ready"])
        runtime.stop(message: "Synthetic completion")
        await runtime.waitForRemoteRelease(); model.releaseRemoteRun("recover")
        XCTAssertEqual(background.desired, [.audio], "Between-invocation demand keeps the selected source alive")
        model.endRemoteContinuity(); background.registry.revoke(receipt)
        XCTAssertTrue(background.desired.isEmpty)
    }

    func testRemoteWaitsForInFlightSetupButDoesNotCaptureAnotherController() async throws {
        let connection = CoreDeviceConnectionSpy()
        connection.ready = false; connection.running = true; connection.allowsConnectionWait = true
        let bridge = try CoreDeviceBridge(flow: connection, connectionTimeout: .seconds(1), remoteExclusive: true)
        let waiting = Task { try await bridge.installedApplications() }
        while connection.connectionAttempts == 0 { await Task.yield() }
        connection.running = false; connection.agentReserved = true; connection.ready = true
        do { _ = try await waiting.value; XCTFail("Another controller owns the ready session") }
        catch { XCTAssertEqual((error as? CoreDeviceAdmissionError)?.code, "control_reserved") }
        XCTAssertEqual(connection.reservations, 0)
        XCTAssertEqual(connection.appQueries, 0)
        await bridge.stop()
    }

    func testMuseRemoteTaskPolicyExecutesConsecutiveInputsAndStillStops() async throws {
        XCTAssertEqual(MuseCompanionAuthorization.inputMode, .task)
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        var frameID: String?
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
            onImage: { frame, _ in frameID = frame.id }, onReceipt: { _ in },
            authorizationMode: MuseCompanionAuthorization.inputMode)
        let deadline = Date().addingTimeInterval(20)
        _ = try await coordinator.executeRemote(name: "screenshot", parameters: [:], callID: "frame", expectedImageID: nil, deadline: deadline)
        for index in 0..<2 {
            let result = try await coordinator.executeRemote(name: "tap", parameters: ["x": 2, "y": 3, "description": "Muse action"],
                callID: "tap\(index)", expectedImageID: frameID, deadline: deadline)
            XCTAssertEqual(result.kind, .returned, result.content)
        }
        XCTAssertEqual(connection.taps, 2)
        await coordinator.stop()
        do {
            _ = try await coordinator.executeRemote(name: "home", parameters: ["description": "stopped"],
                callID: "stopped", expectedImageID: nil, deadline: deadline)
            XCTFail("Stopped Muse execution must not dispatch")
        } catch { XCTAssertEqual(error as? AppError, .stopped) }
        XCTAssertTrue(connection.systemActions.isEmpty)
    }

    func testRemoteGeometryRecheckedAtDispatchAndExpiredFramesRejected() async throws {
        let connection = CoreDeviceConnectionSpy(); connection.geometryToken = "epoch1:revision1:crop1"
        let bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.validateRemoteObservation(frame)
        try await bridge.acceptApproval(imageID: frame.id)
        connection.geometryToken = "epoch2:revision2:crop2"
        do { try await bridge.tap(x: 100, y: 100, imageID: frame.id); XCTFail("Changed geometry must not dispatch") }
        catch { XCTAssertNotNil(error as? AppError) }
        XCTAssertEqual(connection.taps, 0)
        XCTAssertEqual(connection.geometryChecks, 2)
        XCTAssertEqual(connection.captures, 1, "Validation must only read cached geometry")
        let expired = FrameImage(id: frame.id, png: frame.png, width: frame.width, height: frame.height,
            capturedAt: Date().addingTimeInterval(-61), isDemo: false, remoteGeometryToken: connection.geometryToken)
        do { try await bridge.validateRemoteObservation(expired); XCTFail("Expired frame must fail") }
        catch { XCTAssertNotNil(error as? AppError) }
        XCTAssertEqual(connection.geometryChecks, 2, "TTL is checked before backend access")
        await bridge.stop()
    }

    func testRemoteGeometryFailsClosedWithoutBackendMetadata() async throws {
        let connection = CoreDeviceConnectionSpy()
        let bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        do { try await bridge.validateRemoteObservation(frame); XCTFail("Missing metadata must fail closed") }
        catch { XCTAssertNotNil(error as? AppError) }
        XCTAssertEqual(connection.captures, 1, "Validation never requests a screenshot")
        XCTAssertEqual(connection.taps, 0)
        await bridge.stop()
    }

    func testRemoteDeadlineCheckedAfterInputPreparationSuspends() async throws {
        let connection = CoreDeviceConnectionSpy()
        let bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.acceptApproval(imageID: frame.id)
        try await bridge.setRemoteDeadline(Date().addingTimeInterval(0.05))
        connection.inputDelay = .milliseconds(100)
        do { try await bridge.tap(x: 100, y: 100, imageID: frame.id); XCTFail("Expired input must not dispatch") }
        catch { XCTAssertEqual(error as? AppError, .stopped) }
        XCTAssertEqual(connection.taps, 0)
        await bridge.stop()
    }

    func testRemotePastDeadlineRejectedBeforeDispatch() async throws {
        let connection = CoreDeviceConnectionSpy()
        let bridge = try CoreDeviceBridge(flow: connection)
        do { try await bridge.setRemoteDeadline(Date().addingTimeInterval(-1)); XCTFail("Must reject expired deadline") }
        catch { XCTAssertEqual(error as? AppError, .stopped) }
        XCTAssertEqual(connection.taps, 0); XCTAssertEqual(connection.captures, 0)
        await bridge.stop()
    }

    func testRemoteConnectionWaitReportsBoundedTimeout() async throws {
        let absent = CoreDeviceConnectionSpy()
        absent.ready = false; absent.allowsConnectionWait = true
        let waiting = try CoreDeviceBridge(flow: absent, connectionTimeout: .milliseconds(120), remoteExclusive: true)
        do { _ = try await waiting.screenshot(); XCTFail("Expected bounded timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("连接超时")) }
        XCTAssertEqual(absent.captures, 0)
        await waiting.stop()
    }

    func testExplicitStopInterruptsConnectionWaitWithoutDispatch() async throws {
        let connection = CoreDeviceConnectionSpy()
        connection.ready = false; connection.allowsConnectionWait = true
        let bridge = try CoreDeviceBridge(flow: connection, connectionTimeout: .seconds(2), remoteExclusive: true)
        let waiting = Task { try await bridge.installedApplications() }
        while connection.connectionAttempts == 0 { await Task.yield() }
        await bridge.stop()
        do { _ = try await waiting.value; XCTFail("Stopped waiter must not dispatch") }
        catch { XCTAssertEqual(error as? AppError, .stopped) }
        XCTAssertEqual(connection.appQueries, 0)
    }

    func testServiceStopInterruptsWaitWithoutStartingAnotherConnection() async throws {
        let connection = CoreDeviceConnectionSpy()
        connection.ready = false; connection.allowsConnectionWait = true
        let bridge = try CoreDeviceBridge(flow: connection, connectionTimeout: .seconds(2), remoteExclusive: true)
        let waiting = Task { try await bridge.installedApplications() }
        while connection.connectionAttempts == 0 { await Task.yield() }
        connection.connectionStopID = UUID()
        do { _ = try await waiting.value; XCTFail("Service stop must interrupt wait") }
        catch { XCTAssertTrue(error.localizedDescription.contains("连接等待已停止")) }
        XCTAssertEqual(connection.connectionAttempts, 1); XCTAssertEqual(connection.appQueries, 0)
        await bridge.stop()
    }

    func testMuseMediaReuseReleasesOwnersRefreshesOnlyBusinessUseAndExpiresAtTenMinutes() async throws {
        let clock = MediaIdleClock()
        let lifetime = ControlMediaLifetime(now: { clock.instant }, sleep: { await clock.sleep($0) })
        var starts = 0, stops = 0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let flow = DeviceControlCoordinator(store: RemotePairRecordStore(url: url), mediaLifetime: lifetime,
            startMedia: { _ in starts += 1 }, stopMedia: { _ in stops += 1 })
        flow.ready = true
        let session = flow.controlSessionID, retention = flow.mediaRetentionGeneration
        func use(_ owner: UUID) async throws {
            flow.registerAgent(owner: owner, session: session)
            try await flow.agentOperation(owner: owner, session: session) { try await flow.prepareAgentInput($0) }
            flow.finishRemoteAgent(owner: owner, session: session, retentionGeneration: retention)
            await flow.mediaLifetimeWait() // Does NOT wait for the idle grace.
        }
        try await use(UUID())
        XCTAssertFalse(flow.agentReserved); XCTAssertFalse(flow.running)
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 0)
        let firstExpiry = try XCTUnwrap(lifetime.idleUntil)
        XCTAssertEqual(clock.instant.duration(to: firstExpiry), .seconds(600))
        for _ in 0..<20 { await Task.yield() }
        clock.instant = clock.instant.advanced(by: .seconds(599))
        try await use(UUID())
        XCTAssertEqual(starts, 1, "Warm calls reuse video/HID")
        XCTAssertEqual(lifetime.idleUntil, clock.instant.advanced(by: .seconds(600)))
        for _ in 0..<20 { await Task.yield() }
        clock.fire(0) // Old timer wakes after the renewed business use.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(stops, 0)
        let expiry = lifetime.idleUntil
        clock.instant = clock.instant.advanced(by: .seconds(10))
        let readOwner = UUID()
        flow.registerAgent(owner: readOwner, session: session)
        let _: Int = try await flow.agentOperation(owner: readOwner, session: session) { _ in 1 }
        flow.finishRemoteAgent(owner: readOwner, session: session, retentionGeneration: retention)
        XCTAssertEqual(lifetime.idleUntil, expiry, "Non-media work cannot extend the idle window")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(clock.sleeps.last?.0, .seconds(590))
        clock.fire(1)
        clock.instant = try XCTUnwrap(expiry)
        clock.fire(2)
        for _ in 0..<20 { await Task.yield() }
        await flow.mediaLifetimeWait()
        XCTAssertEqual(stops, 1); XCTAssertFalse(lifetime.active)
        XCTAssertTrue(flow.ready); XCTAssertEqual(flow.controlSessionID, session)
    }

    func testMuseHintNeverReleasesRegisteredOrQueuedLocalRunAndStopIsSerialized() async throws {
        let lifetime = ControlMediaLifetime()
        var stops = 0
        var stopGate: CheckedContinuation<Void, Never>?
        let flow = DeviceControlCoordinator(store: RemotePairRecordStore(url: .temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            mediaLifetime: lifetime, startMedia: { _ in }, stopMedia: { _ in
                stops += 1; await withCheckedContinuation { stopGate = $0 }
            })
        flow.ready = true
        let session = flow.controlSessionID, remote = UUID(), local = UUID(), queued = UUID()
        flow.registerAgent(owner: remote, session: session)
        try await flow.agentOperation(owner: remote, session: session) { try await flow.prepareAgentInput($0) }
        flow.registerAgent(owner: local, session: session)
        let next = Task { try await flow.agentOperation(owner: local, session: session) { _ in 42 } }
        for _ in 0..<20 { await Task.yield() }
        flow.finishRemoteAgent(owner: remote, session: session, retentionGeneration: flow.mediaRetentionGeneration)
        XCTAssertFalse(flow.releaseIdleMuseMedia())
        let value = try await next.value; XCTAssertEqual(value, 42)
        flow.registerAgent(owner: queued, session: session)
        flow.releaseAgent(owner: local, session: session)
        XCTAssertFalse(flow.releaseIdleMuseMedia()); XCTAssertEqual(stops, 0)
        flow.releaseAgent(owner: queued, session: session)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(flow.mediaStopping); XCTAssertEqual(stops, 1)
        // A new Muse run can reserve its own execution scope while native STOP
        // finishes. It must not report busy or bind the stopping media session.
        let bridge = try CoreDeviceBridge(flow: flow, remoteExclusive: true)
        let read = Task { try await bridge.installedApplications() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(flow.agentReserved)
        stopGate?.resume(); stopGate = nil
        _ = try? await read.value // Native app query has no backend in this fixture.
        await bridge.stop()
        XCTAssertEqual(stops, 1)
    }

    func testExplicitStopGenerationPreventsLateNormalCompletionFromRetainingMedia() async throws {
        let lifetime = ControlMediaLifetime()
        var stops = 0
        let flow = DeviceControlCoordinator(store: RemotePairRecordStore(url: .temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            mediaLifetime: lifetime, startMedia: { _ in }, stopMedia: { _ in stops += 1 })
        flow.ready = true
        let owner = UUID(), session = flow.controlSessionID, old = flow.mediaRetentionGeneration
        flow.registerAgent(owner: owner, session: session)
        try await flow.agentOperation(owner: owner, session: session) { try await flow.prepareAgentInput($0) }
        flow.revokeMuseMediaRetention()
        XCTAssertEqual(stops, 0, "Revocation cannot tear down active input")
        flow.finishRemoteAgent(owner: owner, session: session, retentionGeneration: old)
        await flow.mediaLifetimeWait()
        XCTAssertEqual(stops, 1); XCTAssertNil(lifetime.idleUntil)
        XCTAssertFalse(flow.agentReserved); XCTAssertTrue(flow.ready)
    }

    func testIdleHintIsIdempotentAndOldGenerationTimerCannotCloseNewMedia() async {
        let clock = MediaIdleClock()
        let lifetime = ControlMediaLifetime(now: { clock.instant }, sleep: { await clock.sleep($0) })
        var expired = 0
        lifetime.didOpen(); lifetime.refreshMuseIdle(); lifetime.scheduleIdle { expired += 1 }
        for _ in 0..<20 { await Task.yield() }
        lifetime.revoke(); lifetime.didOpen()
        clock.fire(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(expired, 0); XCTAssertTrue(lifetime.active)
        XCTAssertNil(lifetime.idleUntil)
    }

    func testCancelledIdleHintWaitDoesNotCancelNativeStopOrNextRun() async throws {
        let lifetime = ControlMediaLifetime()
        var starts = 0, stops = 0
        var gate: CheckedContinuation<Void, Never>?
        let flow = DeviceControlCoordinator(store: RemotePairRecordStore(url: .temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            mediaLifetime: lifetime, startMedia: { _ in starts += 1 }, stopMedia: { _ in
                stops += 1; await withCheckedContinuation { gate = $0 }
            })
        flow.ready = true
        let session = flow.controlSessionID, old = UUID()
        flow.registerAgent(owner: old, session: session)
        try await flow.agentOperation(owner: old, session: session) { try await flow.prepareAgentInput($0) }
        flow.finishRemoteAgent(owner: old, session: session, retentionGeneration: flow.mediaRetentionGeneration)
        let hint = Task { await flow.releaseIdleMuseMediaAndWait() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(stops, 1); XCTAssertTrue(flow.mediaStopping)
        XCTAssertFalse(flow.releaseIdleMuseMedia(), "Duplicate hints never start another STOP")
        hint.cancel() // Simulates the caller giving up its HTTP response wait.
        let owner = UUID()
        let next = Task {
            await flow.mediaLifetimeWait()
            flow.registerAgent(owner: owner, session: session)
            try await flow.agentOperation(owner: owner, session: session) { try await flow.prepareAgentInput($0) }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(starts, 1)
        gate?.resume(); gate = nil
        _ = await hint.value
        try await next.value
        XCTAssertEqual(starts, 2); XCTAssertEqual(stops, 1)
        XCTAssertTrue(flow.ready); XCTAssertTrue(lifetime.active); XCTAssertTrue(flow.agentReserved)
        flow.finishRemoteAgent(owner: owner, session: session, retentionGeneration: flow.mediaRetentionGeneration)
        flow.cancel()
    }
}
