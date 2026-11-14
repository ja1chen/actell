import XCTest
import ImageIO
import UIKit
import ProviderCore
@testable import PhoneAgent

@MainActor final class CoreDeviceBridgeTests: XCTestCase {
    private func launch(_ bridge: CoreDeviceBridge) async throws -> NativeApplicationLaunch? {
        _ = try await bridge.systemActionContext()
        try await bridge.authorizeSystemAction(authorizationID: "fixture-launch", taskScoped: true)
        return try await bridge.systemAction(name: "launch_app", text: "example.fixture", arguments: [], imageID: "fixture-launch")
    }

    func testLaunchedPIDIsScopedToTaskAndConnectionAndReplacedOnLaunch() async throws {
        let flow = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: flow)
        let receipt = try await launch(bridge)
        XCTAssertEqual(receipt?.pid, 7001)
        _ = try await bridge.accessibilityObservation()
        XCTAssertEqual(flow.fallbackPIDs, [7001])
        flow.launchPID = 7002
        _ = try await launch(bridge)
        _ = try await bridge.accessibilityObservation()
        XCTAssertEqual(flow.fallbackPIDs.last!, 7002)
        let other = try CoreDeviceBridge(flow: flow)
        _ = try await other.accessibilityObservation()
        XCTAssertNil(flow.fallbackPIDs.last!)
        flow.controlSessionID = UUID()
        _ = try await bridge.accessibilityObservation()
        XCTAssertNil(flow.fallbackPIDs.last!)
        await bridge.stop(); await other.stop()
    }

    func testOldPIDClearsAfterHomeFailedLaunchChangedProcessAndAXFailure() async throws {
        for reason in ["home", "failed-launch", "changed-process", "ax-failure"] {
            let flow = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: flow)
            _ = try await launch(bridge)
            switch reason {
            case "home":
                try await bridge.authorizeSystemAction(authorizationID: "home", taskScoped: true)
                try await bridge.systemAction(name: "home", text: "", arguments: [], imageID: "home")
            case "failed-launch":
                flow.activationError = .unknownOutcome
                do { _ = try await launch(bridge); XCTFail("Expected launch failure") } catch {}
            case "changed-process":
                flow.accessibilityData = Data(#"{"application":{"pid":7002},"selection":{"method":"hit-test"}}"#.utf8)
                _ = try await bridge.accessibilityObservation()
            default:
                flow.accessibilityError = NativeBackendError.accessibilityFailure(stage: 29, cause: 19)
                do { _ = try await bridge.accessibilityObservation(); XCTFail("Expected AX failure") } catch {}
                flow.accessibilityError = nil
            }
            _ = try await bridge.accessibilityObservation()
            XCTAssertNil(flow.fallbackPIDs.last!, reason)
            XCTAssertTrue(flow.ready)
            await bridge.stop()
            let reads = flow.fallbackPIDs.count
            do { _ = try await bridge.accessibilityObservation(); XCTFail("Stopped task cannot read") } catch {}
            XCTAssertEqual(flow.fallbackPIDs.count, reads)
        }
    }

    func testPIDFallbackMetadataReachesModelAndFailureDoesNotBlockNextAction() async throws {
        let flow = CoreDeviceConnectionSpy(), bridge = try CoreDeviceBridge(flow: flow)
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: .screenshotAndAccessibility)
        _ = try await coordinator.execute(name: "launch_app", parameters: ["bundle_id": "example.fixture", "description": "fixture"], callID: "launch")
        flow.accessibilityData = Data(#"{"status":"available","application":{"pid":7001,"bundleId":"example.fixture"},"selection":{"method":"explicit-pid","reason":"center_hit_unavailable","scope":"requested-application"},"nodes":[{"label":"fixture content"}]}"#.utf8)
        let observation = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "fallback")
        XCTAssertTrue(observation.content.contains("requested-application"))
        XCTAssertTrue(observation.content.contains("fixture content"))
        XCTAssertEqual(flow.fallbackPIDs.last!, 7001)
        flow.accessibilityError = NativeBackendError.accessibilityFailure(stage: 28, cause: 2)
        let failure = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "timeout")
        XCTAssertEqual(failure.kind, .returned)
        XCTAssertTrue(failure.content.contains("unavailable"))
        _ = try await coordinator.execute(name: "tap", parameters: ["x": 1, "y": 1, "description": "fixture"], callID: "after-ax-failure")
        XCTAssertEqual(flow.taps, 1); XCTAssertTrue(flow.ready)
        await bridge.stop()
    }

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
        let flow = DeviceControlCoordinator(), owner = UUID()
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
    func testLogicalDisplayScaleChangeRejectsOldCoordinatesAndFreshObservationCanDrag() async throws {
        let flow = CoreDeviceConnectionSpy(); flow.geometryToken = "stable-video"
        flow.logicalBounds = .init(x: 0, y: 0, width: 390, height: 844)
        let bridge = try CoreDeviceBridge(flow: flow)
        let previous = try await bridge.inputDisplaySnapshot()
        XCTAssertEqual(previous.logicalBounds, flow.logicalBounds)
        flow.logicalBounds = .init(x: 0, y: 0, width: 320, height: 693)
        do { try await bridge.authorizeIndependentInput(previous, authorizationID: "old"); XCTFail("Logical scale changed") }
        catch { XCTAssertEqual((error as? RemoteRPCError)?.code, "geometry_changed") }
        let current = try await bridge.inputDisplaySnapshot()
        try await bridge.authorizeIndependentInput(current, authorizationID: "fresh")
        try await bridge.independentInput(name: "drag", coordinates: [32768, 50000, 32768, 10000], durationMS: 300, snapshot: current, authorizationID: "fresh")
        XCTAssertEqual(flow.drags, [32768, 50000, 32768, 10000, 300])
        XCTAssertEqual(flow.captures, 0)
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
        let flow = DeviceControlCoordinator(store: store)
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
        let flow = DeviceControlCoordinator(), owner = UUID()
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
        let flow = DeviceControlCoordinator(), owner = UUID()
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
        let flow = DeviceControlCoordinator(store: RemotePairRecordStore(url: url))
        flow.background()
        flow.restoreConnection()
        XCTAssertTrue(flow.isBackground)
        XCTAssertFalse(flow.ready); XCTAssertFalse(flow.hasRecord); XCTAssertFalse(flow.running)
        flow.cancel()
    }
    func testBackgroundKeepsIdleAuthenticatedSession() {
        let flow = DeviceControlCoordinator()
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
        let flow = DeviceControlCoordinator(), owner = UUID()
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
        let flow = DeviceControlCoordinator(), owner = UUID()
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
            let tap = try await coordinator.execute(name: "tap", parameters: ["x": 2, "y": 3, "description": "first"], callID: "tap1")
            let wait = try await coordinator.execute(name: "wait", parameters: ["duration_ms": 1], callID: "wait")
            _ = try await coordinator.execute(name: "home", parameters: ["description": "home"], callID: "home")
            _ = try await coordinator.execute(name: "drag", parameters: ["from_x": 1, "from_y": 2, "to_x": 5, "to_y": 10, "duration_ms": 200, "description": "drag"], callID: "drag")
            _ = try await coordinator.execute(name: "tap", parameters: ["x": 2, "y": 3, "description": "next"], callID: "tap2")
            XCTAssertEqual(tap.kind, .returned)
            XCTAssertEqual(tap.content, "Command delivery acknowledged.")
            XCTAssertEqual(wait.kind, .returned)
            XCTAssertEqual(wait.content, "Wait completed.")
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
        let flow = DeviceControlCoordinator(); flow.ready = true
        let bridge = try CoreDeviceBridge(flow: flow)
        XCTAssertFalse(flow.agentReserved)
        flow.background()
        XCTAssertTrue(flow.ready)
        await bridge.stop()
        XCTAssertTrue(flow.ready)
        flow.cancel()
    }
    func testDeviceRunsQueueAndWaitingCancellationPreservesOwner() async throws {
        let flow = DeviceControlCoordinator(); flow.ready = true
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
        let flow = DeviceControlCoordinator(); flow.ready = true
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
        let result = fixtureMessages(request).first { $0.role == .tool }
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
                    continuation.yield(.terminal(response)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension CoreDeviceBridgeTests {
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
        let waiting = try CoreDeviceBridge(flow: absent, connectionTimeout: .milliseconds(120))
        do { _ = try await waiting.screenshot(); XCTFail("Expected bounded timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("连接超时")) }
        XCTAssertEqual(absent.captures, 0)
        await waiting.stop()
    }
}
