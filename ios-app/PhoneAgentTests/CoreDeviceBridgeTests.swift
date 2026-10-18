import XCTest
import ImageIO
import CoreImage
import CoreVideo
import UIKit
import ProviderCore
@testable import PhoneAgent

@MainActor private final class CoreDeviceConnectionSpy: CoreDeviceControlConnection {
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
    var geometryError: Error?
    var geometryChecks = 0
    func agentInputGeometry(owner: UUID, session: UUID) async throws -> String {
        if let geometryError { throw geometryError }
        guard let geometryToken else { throw RemoteRPCError("geometry_unavailable", "No synthetic geometry") }
        return geometryToken
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
    func agentSystemAction(owner: UUID, session: UUID, name: String, text: String, arguments: [String], validate: () throws -> Void) async throws {
        try validate(); systemActions.append(name)
        if name == "launch_app" {
            launchedBundles.append(text); launchReleaseCounts.append(releases)
            if let activationError { throw activationError }
        }
    }
    func registerAgent(owner: UUID, session: UUID) { reservations += 1 }
    func agentCapture(owner: UUID, session: UUID) async throws -> Data { captures += 1; if let captureError { throw captureError }; return png }
    func agentTap(owner: UUID, session: UUID, x: UInt16, y: UInt16, validate: () throws -> Void) async throws { if let inputDelay { try await Task.sleep(for: inputDelay) }; try validate(); taps += 1 }
    func agentDrag(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, validate: () throws -> Void) async throws { try validate(); drags = [fromX, fromY, toX, toY, durationMS] }
    func releaseAgent(owner: UUID, session: UUID) { releases += 1 }
}

@MainActor private final class CoreDeviceTestLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    func report(completed: Int, subtitle: String) {}
    func complete(success: Bool) {}
}
@MainActor private final class CoreDeviceTestScheduler: RunBackgroundScheduler {
    let lease = CoreDeviceTestLease()
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws { launched(lease) }
    func cancel(identifier: String) {}
}

