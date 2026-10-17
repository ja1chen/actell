import XCTest
@testable import PhoneAgent

private actor RemoteRuntimeTestBridge: DeviceBridge {
    private let demo = DemoBridge()
    private(set) var inputs = 0
    private(set) var stops = 0
    func supportsBackgroundExecution(tool: String) -> Bool { true }
    func setRemoteDeadline(_ deadline: Date) throws { guard deadline > Date() else { throw AppError.stopped } }
    func inputDisplaySnapshot() -> InputDisplaySnapshot { .init(context: "synthetic-remote-control", token: "v1", sampledAt: Date()) }
    func authorizeIndependentInput(_ snapshot: InputDisplaySnapshot, authorizationID: String) {}
    func independentInput(name: String, coordinates: [Int], durationMS: Int, snapshot: InputDisplaySnapshot, authorizationID: String) { inputs += 1 }
    func screenshot() async throws -> FrameImage { try await demo.screenshot() }
    func validateRemoteObservation(_ frame: FrameImage) {}
    func tap(x: Int, y: Int, imageID: String) throws { throw AppError.stopped }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) throws { throw AppError.stopped }
    func systemActionContext() -> String { "synthetic-remote-control" }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) throws {
        guard taskScoped, !authorizationID.isEmpty else { throw AppError.stopped }
    }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) { inputs += 1 }
    func stop() async { stops += 1; await demo.stop() }
}