@MainActor final class CoreDeviceBridgeTests: XCTestCase {
    func testGeometryFailurePreservesReasonWithoutInputAndCancellationIsNotRewritten() async throws {
        let flow = CoreDeviceConnectionSpy()
        let bridge = try CoreDeviceBridge(flow: flow)
        flow.geometryError = NativeInputGeometryError(.metadataQuery, stage: 11, cause: 2)
        do { _ = try await bridge.inputDisplaySnapshot(); XCTFail("Expected metadata failure") }
        catch {
            let failure = try XCTUnwrap(error as? RemoteRPCError)
            XCTAssertEqual(failure.code, "geometry_unavailable")
            XCTAssertEqual(failure.diagnosticFields["geometry_reason"], "metadata_query")
            XCTAssertEqual(failure.diagnosticFields["native_cause"], "2")
        }
        flow.geometryError = CancellationError()
        do { _ = try await bridge.inputDisplaySnapshot(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(flow.taps, 0); XCTAssertEqual(flow.captures, 0)
        await bridge.stop()
    }

    func testReadOnlyGeometryFailureRetainsFlowButClosedTransportRevokesIt() async throws {
        let flow = PairingFlow(), owner = UUID()
        flow.ready = true
        let session = flow.controlSessionID
        flow.registerAgent(owner: owner, session: session)
        for reason: NativeInputGeometryError.Reason in [.metadataQuery, .metadataInvalid, .decoderUnavailable, .decoderFailed, .sizeMismatch, .framePending, .generationChanged, .streamChanged] {
            let failure = NativeInputGeometryError(reason)
            do {
                let _: Void = try await flow.agentOperation(owner: owner, session: session) { _ in throw failure }
                XCTFail("Expected geometry failure")
            } catch { XCTAssertEqual(error as? NativeInputGeometryError, failure) }
            XCTAssertTrue(flow.ready)
            XCTAssertEqual(flow.controlSessionID, session)
            XCTAssertFalse(flow.running)
            let next = try await flow.agentOperation(owner: owner, session: session) { _ in 42 }
            XCTAssertEqual(next, 42)
            XCTAssertNil(flow.lastFailure)
        }
        do {
            let _: Void = try await flow.agentOperation(owner: owner, session: session) { _ in
                throw NativeBackendError.protocolFailure(stage: 12, cause: 5)
            }
            XCTFail("Closed transport must fail")
        } catch {}
        XCTAssertFalse(flow.ready)
        XCTAssertNotEqual(flow.controlSessionID, session)
    }

    func testIndependentInputUsesGeometryWithoutCaptureAndConsumesGrant() async throws {
        let flow = CoreDeviceConnectionSpy(); flow.geometryToken = "first"
        let bridge = try CoreDeviceBridge(flow: flow)
        let snapshot = try await bridge.inputDisplaySnapshot()
        try await bridge.authorizeIndependentInput(snapshot, authorizationID: "one")
        try await bridge.independentInput(name: "tap", coordinates: [32768, 65535], durationMS: 0, snapshot: snapshot, authorizationID: "one")
        XCTAssertEqual(flow.taps, 1)
        XCTAssertEqual(flow.captures, 0)
        do {
            try await bridge.independentInput(name: "tap", coordinates: [32768, 65535], durationMS: 0, snapshot: snapshot, authorizationID: "one")
            XCTFail("A consumed grant must not execute twice")
        } catch {}
        XCTAssertEqual(flow.taps, 1)
        await bridge.stop()
    }
    func testIndependentGeometryChangesRejectBeforeInput() async throws {
        let flow = CoreDeviceConnectionSpy(); flow.geometryToken = "first"
        let bridge = try CoreDeviceBridge(flow: flow)
        let snapshot = try await bridge.inputDisplaySnapshot()
        flow.geometryToken = "second"
        do { try await bridge.authorizeIndependentInput(snapshot, authorizationID: "changed"); XCTFail("Geometry changed") }
        catch { XCTAssertEqual((error as? RemoteRPCError)?.code, "geometry_changed") }
        let current = try await bridge.inputDisplaySnapshot()
        try await bridge.authorizeIndependentInput(current, authorizationID: "final")
        flow.geometryToken = "third" // Changes after authorization, at final native fence.
        do {
            try await bridge.independentInput(name: "tap", coordinates: [0, 0], durationMS: 0, snapshot: current, authorizationID: "final")
            XCTFail("Final geometry fence must reject")
        } catch {}
        XCTAssertEqual(flow.taps, 0)
        XCTAssertEqual(flow.captures, 0)
        await bridge.stop()
    }
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
        XCTAssertFalse(result.isError, result.result)
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
            let result = try await coordinator.executeRemote(name: "tap", parameters: ["x": 2, "y": 3, "purpose": "Muse action"],
                callID: "tap\(index)", expectedImageID: frameID, deadline: deadline)
            XCTAssertFalse(result.isError, result.result)
        }
        XCTAssertEqual(connection.taps, 2)
        await coordinator.stop()
        do {
            _ = try await coordinator.executeRemote(name: "home", parameters: ["purpose": "stopped"],
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

    func testCompletionActivationDoesNotCaptureReconnectOrCrossStopOrAnotherOwner() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        let activated = try await bridge.bringApplicationToForeground(bundleID: "com.ja1chen.PhoneAgent")
        XCTAssertTrue(activated)
        XCTAssertEqual(connection.launchedBundles, ["com.ja1chen.PhoneAgent"])
        XCTAssertEqual(connection.captures, 0); XCTAssertEqual(connection.connectionAttempts, 0)
        connection.agentReserved = true
        let busy = try await bridge.bringApplicationToForeground(bundleID: "com.ja1chen.PhoneAgent")
        XCTAssertFalse(busy)
        connection.agentReserved = false; connection.ready = false
        let absent = try await bridge.bringApplicationToForeground(bundleID: "com.ja1chen.PhoneAgent")
        XCTAssertFalse(absent)
        XCTAssertEqual(connection.connectionAttempts, 0)
        connection.ready = true; connection.controlSessionID = UUID()
        do { _ = try await bridge.bringApplicationToForeground(bundleID: "com.ja1chen.PhoneAgent"); XCTFail("Old generation activated") } catch {}
        await bridge.stop()
        do { _ = try await bridge.bringApplicationToForeground(bundleID: "com.ja1chen.PhoneAgent"); XCTFail("Stopped task activated") } catch {}
        XCTAssertEqual(connection.launchedBundles.count, 1)
    }
    func testBackgroundCompletionReturnsCorrectConversationBeforeReleaseEvenIfActivationFails() async throws {
        for activationFails in [false, true] {
            let connection = CoreDeviceConnectionSpy()
            if activationFails { connection.activationError = .timeout }
            let bridge = try CoreDeviceBridge(flow: connection)
            let lifecycle = RunLifecycleCoordinator(scheduler: CoreDeviceTestScheduler(), storage: MemoryRunCheckpointStore())
            let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                runServices: AgentRunServices(provider: DisconnectedChatProvider(requestsScreenshot: false), bridge: bridge), lifecycle: lifecycle)
            let id = model.createConversation(mode: .live)
            XCTAssertTrue(model.send("test", in: id, cloudConsent: true))
            let run = try XCTUnwrap(model.ownedRun)
            let other = model.createConversation(mode: .live)
            model.selectConversation(other)
            model.setForeground(false)
            for _ in 0..<200 {
                if !model.running { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.running)
            XCTAssertEqual(model.sessions.conversation(id)?.phase, .completed)
            XCTAssertEqual(model.activityNavigation?.route.sessionID, id)
            XCTAssertEqual(model.activityNavigation?.route.runID, run.runID)
            XCTAssertNil(model.activityNavigation?.messageID)
            XCTAssertEqual(connection.launchedBundles, [Bundle.main.bundleIdentifier!])
            XCTAssertEqual(connection.launchReleaseCounts, [0], "Activate before closing the device lease")
            XCTAssertEqual(connection.captures, 0)
            XCTAssertEqual(connection.releases, 1)
        }
    }

    func testWorkerCompletionPublishesNavigationOnAppOwner() async throws {
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServicesFactory: { _ in AgentRunServices(provider: DisconnectedChatProvider(requestsScreenshot: false), bridge: UnavailableBridge()) })
        let first = model.createConversation(mode: .live)
        let workerID = model.createConversation(mode: .live)
        let worker = model.executionModel(for: workerID)
        let presentation = AgentPresentationAdapter(model: model, sessionID: workerID)
        XCTAssertTrue(model.send("test", in: workerID, cloudConsent: true))
        model.selectConversation(first)
        for _ in 0..<200 {
            if !worker.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sessions.conversation(workerID)?.phase, .completed)
        XCTAssertEqual(model.activityNavigation?.route.sessionID, workerID)
        XCTAssertEqual(model.activityNavigation?.id, worker.activityNavigation?.id)
        XCTAssertEqual(presentation.activityNavigation?.id, model.activityNavigation?.id)
        let previous = model.activityNavigation?.id
        XCTAssertTrue(model.openActivityURL(try XCTUnwrap(model.activityNavigation?.route.url)))
        XCTAssertNotEqual(model.activityNavigation?.id, previous, "Repeated links issue another scroll request")
        XCTAssertEqual(presentation.activityNavigation?.id, model.activityNavigation?.id)
    }

    func testTransportStopIsToolErrorWhileExplicitRunStopRemainsCancellation() async throws {
        let connection = CoreDeviceConnectionSpy()
        let bridge = try CoreDeviceBridge(flow: connection)
        connection.captureError = .stopped
        do { _ = try await bridge.screenshot(); XCTFail("Expected connection error") }
        catch { guard case AppError.unavailable = error else { return XCTFail("Transport loss must not stop the Agent: \(error)") } }
        connection.captureError = nil
        _ = try await bridge.screenshot()
        await bridge.stop()
        do { _ = try await bridge.screenshot(); XCTFail("Explicit stop must cancel") }
        catch { XCTAssertEqual(error as? AppError, .stopped) }
    }

    @MainActor func testPredictiveVideoFrameUpdatesScreenshotWithoutInputOrNewKeyframe() async throws {
        // Synthetic green IDR followed by blue P-frame, encoded with libx265.
        var first = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGwAAAEABDAH//wFgAAADAJAAAAMAAAMAHpKAkEIBAQFgAAADAJAAAAMAAAMAHqAggYWWSpJMrwFoCAAAAwAIAAADAAhARAHBcrQiQAAAABcoAa8TgOUyUf/ySo/+t9X+gGtACCMdhw==")!
        let second = Data(base64Encoded: "AgAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAAAAAEAAAABgAAAAGAAAACkAAAAHAAAAIAAAAEABDAH//wFgAAADAJAAAAMAAAMAHpKAkEIBAQFgAAADAJAAAAMAAAMAHqAggYWWSpJMrwFoCAAAAwAIAAADAAhARAHBcrQiQAAAABwCAdAJfik2BHDwBOmDhifhmQd71Nsf/55oTwLA")!
        let original = try CoreDeviceVideoSample(first)
        let nalOffset = 64 + original.parameters.reduce(0) { $0 + $1.count }
        first[nalOffset + 3] += 14
        first.append(contentsOf: [0,64,0,96,0,0,3,0,0,0,62,0,94,3])
        var size = UInt32(original.bytes.count + 14).littleEndian
        withUnsafeBytes(of: &size) { first.replaceSubrange(60..<64, with: $0) }
        XCTAssertFalse(try CoreDeviceVideoSample(second).sync)
        let decoder = CoreDeviceVideoDecoder()
        try await decoder.consume(first)
        let initial = try await decoder.jpeg(notBefore: .now.advanced(by: .seconds(-1)))
        let green = try XCTUnwrap(initial)
        try await Task.sleep(for: .milliseconds(1100))
        try await decoder.consume(second)
        let updated = try await decoder.jpeg(notBefore: .now.advanced(by: .seconds(-1)))
        let blue = try XCTUnwrap(updated)
        XCTAssertNotEqual(green, blue, "A P-frame must update the screenshot without input or another keyframe")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(blue as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width,62); XCTAssertEqual(image.height,94, "Content geometry persists when later P-frames omit the trailer")
    }
    func testDisplayServiceTrailerDeclaresCanvasAndContentWithoutExternalScreenSize() throws {
        func picture(_ suffix: [UInt8]) -> Data {
            let nal: [UInt8] = [0x26, 1, 0xaa, 0xbb] + suffix
            let n = UInt32(nal.count).bigEndian
            var data = withUnsafeBytes(of: n) { Data($0) }; data.append(contentsOf: nal); return data
        }
        // Existing captured upstream fixture, previously hardcoded as a suffix to discard.
        let observed: [UInt8] = [0x04,0xf0,0x0a,0xc0,0,0,3,0,0,0x04,0xec,0x0a,0xb0,3]
        let parsed = try CoreDeviceDisplayPicture(picture(observed), codedWidth: 1264, codedHeight: 2752)
        XCTAssertEqual(parsed.visibleWidth,1260); XCTAssertEqual(parsed.visibleHeight,2736)
        XCTAssertEqual(parsed.bytes, Data([0,0,0,4,0x26,1,0xaa,0xbb]))
        let phone: [UInt8] = [0x04,0xa0,0x0a,0x10,0,0,3,0,0,0x04,0x9b,0x09,0xfc,3]
        let current = try CoreDeviceDisplayPicture(picture(phone), codedWidth: 1184, codedHeight: 2576)
        XCTAssertEqual(current.visibleWidth,1179); XCTAssertEqual(current.visibleHeight,2556)
        // A coincidental suffix from another canvas must remain untouched.
        let mismatch = try CoreDeviceDisplayPicture(picture(phone), codedWidth: 1280, codedHeight: 2592)
        XCTAssertNil(mismatch.visibleWidth); XCTAssertEqual(mismatch.bytes, picture(phone))
        var unknown = phone; unknown[4] = 1
        XCTAssertNil(try CoreDeviceDisplayPicture(picture(unknown), codedWidth: 1184, codedHeight: 2576).visibleWidth)
        XCTAssertThrowsError(try CoreDeviceDisplayPicture(Data([0,0,0,20,1]), codedWidth:1184, codedHeight:2576))
    }
    func testPreferredApertureOverridesFullFrameAndKeepsOffsets() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
            nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        let aperture = [kCVImageBufferCleanApertureWidthKey: 66,
                        kCVImageBufferCleanApertureHeightKey: 98,
                        kCVImageBufferCleanApertureHorizontalOffsetKey: -15,
                        kCVImageBufferCleanApertureVerticalOffsetKey: -9] as CFDictionary
        // Confirm offset interpretation against CoreVideo itself, then provide
        // only PreferredCleanAperture (ordinary clean rect remains full size).
        CVBufferSetAttachment(buffer, kCVImageBufferCleanApertureKey, aperture, .shouldPropagate)
        let expected = CVImageBufferGetCleanRect(buffer)
        XCTAssertEqual(expected, CGRect(x: 16, y: 24, width: 66, height: 98))
        CVBufferRemoveAttachment(buffer, kCVImageBufferCleanApertureKey)
        CVBufferSetAttachment(buffer, kCVImageBufferPreferredCleanApertureKey, aperture, .shouldPropagate)
        XCTAssertEqual(CVImageBufferGetCleanRect(buffer), CGRect(x: 0, y: 0, width: 128, height: 128))
        XCTAssertEqual(try CoreDeviceVideoImage.visibleRect(buffer: buffer, width: 128, height: 128,
            formatAperture: CGRect(x: 0, y: 0, width: 128, height: 128)), expected)
        // Invalid preferred geometry must never crop arbitrary pixels.
        CVBufferSetAttachment(buffer, kCVImageBufferPreferredCleanApertureKey,
            [kCVImageBufferCleanApertureWidthKey: 999, kCVImageBufferCleanApertureHeightKey: 98] as CFDictionary, .shouldPropagate)
        XCTAssertEqual(try CoreDeviceVideoImage.visibleRect(buffer: buffer, width: 128, height: 128),
            CGRect(x: 0, y: 0, width: 128, height: 128))
    }
    func testScreenshotCropsAlignedPaddingAndProducesOpaqueJPEG() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        let context = CIContext()
        let visible = CGRect(x: 0, y: 30, width: 66, height: 98)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: visible)
        context.render(green.composited(over: black), to: buffer)
        let rect = try CoreDeviceVideoImage.visibleRect(buffer: buffer, width: 66, height: 98)
        XCTAssertEqual(rect, visible)
        let jpeg = try CoreDeviceVideoImage.jpeg(buffer: buffer, rect: rect, context: context)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 66); XCTAssertEqual(image.height, 98)
        // All four corners must be actual picture pixels, not right/bottom allocation padding.
        var rgba = [UInt8](repeating: 0, count: 66 * 98 * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let bitmap = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 66, height: 98,
                bitsPerComponent: 8, bytesPerRow: 66 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: 66, height: 98))
        }
        for pixel in [0, 65, 97 * 66, 98 * 66 - 1] {
            XCTAssertGreaterThan(rgba[pixel * 4 + 1], 240)
            XCTAssertEqual(rgba[pixel * 4 + 3], 255)
        }
        XCTAssertThrowsError(try CoreDeviceVideoImage.visibleRect(buffer: buffer, width: 129, height: 98))
    }
    func testScreenshotRespectsDeclaredApertureOffset() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
            nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        let rect = try CoreDeviceVideoImage.visibleRect(buffer: buffer, width: 66, height: 98,
            formatAperture: CGRect(x: 16, y: 6, width: 66, height: 98))
        XCTAssertEqual(rect, CGRect(x: 16, y: 24, width: 66, height: 98))
    }
    func testScreenshotTimeoutReasonDistinguishesTransportAssemblyAndFreshness() {
        XCTAssertEqual(CoreDeviceVideoSnapshotFailure.timeoutCause(datagrams: 0, rtp: 0, frames: 0, overflows: 0), 8)
        XCTAssertEqual(CoreDeviceVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 0, frames: 0, overflows: 0), 9)
        XCTAssertEqual(CoreDeviceVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 4, frames: 0, overflows: 0), 10)
        XCTAssertEqual(CoreDeviceVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 4, frames: 1, overflows: 0), 11)
        XCTAssertEqual(CoreDeviceVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 4, frames: 1, overflows: 1), 12)
        XCTAssertEqual(CoreDeviceVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 4, frames: 1, overflows: 1, initialOverflows: 1), 11, "Historical overload must not label a later screenshot failure")
    }
    @MainActor func testIdleSnapshotRequiresConfirmedSerialAndEpoch() async throws {
        let bytes = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGgAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAggYWWVmkkyvAWgIAAAAMAgAAAAwCERAHBcrQiQAAAABYoAa8TgOUyUf/aKP+n1f6Aa0AIIx2H")!
        let decoder = CoreDeviceVideoDecoder()
        try await decoder.consume(bytes)
        let began = ContinuousClock.now.advanced(by: .seconds(2))
        let unconfirmed = try await decoder.jpeg(notBefore: began)
        XCTAssertNil(unconfirmed, "A stale image alone does not prove a live static screen")
        let confirmed = try await decoder.jpeg(notBefore: began, confirmedEpoch: 1, confirmedSerial: 1)
        XCTAssertNotNil(confirmed, "Sender-confirmed complete picture stays valid while static")
        let behind = try await decoder.jpeg(notBefore: began, confirmedEpoch: 1, confirmedSerial: 2)
        XCTAssertNil(behind, "Decoder must catch up to the peer confirmation")
        let otherEpoch = try await decoder.jpeg(notBefore: began, confirmedEpoch: 2, confirmedSerial: 1)
        XCTAssertNil(otherEpoch, "Confirmation cannot cross a reset")
        await decoder.reset()
        let reset = try await decoder.jpeg(notBefore: began, confirmedEpoch: 1, confirmedSerial: 1)
        XCTAssertNil(reset, "Reset pixels cannot satisfy an earlier confirmation")
    }
    @MainActor func testHEVCConformanceCropProducesExactVisibleScreenshotDimensions() async throws {
        let decoder = CoreDeviceVideoDecoder()
        let began = ContinuousClock.now
        try await decoder.consume(Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEIAAABiAAAAGAAAACsAAAAHAAAAJwAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAkgackmWVmkkyvAWgIAAADAAgAAAMACEBEAcFytCJAAAAAIygBrxOA5TJR//JKj/631f6Aa0AIRUTVT4gVgwAAAwAHGETA")!)
        let output = try await decoder.jpeg(notBefore: began)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(output) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 66); XCTAssertEqual(image.height, 98)
    }
    func testHEVCDecodeProducesJPEGAndResetRejectsPreviousFrame() async throws {
        // Synthetic 64x96 green frame, generated with FFmpeg/libx265; no device pixels.
        let bytes = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGgAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAggYWWVmkkyvAWgIAAAAMAgAAAAwCERAHBcrQiQAAAABYoAa8TgOUyUf/aKP+n1f6Aa0AIIx2H")!
        let sample = try CoreDeviceVideoSample(bytes)
        XCTAssertEqual(sample.width, 64); XCTAssertEqual(sample.height, 96)
        XCTAssertTrue(sample.sync)
        let decoder = CoreDeviceVideoDecoder()
        let began = ContinuousClock.now
        try await decoder.consume(bytes)
        let output = try await decoder.jpeg(notBefore: began)
        let jpeg = try XCTUnwrap(output)
        XCTAssertTrue(jpeg.starts(with: [0xff, 0xd8, 0xff]))
        XCTAssertEqual(FrameImage(id: "video", png: jpeg, width: 64, height: 96, capturedAt: Date(), isDemo: false).mimeType, "image/jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 96)
        let future = try await decoder.jpeg(notBefore: ContinuousClock.now)
        XCTAssertNil(future, "a previous frame must not satisfy a later screenshot")
        await decoder.reset()
        let cleared = try await decoder.jpeg(notBefore: began)
        XCTAssertNil(cleared)
        var malformed = bytes; malformed.removeLast()
        XCTAssertThrowsError(try CoreDeviceVideoSample(malformed))
    }
    func testExplicitPairingResetClearsStoredIdentityAndRevokesConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemotePairRecordStore(url: directory.appending(path: "identity.plist"))
        // Even an invalid/stale local record must have a recovery path.
        try Data("stale-fixture".utf8).write(to: store.url)
        let flow = PairingFlow(store: store)
        XCTAssertTrue(flow.hasRecord)
        flow.ready = true; flow.lastFailure = "fixture failure"
        let session = flow.controlSessionID
        flow.running = true; flow.resetPairing()
        XCTAssertTrue(store.exists, "Never reset during an operation")
        flow.running = false; flow.resetPairing()
        XCTAssertFalse(store.exists); XCTAssertFalse(flow.hasRecord); XCTAssertFalse(flow.ready)
        XCTAssertNil(flow.lastFailure); XCTAssertNotEqual(session, flow.controlSessionID)
        flow.resetPairing() // idempotent, idle and no network request
        XCTAssertFalse(flow.running)
    }
    func testBridgeCompletionWaitsForOwnedMediaCleanupBeforeReturning() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        _ = try await bridge.screenshot()
        connection.holdRelease = true
        var completed = false
        let stop = Task { await bridge.stop(); completed = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(connection.releases, 1)
        XCTAssertFalse(completed)
        XCTAssertNotNil(connection.releaseGate)
        connection.releaseGate?.resume()
        await stop.value
        XCTAssertTrue(completed)
        XCTAssertTrue(connection.ready)
        // A normal chat bridge never acquired device control and must not wait
        // for cleanup owned by a different control run.
        connection.releaseGate = nil
        let chat = try CoreDeviceBridge(flow: connection)
        completed = false
        let chatStop = Task { await chat.stop(); completed = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(completed)
        connection.releaseGate?.resume()
        await chatStop.value
    }
    func testControlMediaCleanupWaitsForLastOwnerAndCannotCompleteIntoNewGeneration() async {
        let lifetime = ControlMediaLifetime()
        lifetime.didOpen()
        var stops = 0, completions = 0
        var receipt: CheckedContinuation<Void, Never>?
        XCTAssertFalse(lifetime.finishIfIdle(hasUsers: true, stop: { stops += 1 }, completed: { _ in completions += 1 }))
        XCTAssertTrue(lifetime.active)
        XCTAssertTrue(lifetime.finishIfIdle(hasUsers: false, stop: {
            stops += 1
            await withCheckedContinuation { receipt = $0 }
        }, completed: { _ in completions += 1 }))
        XCTAssertFalse(lifetime.finishIfIdle(hasUsers: false, stop: { stops += 1 }, completed: { _ in completions += 1 }))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(stops, 1); XCTAssertTrue(lifetime.stopping)
        lifetime.revoke(); lifetime.didOpen()
        receipt?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(lifetime.active)
        XCTAssertFalse(lifetime.stopping)
        XCTAssertEqual(completions, 0, "old cleanup must not alter a newer control session")
        XCTAssertTrue(lifetime.finishIfIdle(hasUsers: false, stop: {}, completed: { success in
            XCTAssertTrue(success); completions += 1
        }))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(lifetime.active); XCTAssertEqual(completions, 1)
    }
    func testControlMediaCleanupFailureIsReportedAndTerminationRevokesAllOwners() async {
        let lifetime = ControlMediaLifetime()
        lifetime.didOpen()
        var result: Bool?
        XCTAssertTrue(lifetime.finishIfIdle(hasUsers: false, stop: { throw NativeBackendError.closed }, completed: { result = $0 }))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(result, false); XCTAssertFalse(lifetime.active)
        let flow = PairingFlow(), owner = UUID()
        flow.ready = true
        let session = flow.controlSessionID
        flow.registerAgent(owner: owner, session: session)
        flow.background()
        XCTAssertTrue(flow.ready)
        flow.applicationWillTerminate()
        XCTAssertFalse(flow.ready); XCTAssertFalse(flow.agentReserved)
        XCTAssertNotEqual(flow.controlSessionID, session)
    }
    func testScreenshotFailureRetainsFlowGenerationButUncertainInputRevokesIt() async throws {
        let flow = PairingFlow(), owner = UUID()
        flow.ready = true
        let session = flow.controlSessionID
        flow.registerAgent(owner: owner, session: session)
        do {
            let _: Void = try await flow.agentOperation(owner: owner, session: session) { _ in
                throw NativeBackendError.screenshotFailure(stage: 19, cause: 1)
            }
            XCTFail("expected screenshot failure")
        } catch {}
        XCTAssertTrue(flow.ready)
        XCTAssertEqual(flow.controlSessionID, session)
        XCTAssertFalse(flow.running)
        XCTAssertTrue(flow.lastFailure?.contains("截图服务连接失败") == true)
        let value = try await flow.agentOperation(owner: owner, session: session) { _ in 42 }
        XCTAssertEqual(value, 42)
        XCTAssertNil(flow.lastFailure)
        do {
            let _: Void = try await flow.agentOperation(owner: owner, session: session) { _ in
                throw NativeBackendError.protocolFailure(stage: 11, cause: 7)
            }
            XCTFail("expected uncertain input")
        } catch {}
        XCTAssertFalse(flow.ready)
        XCTAssertNotEqual(flow.controlSessionID, session)
        XCTAssertTrue(flow.lastFailure?.contains("发送结果未知") == true)
    }
    func testDisconnectedToolPreservesSpecificConnectionFailure() async throws {
        let connection = CoreDeviceConnectionSpy()
        connection.ready = false
        connection.connectionFailure = "连接保活失败：隧道已关闭"
        let bridge = try CoreDeviceBridge(flow: connection)
        do { _ = try await bridge.screenshot(); XCTFail("disconnected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("连接保活失败：隧道已关闭")) }
        XCTAssertEqual(connection.captures, 0)
        await bridge.stop()
    }
    func testApplicationQueryRebindsConnectionWithoutFrameButExplicitStopFencesIt() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        _ = try await bridge.installedApplications()
        XCTAssertEqual(connection.appQueries, 1)
        connection.controlSessionID = UUID()
        _ = try await bridge.installedApplications()
        XCTAssertEqual(connection.appQueries, 2)
        XCTAssertEqual(connection.captures, 0)
        await bridge.stop()
        do { _ = try await bridge.installedApplications(); XCTFail("explicit stop") } catch {}
        XCTAssertEqual(connection.appQueries, 2)
    }
    func testDeviceToolWaitsForConnectionAndReportsBoundedTimeout() async throws {
        let delayed = CoreDeviceConnectionSpy()
        delayed.ready = false; delayed.allowsConnectionWait = true; delayed.connectionDelay = .milliseconds(70)
        let bridge = try CoreDeviceBridge(flow: delayed, connectionTimeout: .seconds(1))
        _ = try await bridge.installedApplications()
        XCTAssertEqual(delayed.connectionAttempts, 1); XCTAssertEqual(delayed.appQueries, 1)
        XCTAssertEqual(delayed.captures, 0)
        await bridge.stop()
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
    func testReconnectInvalidatesOldCoordinateGrantButAllowsNewObservation() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.authorizeTaskInput(imageID: frame.id)
        connection.controlSessionID = UUID()
        do { try await bridge.tap(x: 1, y: 1, imageID: frame.id); XCTFail("Old coordinates cannot cross connection generations") } catch {}
        XCTAssertEqual(connection.taps, 0)
        let fresh = try await bridge.screenshot()
        try await bridge.authorizeTaskInput(imageID: fresh.id)
        try await bridge.tap(x: 1, y: 1, imageID: fresh.id)
        XCTAssertEqual(connection.taps, 1)
        await bridge.stop()
    }
    func testSystemActionsNeedOneUseAuthorizationButNoScreenshot() async throws {
        for name in ["home", "launch_app", "type_text"] {
            let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
            _ = try await bridge.systemActionContext()
            do { try await bridge.systemAction(name: name, text: "fixture", arguments: [], imageID: "not-approved"); XCTFail("unapproved") } catch {}
            try await bridge.authorizeSystemAction(authorizationID: "single-use", taskScoped: true)
            try await bridge.systemAction(name: name, text: "fixture", arguments: [], imageID: "single-use")
            do { try await bridge.systemAction(name: name, text: "fixture", arguments: [], imageID: "single-use"); XCTFail("replay") } catch {}
            XCTAssertEqual(connection.systemActions, [name]); XCTAssertEqual(connection.captures, 0)
            try await bridge.authorizeSystemAction(authorizationID: "old-session", taskScoped: true)
            connection.controlSessionID = UUID()
            _ = try await bridge.installedApplications()
            do { try await bridge.systemAction(name: name, text: "fixture", arguments: [], imageID: "old-session"); XCTFail("old grant") } catch {}
            XCTAssertEqual(connection.systemActions, [name])
            await bridge.stop()
        }
    }
    func testNewActionsConsumeOneUseApprovalAndCannotReplay() async throws {
        for name in ["home", "launch_app", "type_text"] {
            let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
            let frame = try await bridge.screenshot()
            do { try await bridge.systemAction(name: name, text: "example.fixture", arguments: [], imageID: frame.id); XCTFail("unapproved action") } catch {}
            XCTAssertTrue(connection.systemActions.isEmpty)
            try await bridge.acceptApproval(imageID: frame.id)
            try await bridge.systemAction(name: name, text: "example.fixture", arguments: [], imageID: frame.id)
            do { try await bridge.systemAction(name: name, text: "example.fixture", arguments: [], imageID: frame.id); XCTFail("replay") } catch {}
            XCTAssertEqual(connection.systemActions, [name])
            await bridge.stop()
        }
    }
    func testStartupRestoreDoesNotFalselyMarkBackgroundAsForeground() {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "identity.plist")
        let flow = PairingFlow(store: RemotePairRecordStore(url: url))
        flow.background()
        flow.restoreConnection()
        XCTAssertTrue(flow.isBackground)
        XCTAssertFalse(flow.ready); XCTAssertFalse(flow.hasRecord); XCTAssertFalse(flow.running)
        flow.cancel()
    }
    func testBackgroundKeepsIdleAuthenticatedSession() {
        let flow = PairingFlow()
        flow.ready = true
        let session = flow.controlSessionID
        flow.background()
        XCTAssertTrue(flow.isBackground)
        XCTAssertTrue(flow.ready)
        XCTAssertEqual(flow.controlSessionID, session)
        flow.resume()
        XCTAssertFalse(flow.isBackground)
        XCTAssertTrue(flow.ready)
        XCTAssertEqual(flow.controlSessionID, session)
        flow.cancel()
    }
    func testFinishingLastBackgroundRunKeepsConnectionForNextRun() {
        let flow = PairingFlow(), owner = UUID()
        flow.ready = true
        let session = flow.controlSessionID
        flow.retainConnection(owner: owner)
        flow.registerAgent(owner: owner, session: session)
        flow.background()
        flow.releaseAgent(owner: owner, session: session)
        flow.releaseConnection(owner: owner)
        XCTAssertFalse(flow.agentReserved)
        XCTAssertTrue(flow.ready)
        XCTAssertEqual(flow.controlSessionID, session)
        flow.cancel()
        XCTAssertFalse(flow.ready)
        XCTAssertNotEqual(flow.controlSessionID, session)
    }
    func testOrdinaryChatFinishingInBackgroundDoesNotRevokeControl() {
        let flow = PairingFlow(), owner = UUID()
        flow.ready = true
        let session = flow.controlSessionID
        flow.retainConnection(owner: owner)
        flow.background()
        flow.releaseConnection(owner: owner)
        XCTAssertTrue(flow.ready)
        XCTAssertEqual(flow.controlSessionID, session)
        flow.cancel()
    }
    func testConsecutiveAuthorizedOperationsReuseCoordinateReferenceWithoutCaptures() async throws {
        for mode in [InputAuthorizationMode.perAction, .task] {
            let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
            let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
                onImage: { _, _ in }, onReceipt: { _ in }, authorizationMode: mode)
            _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "frame")
            let tap = try await coordinator.execute(name: "tap", parameters: ["x": 2, "y": 3, "purpose": "first"], callID: "tap1")
            let wait = try await coordinator.execute(name: "wait", parameters: ["duration_ms": 1], callID: "wait")
            _ = try await coordinator.execute(name: "home", parameters: ["purpose": "home"], callID: "home")
            _ = try await coordinator.execute(name: "drag", parameters: ["from_x": 1, "from_y": 2, "to_x": 5, "to_y": 10, "duration_ms": 200, "purpose": "drag"], callID: "drag")
            _ = try await coordinator.execute(name: "tap", parameters: ["x": 2, "y": 3, "purpose": "next"], callID: "tap2")
            XCTAssertFalse(tap.isError)
            XCTAssertEqual(tap.result, "Command delivery acknowledged.")
            XCTAssertFalse(wait.isError)
            XCTAssertEqual(wait.result, "Wait completed.")
            XCTAssertEqual(connection.captures, 1)
            XCTAssertEqual(connection.taps, 2)
            XCTAssertEqual(connection.drags.count, 5)
            XCTAssertEqual(connection.systemActions, ["home"])
            await coordinator.stop()
        }
    }

    func testUsesRemotePixelsAndRequiresApprovalBeforeInput() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        XCTAssertEqual(frame.width, 10); XCTAssertEqual(frame.height, 20); XCTAssertFalse(frame.isDemo)
        do { try await bridge.tap(x: 100, y: 200, imageID: frame.id); XCTFail("unapproved input") } catch {}
        XCTAssertEqual(connection.taps, 0)
        try await bridge.acceptApproval(imageID: frame.id)
        try await bridge.tap(x: 100, y: 200, imageID: frame.id)
        do { try await bridge.tap(x: 100, y: 200, imageID: frame.id); XCTFail("replayed input") } catch {}
        XCTAssertEqual(connection.taps, 1)
    }
    func testReconnectInvalidatesOldGrantButRunCanObserveAgain() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.authorizeTaskInput(imageID: frame.id)
        connection.controlSessionID = UUID()
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("new generation accepted") } catch {}
        _ = try await bridge.screenshot()
        XCTAssertEqual(connection.taps, 0)
        XCTAssertEqual(connection.captures, 2)
    }
    func testDragForwardsNormalizedCoordinatesAndConsumesApproval() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.authorizeTaskInput(imageID: frame.id)
        try await bridge.drag(fromX: 0, fromY: 65535, toX: 65535, toY: 0, durationMS: 1000, imageID: frame.id)
        XCTAssertEqual(connection.drags, [0, 65535, 65535, 0, 1000])
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("consumed approval accepted") } catch {}
    }
    func testCancellationFencesBeforeAsynchronousRelease() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.acceptApproval(imageID: frame.id)
        bridge.cancelTransport()
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("cancelled input") } catch {}
        XCTAssertEqual(connection.taps, 0)
        await bridge.stop()
        XCTAssertTrue(connection.ready)
    }
    func testInvalidScreenshotRevokesPreviousImageApproval() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.acceptApproval(imageID: frame.id)
        connection.png = Data()
        do { _ = try await bridge.screenshot(); XCTFail("invalid PNG accepted") } catch {}
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("prior frame reused") } catch {}
        XCTAssertEqual(connection.taps, 0)
    }
    func testDisconnectedBridgeReportsErrorOnlyWhenToolIsCalledAndCanBindLater() async throws {
        let connection = CoreDeviceConnectionSpy(); connection.ready = false
        let bridge = try CoreDeviceBridge(flow: connection)
        XCTAssertEqual(connection.reservations, 0)
        do { _ = try await bridge.screenshot(); XCTFail("disconnected capture") } catch {}
        XCTAssertEqual(connection.captures, 0)
        connection.controlSessionID = UUID(); connection.ready = true
        _ = try await bridge.screenshot()
        XCTAssertEqual(connection.reservations, 1)
        XCTAssertEqual(connection.captures, 1)
    }
    func testBackgroundCapabilityDoesNotTurnConnectionFailureIntoLifecyclePause() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        _ = try await bridge.screenshot()
        connection.controlSessionID = UUID()
        let capable = await bridge.supportsBackgroundExecution(tool: "screenshot")
        XCTAssertTrue(capable)
        _ = try await bridge.screenshot()
        XCTAssertEqual(connection.captures, 2)
    }
    func testDisconnectedOrdinaryChatAndFailedToolBothAllowModelReply() async throws {
        for requestsScreenshot in [false, true] {
            let connection = CoreDeviceConnectionSpy(); connection.ready = false; connection.allowsConnectionWait = true
            let bridge = try CoreDeviceBridge(flow: connection, connectionTimeout: .milliseconds(120))
            let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                runServices: AgentRunServices(provider: DisconnectedChatProvider(requestsScreenshot: requestsScreenshot), bridge: bridge))
            let id = model.createConversation(mode: .live)
            XCTAssertTrue(model.send("你好", in: id, cloudConsent: true))
            for _ in 0..<200 {
                if !model.running && !model.stopping { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.running)
            XCTAssertEqual(model.sessions.conversation(id)?.phase, .completed)
            XCTAssertTrue(model.sessions.conversation(id)?.messages.contains { $0.role == .assistant && $0.text == "正常回复" } ?? false)
            let tools = model.sessions.conversation(id)?.messages.compactMap(\.tool) ?? []
            XCTAssertEqual(tools.count, requestsScreenshot ? 1 : 0)
            if requestsScreenshot { XCTAssertEqual(tools.first?.state, .failed) }
            XCTAssertEqual(connection.reservations, 0)
            XCTAssertEqual(connection.captures, 0)
            XCTAssertEqual(connection.connectionAttempts, requestsScreenshot ? 1 : 0)
        }
    }
    func testOrdinaryRunPreservesBackgroundConnectionWithoutReservingDevice() async throws {
        let flow = PairingFlow(); flow.ready = true
        let bridge = try CoreDeviceBridge(flow: flow)
        XCTAssertFalse(flow.agentReserved)
        flow.background()
        XCTAssertTrue(flow.ready)
        await bridge.stop()
        XCTAssertTrue(flow.ready)
        flow.cancel()
    }
    func testDeviceRunsQueueAndWaitingCancellationPreservesOwner() async throws {
        let flow = PairingFlow(); flow.ready = true
        let session = flow.controlSessionID, a = UUID(), b = UUID(), c = UUID()
        flow.registerAgent(owner: a, session: session)
        flow.registerAgent(owner: b, session: session)
        flow.registerAgent(owner: c, session: session)
        _ = try await flow.agentOperation(owner: a, session: session) { _ in 1 }
        XCTAssertTrue(flow.canActivateApplication(owner: a, session: session))
        XCTAssertFalse(flow.canActivateApplication(owner: b, session: session), "Completion must not take another run's device lease")
        flow.background()
        XCTAssertTrue(flow.ready)
        var secondEntered = false, thirdEntered = false
        let second = Task { try await flow.agentOperation(owner: b, session: session) { _ in secondEntered = true } }
        let third = Task { try await flow.agentOperation(owner: c, session: session) { _ in thirdEntered = true } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(secondEntered); XCTAssertFalse(thirdEntered)
        second.cancel(); flow.releaseAgent(owner: b, session: session)
        do { try await second.value; XCTFail("cancelled waiter ran") } catch {}
        XCTAssertTrue(flow.ready)
        _ = try await flow.agentOperation(owner: a, session: session) { _ in 2 }
        flow.releaseAgent(owner: a, session: session)
        try await third.value
        XCTAssertTrue(thirdEntered); XCTAssertFalse(secondEntered)
        XCTAssertTrue(flow.ready)
        flow.releaseAgent(owner: c, session: session)
        XCTAssertTrue(flow.ready)
        XCTAssertEqual(flow.controlSessionID, session)
        flow.cancel()
    }

    func testCoreDeviceRunCanCaptureAndTapInBackgroundWithoutScreenCapture() async throws {
        let connection = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: connection)
        let synthetic = try await DemoBridge().screenshot()
        connection.png = synthetic.png
        let scheduler = CoreDeviceTestScheduler()
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: AgentRunServices(provider: DemoProvider(), bridge: bridge), lifecycle: lifecycle)
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("test", in: id, cloudConsent: true))
        XCTAssertTrue(lifecycle.hasLease)
        XCTAssertFalse(model.capture.active)
        model.setForeground(false)
        for _ in 0..<200 {
            if !model.running && !model.stopping { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.running)
        XCTAssertEqual(connection.taps, 1)
        XCTAssertTrue(model.sessions.conversation(id)?.messages.compactMap(\.tool).contains { $0.name == "screenshot" && $0.state == .succeeded } ?? false)
    }

    func testConnectionFailureClearsAllOwnersAndNeverReplaysQueuedInput() async throws {
        let flow = PairingFlow(); flow.ready = true
        let old = flow.controlSessionID, a = UUID(), b = UUID()
        flow.registerAgent(owner: a, session: old); flow.registerAgent(owner: b, session: old)
        _ = try await flow.agentOperation(owner: a, session: old) { _ in 1 }
        var entered = false
        let waiter = Task { try await flow.agentOperation(owner: b, session: old) { _ in entered = true } }
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await flow.agentOperation(owner: a, session: old) { _ in throw NativeBackendError.malformedEvent }
            XCTFail("failure ignored")
        } catch {}
        XCTAssertFalse(flow.agentReserved)
        XCTAssertNotEqual(flow.controlSessionID, old)
        flow.ready = true // Reconnection must not revive an old queued run.
        do { try await waiter.value; XCTFail("queued run survived reconnect") } catch {}
        XCTAssertFalse(entered)
        flow.cancel()
    }

}

private struct DisconnectedChatProvider: ModelProvider {
    static let name = "disconnected-chat-fixture"
    let configuration = ProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    let requestsScreenshot: Bool
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let result = request.messages.first { $0.role == .tool }
        if requestsScreenshot && result == nil {
            return ModelResponse(text: "", finishReason: .toolCalls,
                toolCalls: [ModelToolCall(id: "screen", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)
        }
        if requestsScreenshot && result?.content.contains("等待手机操控连接超时") != true {
            throw AppError.invalid("模型未收到设备工具的连接错误")
        }
        return ModelResponse(text: "正常回复", finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Manual monotonic clock: exercise ten-minute boundaries without real waits.
@MainActor private final class MediaIdleClock {
    var instant = ContinuousClock.now
    var sleeps: [(Duration, CheckedContinuation<Void, Never>)] = []
    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { sleeps.append((duration, $0)) }
    }
    func fire(_ index: Int) { sleeps[index].1.resume() }
}

extension CoreDeviceBridgeTests {
    func testMuseMediaReuseReleasesOwnersRefreshesOnlyBusinessUseAndExpiresAtTenMinutes() async throws {
        let clock = MediaIdleClock()
        let lifetime = ControlMediaLifetime(now: { clock.instant }, sleep: { await clock.sleep($0) })
        var starts = 0, stops = 0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let flow = PairingFlow(store: RemotePairRecordStore(url: url), mediaLifetime: lifetime,
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
        let flow = PairingFlow(store: RemotePairRecordStore(url: .temporaryDirectory.appendingPathComponent(UUID().uuidString)),
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
        let flow = PairingFlow(store: RemotePairRecordStore(url: .temporaryDirectory.appendingPathComponent(UUID().uuidString)),
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
}

extension CoreDeviceBridgeTests {
    func testCancelledIdleHintWaitDoesNotCancelNativeStopOrNextRun() async throws {
        let lifetime = ControlMediaLifetime()
        var starts = 0, stops = 0
        var gate: CheckedContinuation<Void, Never>?
        let flow = PairingFlow(store: RemotePairRecordStore(url: .temporaryDirectory.appendingPathComponent(UUID().uuidString)),
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