@MainActor final class RemoteToolRuntimeTests: XCTestCase {
    func testPerInvokeReleaseRetainsSelectedContinuationWithoutHoldingPhoneOwnership() async throws {
        let background = BackgroundExecutionCoordinator.testing(selection: [.audio])
        let receipt = BackgroundSourceToken(mechanism: .audio, owner: UUID())
        background.registry.publish(receipt)
        let model = AgentViewModel(loadPersistentState: false, backgroundCoordinator: background, makeRemoteBridge: { RemoteRuntimeTestBridge() })
        model.setForeground(true); model.setProtectedDataAvailable(true)
        let first = try model.acquireRemoteRun("first", onImage: { _ in }, onStop: {})
        first.stop(message: "Synthetic normal completion")
        await first.waitForRemoteRelease(); model.releaseRemoteRun("first")
        XCTAssertFalse(model.hasBusySessions) // No phone ownership between calls.
        XCTAssertEqual(background.desired, [.audio])
        model.setForeground(false)
        let second = try model.acquireRemoteRun("second", onImage: { _ in }, onStop: {})
        let result = try await second.executeRemoteTool(name: "home", arguments: ["purpose": "Synthetic continuation"], callID: "home", imageID: nil, deadline: Date().addingTimeInterval(20))
        XCTAssertFalse(result.isError, result.result)
        second.stop(message: "Synthetic normal completion")
        await second.waitForRemoteRelease(); model.releaseRemoteRun("second")
        model.endRemoteContinuity()
        XCTAssertTrue(background.desired.isEmpty)
        let afterStop = try model.acquireRemoteRun("after-stop", onImage: { _ in }, onStop: {})
        afterStop.stop(message: "Synthetic completion")
        await afterStop.waitForRemoteRelease(); model.releaseRemoteRun("after-stop")
        model.endRemoteContinuity()
        background.registry.revoke(receipt)
    }
    func testBackgroundAdmissionDoesNotRequireForegroundHistoryOrPreexistingReceipt() async throws {
        let background = BackgroundExecutionCoordinator.testing(selection: [.audio])
        let bridge = RemoteRuntimeTestBridge()
        let model = AgentViewModel(loadPersistentState: false, backgroundCoordinator: background, makeRemoteBridge: { bridge })
        model.setForeground(false)
        let runtime = try model.acquireRemoteRun("background", onImage: { _ in }, onStop: {})
        XCTAssertTrue(runtime.running) // Admission succeeds before any source receipt.
        let receipt = BackgroundSourceToken(mechanism: .audio, owner: UUID())
        background.registry.publish(receipt) // Shared execution lifecycle handles readiness.
        let result = try await runtime.executeRemoteTool(name: "home", arguments: ["purpose": "Synthetic background request"], callID: "home", imageID: nil, deadline: Date().addingTimeInterval(20))
        XCTAssertFalse(result.isError, result.result)
        runtime.stop(message: "Synthetic completion")
        await runtime.waitForRemoteRelease(); model.releaseRemoteRun("background")
        model.setProtectedDataAvailable(false)
        XCTAssertTrue(background.desired.isEmpty)
        XCTAssertThrowsError(try model.acquireRemoteRun("locked", onImage: { _ in }, onStop: {}))
        background.registry.revoke(receipt)
    }
    func testIndependentRemoteInputNeedsNoScreenshotAndPreservesBounds() async throws {
        let bridge = RemoteRuntimeTestBridge()
        let model = AgentViewModel(loadPersistentState: false, makeRemoteBridge: { bridge })
        model.setForeground(true); model.setProtectedDataAvailable(true)
        let runtime = try model.acquireRemoteRun("independent", onImage: { _ in XCTFail("Input must not capture a screenshot") }, onStop: {})
        for index in 0..<2 {
            let result = try await runtime.executeRemoteTool(name: "tap", arguments: ["x": 500, "y": 1000, "purpose": "Synthetic input", "_input_contract": InputDisplaySnapshot.contract], callID: "tap-\(index)", imageID: nil, deadline: Date().addingTimeInterval(20))
            XCTAssertFalse(result.isError, result.result)
        }
        let bad = try await runtime.executeRemoteTool(name: "tap", arguments: ["x": 1001, "y": 0, "purpose": "Synthetic input", "_input_contract": InputDisplaySnapshot.contract], callID: "bad", imageID: nil, deadline: Date().addingTimeInterval(20))
        XCTAssertTrue(bad.isError)
        let count = await bridge.inputs
        XCTAssertEqual(count, 2)
        runtime.stop(message: "Synthetic stop")
        await runtime.waitForRemoteRelease()
        model.releaseRemoteRun("independent")
    }
    func testRemoteRuntimeUsesSelectedBackgroundMechanismsAndReleasesDemand() async throws {
        let background = BackgroundExecutionCoordinator.testing(selection: [.audio])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try RemoteToolRuntime(bridge: RemoteRuntimeTestBridge(), persistent: true,
            directory: directory, backgroundCoordinator: background,
            approvalRecords: ApprovalRecordStore(inMemory: true), diagnostics: USBDiagnosticsLog(),
            onImage: { _ in }, onStop: {})
        XCTAssertEqual(background.desired, [.audio])
        XCTAssertFalse(background.locationExplanation) // A remote request never prompts for location.
        background.applySelection([])
        XCTAssertTrue(background.desired.isEmpty)
        background.applySelection([.audio])
        XCTAssertTrue(background.desired.isEmpty) // New selections do not expand an existing run.
        runtime.stop(message: "Synthetic remote stop")
        await runtime.waitForRemoteRelease()
        XCTAssertTrue(background.desired.isEmpty)
        XCTAssertFalse(runtime.running)
    }
    func testRemoteToolsNeverCreateSelectOrWriteAnAgentConversation() async throws {
        let sessions = ConversationStore(inMemory: true), bridge = RemoteRuntimeTestBridge()
        let model = AgentViewModel(sessions: sessions, loadPersistentState: false, makeRemoteBridge: { bridge })
        model.setForeground(true); model.setProtectedDataAvailable(true)
        let selected = model.createConversationDraft(mode: .demo)
        sessions.setDraft("Local draft stays here", in: selected)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(sessions.conversation(selected))
        var captured: FrameImage?
        var stopped = 0
        let runtime = try model.acquireRemoteRun("remote-test", onImage: { captured = $0 }, onStop: { stopped += 1 })
        XCTAssertTrue(model.hasBusySessions)
        XCTAssertEqual(model.selectedConversationID, selected)
        XCTAssertNil(model.currentRun)
        XCTAssertTrue(sessions.activeRuns.isEmpty)
        let screenshot = try await runtime.executeRemoteTool(name: "screenshot", arguments: [:], callID: "screen", imageID: nil, deadline: Date().addingTimeInterval(20))
        XCTAssertFalse(screenshot.isError)
        XCTAssertNotNil(captured)
        for id in ["home-one", "home-two"] {
            let result = try await runtime.executeRemoteTool(name: "home", arguments: ["purpose": "Synthetic test"], callID: id, imageID: nil, deadline: Date().addingTimeInterval(20))
            XCTAssertFalse(result.isError, result.result)
        }
        let inputs = await bridge.inputs
        XCTAssertEqual(inputs, 2)
        XCTAssertEqual(model.approvalRecords.records.count, 2)
        XCTAssertTrue(model.approvalRecords.records.allSatisfy { $0.state == .finished && $0.authorizationMode == .task })
        XCTAssertEqual(runtime.remoteDelivery("home-two"), .acknowledged)
        do {
            let replay = try await runtime.executeRemoteTool(name: "home", arguments: ["purpose": "Synthetic test"], callID: "home-two", imageID: nil, deadline: Date().addingTimeInterval(20))
            XCTAssertTrue(replay.isError)
        } catch {}
        let afterReplay = await bridge.inputs
        XCTAssertEqual(afterReplay, 2)
        model.stop()
        XCTAssertEqual(stopped, 1)
        XCTAssertTrue(model.hasBusySessions) // The lease stays claimed until release finishes.
        await runtime.waitForRemoteRelease()
        let stops = await bridge.stops
        XCTAssertEqual(stops, 1)
        model.releaseRemoteRun("remote-test")
        XCTAssertFalse(model.hasBusySessions)
        XCTAssertEqual(model.selectedConversationID, selected)
        XCTAssertEqual(try encoder.encode(sessions.conversation(selected)), before)
        XCTAssertTrue(sessions.conversations.isEmpty) // Composer draft remains a draft.
        XCTAssertTrue(sessions.activeRuns.isEmpty)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertNil(model.activitySnapshot)
    }
    func testFailedAdmissionDoesNotLeaveEmptyConversationsOrChangeSelection() throws {
        let sessions = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: sessions, loadPersistentState: false, makeRemoteBridge: {
            throw RemoteRPCError("control_not_connected", "Synthetic disconnected route")
        })
        model.setForeground(true); model.setProtectedDataAvailable(true)
        XCTAssertThrowsError(try model.acquireRemoteRun("failed", onImage: { _ in }, onStop: {}))
        XCTAssertTrue(sessions.conversations.isEmpty)
        XCTAssertNil(model.selectedConversationID)
        XCTAssertTrue(sessions.activeRuns.isEmpty)
        XCTAssertFalse(model.hasBusySessions)
    }
    func testLockStopsIndependentRuntimeAndRetainsLeaseUntilDrained() async throws {
        let sessions = ConversationStore(inMemory: true), bridge = RemoteRuntimeTestBridge()
        let model = AgentViewModel(sessions: sessions, loadPersistentState: false, makeRemoteBridge: { bridge })
        model.setForeground(true); model.setProtectedDataAvailable(true)
        var stopped = 0
        let runtime = try model.acquireRemoteRun("locked", onImage: { _ in }, onStop: { stopped += 1 })
        model.setProtectedDataAvailable(false)
        XCTAssertEqual(stopped, 1)
        XCTAssertFalse(runtime.running)
        XCTAssertTrue(model.hasBusySessions)
        await runtime.waitForRemoteRelease()
        model.releaseRemoteRun("old-id")
        XCTAssertTrue(model.hasBusySessions)
        model.releaseRemoteRun("locked")
        XCTAssertFalse(model.hasBusySessions)
        XCTAssertTrue(sessions.conversations.isEmpty)
    }
}
