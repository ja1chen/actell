import XCTest
import CoreVideo
import Combine
import ProviderCore
@testable import PhoneAgent

private final class SyntheticCapture: @unchecked Sendable {
    let frames = LatestScreenFrame()
    let health = USBTransportHealth()
    let token = UUID()
    let epoch: UUID
    private let pixels: [CVPixelBuffer]
    init() throws {
        var result: [CVPixelBuffer] = []
        for byte in [UInt8(60), UInt8(180)] {
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 390, 844, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
                  let pixel else { throw AppError.stopped }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(byte), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            result.append(pixel)
        }
        pixels = result; epoch = frames.begin(); health.begin(token); push()
    }
    func push(alternate: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        frames.put(pixels[alternate ? 1 : 0], orientation: 1, presentationSeconds: now, epoch: epoch, now: now)
        health.receivedPing(token, now: now)
    }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
@MainActor private final class SystemSchedulerSpy: RunBackgroundScheduler {
    var submissions = 0
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws { submissions += 1 }
    func cancel(identifier: String) {}
}
@MainActor private final class TargetState { var changed = false }
private struct ScreenOnlyProvider: ModelProvider {
    static let name = "screen-only-fixture"
    let configuration = ProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let messages = fixtureMessages(request)
        let observed = messages.firstIndex { $0.role == .tool && $0.toolCallId == "read-screen" }.map { index in
            messages.dropFirst(index + 1).contains { !$0.images.isEmpty }
        } ?? false
        if observed {
            return ModelResponse(text: "已查看本机画面", finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: "", finishReason: .toolCalls,
            toolCalls: [ModelToolCall(id: "read-screen", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.terminal(response))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
private actor GuardedUSBFixture: USBCommandTransport {
    private(set) var inputs: [String] = []
    private(set) var stopped = false
    let delay: UInt64
    let fail: Bool
    let stopDelay: UInt64
    init(delay: UInt64 = 0, fail: Bool = false, stopDelay: UInt64 = 0) {
        self.delay = delay; self.fail = fail; self.stopDelay = stopDelay
    }
    func command(_ body: String) async throws { try await command(body, permit: nil) }
    func command(_ body: String, permit: USBInputPermit?) async throws {
        guard !stopped else { throw AppError.stopped }
        if body == "PING" {
            return
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let enqueue = { self.inputs.append(body) }
        if let permit { try permit.enqueue(enqueue) } else { enqueue() }
        if fail { throw AppError.unknownOutcome }
    }
    func stopInputs(_ session: USBInputSession) async { stopped = true; if stopDelay > 0 { try? await Task.sleep(nanoseconds: stopDelay) } }
}

final class ScreenUSBPermitTests: XCTestCase {
    func testFirstCaptureOrHeartbeatFailureIsPreservedAfterCleanupAndLateUpdates() throws {
        for cause in ["usbHeartbeat", "captureEnded"] {
            let source = try SyntheticCapture(), clock = TestClock()
            source.push(now: clock.now())
            let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true, now: { clock.now() })
            switch cause {
            case "usbHeartbeat": clock.advance(0.8); source.push(now: clock.now()); source.health.invalidate()
            default: source.frames.invalidate()
            }
            XCTAssertThrowsError(try context.requireHealthy())
            let message = try XCTUnwrap(context.failureMessage)
            XCTAssertTrue(context.diagnosticSummary.contains("failure=\(cause)"))
            context.revoke(); source.push(now: clock.now())
            XCTAssertEqual(context.failureMessage, message)
            XCTAssertThrowsError(try context.requireHealthy()) { XCTAssertEqual($0.localizedDescription, message) }
        }
    }
    func testStaticBackgroundFrameDoesNotExpireAndPermitStillRequiresLiveCaptureAndUSB() throws {
        let source = try SyntheticCapture(), clock = TestClock()
        source.push(now: clock.now())
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true, now: { clock.now() })
        context.setScene(.background)
        clock.advance(1); source.push(now: clock.now())
        let stamp = try source.frames.latestStamp()
        let scope = try XCTUnwrap(context.observation())
        let permit = USBInputPermit(context: context, observation: scope, sequence: stamp.sequence)
        for elapsed in [3.0, 60.0, 3_600.0] {
            clock.advance(elapsed)
            source.health.receivedPing(source.token, now: clock.now())
            XCTAssertNoThrow(try context.requireHealthy())
            XCTAssertEqual(try source.frames.latestStamp().sequence, stamp.sequence)
            XCTAssertEqual(try source.frames.latestStamp().uptime, stamp.uptime)
        }
        var sent = 0
        try permit.enqueue { sent += 1 }
        XCTAssertEqual(sent, 1)
        XCTAssertThrowsError(try permit.enqueue { sent += 1 }, "A permit is still one-use")
        let next = USBInputPermit(context: context, observation: scope, sequence: stamp.sequence)
        source.frames.invalidate()
        XCTAssertThrowsError(try next.enqueue { sent += 1 })
        XCTAssertEqual(sent, 1)
    }
    func testStaleHeartbeatAndNewCaptureSessionCannotReusePermit() throws {
        let source = try SyntheticCapture(), clock = TestClock()
        source.push(now: clock.now())
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true, now: { clock.now() })
        context.setScene(.background)
        XCTAssertThrowsError(try context.requireForegroundApproval())
        clock.advance(0.8)
        XCTAssertThrowsError(try context.requireHealthy())
        source.push(now: clock.now()); XCTAssertThrowsError(try context.requireHealthy())
        let next = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true, now: { clock.now() })
        _ = source.frames.begin()
        XCTAssertThrowsError(try next.requireHealthy())
    }
    func testHealthyCaptureAndUSBCanContinueBeyondFormerBackgroundAndRunDeadlines() throws {
        let source = try SyntheticCapture(), clock = TestClock()
        source.push(now: clock.now())
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true, now: { clock.now() })
        context.setScene(.background); clock.advance(61); source.push(now: clock.now())
        XCTAssertNoThrow(try context.requireHealthy())
        clock.advance(3_600); source.push(now: clock.now())
        XCTAssertNoThrow(try context.requireHealthy())
        context.setScene(.active)
        XCTAssertNoThrow(try context.requireHealthy())
        context.setScene(.background)
        clock.advance(3_600); source.push(now: clock.now())
        XCTAssertNoThrow(try context.requireHealthy())
        context.revoke()
        source.push(now: clock.now())
        XCTAssertThrowsError(try context.requireHealthy(), "Elapsed-time removal must not restore a stopped session")
    }
    func testNewerFrameCannotReviveRevokedPermitAndConsumptionRemainsOneShot() throws {
        let source = try SyntheticCapture()
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: false)
        let scope = try XCTUnwrap(context.observation())
        var sent = 0
        let stale = USBInputPermit(context: context, observation: scope, sequence: try source.frames.latestStamp().sequence)
        context.revoke()
        source.push(alternate: true)
        XCTAssertThrowsError(try stale.enqueue { sent += 1 })
        let fresh = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: false)
        let once = USBInputPermit(context: fresh, observation: scope, sequence: try source.frames.latestStamp().sequence)
        try once.enqueue { sent += 1 }
        XCTAssertThrowsError(try once.enqueue { sent += 1 })
        let changing = USBInputPermit(context: fresh, observation: scope, sequence: try source.frames.latestStamp().sequence)
        fresh.setScene(.inactive)
        XCTAssertThrowsError(try changing.enqueue { sent += 1 })
        XCTAssertEqual(sent, 1)
    }
    func testRevocationWhileTransportActorIsSuspendedPreventsEnqueue() async throws {
        let source = try SyntheticCapture()
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: false)
        let permit = USBInputPermit(context: context, observation: try XCTUnwrap(context.observation()), sequence: try source.frames.latestStamp().sequence)
        let transport = GuardedUSBFixture(delay: 200_000_000)
        let sending = Task { try await transport.command("TAP 1 2", permit: permit) }
        try await Task.sleep(nanoseconds: 50_000_000); context.revoke()
        do { try await sending.value; XCTFail("revoked permit was sent") } catch {}
        let inputs = await transport.inputs; XCTAssertTrue(inputs.isEmpty)
    }
}

@MainActor final class ScreenUSBBackgroundIntegrationTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw AppError.timeout
    }
    private func model(_ source: SyntheticCapture, transport: GuardedUSBFixture) throws -> AgentViewModel {
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true)
        let bridge = USBDeviceBridge(frames: source.frames, transport: transport, context: context)
        return AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                              runServices: .init(provider: DemoProvider(), bridge: bridge))
    }
    func testHIDConnectedForegroundScreenshotDoesNotWaitForBackgroundOrGrantInput() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let diagnostics = USBDiagnosticsLog(console: false)
        let bridge = try LiveDeviceBridgeRouter.make(frames: source.frames, captureActive: true,
            usb: .init(transport: transport, health: source.health, supportsHID: true), backgroundEnabled: true, diagnostics: diagnostics)
        XCTAssertTrue(bridge is USBDeviceBridge)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        let read = Task { try await bridge.screenshot() }
        let timeout = Task { try? await Task.sleep(nanoseconds: 750_000_000); if !Task.isCancelled { read.cancel() } }
        defer { ticker.cancel(); timeout.cancel(); read.cancel() }
        let frame = try await read.value
        XCTAssertNotNil(frame.capture); XCTAssertFalse(frame.png.isEmpty)
        // Observation metadata is NOT an input grant. Do not call the explicit
        // authorizeTaskInput API in a test for *ungranted* screenshot access.
        _ = try await bridge.approvalContext(imageID: frame.id)
        do { try await bridge.tap(x: 1, y: 2, imageID: frame.id); XCTFail("Foreground read is not input permission") } catch {}
        let inputs = await transport.inputs, stopped = await transport.stopped
        XCTAssertTrue(inputs.isEmpty); XCTAssertFalse(stopped, "A healthy foreground screenshot must not send STOP")
        XCTAssertTrue(diagnostics.report().contains("screenshot.begin scene=active"))
        XCTAssertTrue(diagnostics.report().contains("screenshot.ready sequence="))
        XCTAssertFalse(diagnostics.report().contains("bridge.stop"))
        await bridge.stop()
    }
    func testHIDConnectedScreenshotWaitsThroughInactiveForNewBackgroundFrame() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true)
        let bridge = USBDeviceBridge(frames: source.frames, transport: transport, context: context)
        let previousSequence = try source.frames.latestStamp().sequence
        context.setScene(.inactive)
        var completed = false
        let read = Task { let result = try await bridge.screenshot(); completed = true; return result }
        defer { read.cancel() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(completed)
        context.setScene(.background)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(completed, "The foreground frame must not cross the transition")
        source.push()
        let frame = try await read.value
        XCTAssertGreaterThan(try XCTUnwrap(frame.capture?.sequence), previousSequence)
        XCTAssertNoThrow(try context.requireHealthy())
        await bridge.stop()
    }
    func testHeartbeatFailureRetainsCauseWhileInputReleaseCompletes() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture(stopDelay: 250_000_000)
        let diagnostics = USBDiagnosticsLog(console: false)
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true)
        let bridge = USBDeviceBridge(frames: source.frames, transport: transport, context: context, diagnostics: diagnostics)
        try await bridge.arm()
        source.health.invalidate()
        try await waitUntil { diagnostics.report().contains("bridge.stop reason=sessionInvalid") }
        // A watchdog that runs during asynchronous STOP cleanup must report the
        // original transport failure, not generic revoked/unhealthy state.
        context.revoke()
        XCTAssertEqual(context.failureMessage, ScreenUSBExecutionContext.Failure.usbHeartbeat.message)
        XCTAssertThrowsError(try context.requireHealthy()) {
            XCTAssertEqual($0.localizedDescription, ScreenUSBExecutionContext.Failure.usbHeartbeat.message)
        }
        let stopped = await transport.stopped
        XCTAssertTrue(stopped)
        XCTAssertTrue(source.frames.diagnostics().active)
        XCTAssertFalse(diagnostics.report().contains("PRIVATE_DETAILS"))
        XCTAssertFalse(diagnostics.report().contains("reason=screenshotTimeout"))
    }
    func testLiveHIDConnectedScreenOnlyTaskCompletesWithoutLeavingPhoneAgent() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true)
        let bridge = USBDeviceBridge(frames: source.frames, transport: transport, context: context)
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: .init(provider: ScreenOnlyProvider(), bridge: bridge))
        model.mode = .live
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start()
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertEqual(model.activeRecord?.phase, .completed, model.status)
        XCTAssertNotNil(model.latestFrame)
        XCTAssertTrue(model.approvalRecords.records.isEmpty)
        let inputs = await transport.inputs
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(model.lifecycle.checkpoint?.tools.first(where: { $0.name == "screenshot" })?.delivery, .observedResult)
    }
    func testLiveUSBTaskCompletesInBackgroundWithoutPerActionApproval() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        model.mode = .live // Real routing policy; provider and USB remain offline fixtures.
        var presentedApproval = false
        let observation = model.$approval.sink { if $0 != nil { presentedApproval = true } }
        // Keep delivering frames and heartbeats through dispatch and observation.
        let ticker = Task {
            while !Task.isCancelled {
                if model.activitySnapshot?.state.phase == .executing { source.health.receivedPing(source.token) }
                else { source.push() }
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
        defer { ticker.cancel(); observation.cancel(); model.stop() }
        model.start(); model.setScene(.inactive); model.setScene(.background)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertFalse(presentedApproval)
        let inputs = await transport.inputs
        XCTAssertEqual(inputs.count, 1, "status=\(model.status)")
        XCTAssertEqual(model.activeRecord?.phase, .completed)
        XCTAssertEqual(model.lifecycle.checkpoint?.tools.first(where: { $0.name == "tap" })?.delivery, .observedResult)
        XCTAssertEqual(model.approvalRecords.records.count, 1)
        XCTAssertEqual(model.approvalRecords.records.first?.authorizationMode, .task)
        XCTAssertEqual(model.approvalRecords.records.first?.state, .finished)
        XCTAssertTrue(model.usbDiagnosticReport().contains("input.authorized source=task tool=tap"))
    }
    func testTaskAuthorizationStillRevokesAtStopLockCaptureLossAndUSBFailure() async throws {
        for loss in ["stop", "lock", "capture", "usb"] {
            let source = try SyntheticCapture(), transport = GuardedUSBFixture(delay: 500_000_000)
            let model = try model(source, transport: transport)
            model.mode = .live
            let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
            defer { ticker.cancel(); model.stop() }
            model.start(); model.setScene(.background)
            try await waitUntil { model.approvalRecords.records.contains { $0.state == .executing } }
            XCTAssertNil(model.approval)
            ticker.cancel()
            switch loss {
            case "stop": model.stop()
            case "lock": model.setProtectedDataAvailable(false)
            case "capture": source.frames.invalidate()
            default: source.health.invalidate()
            }
            try await waitUntil { !model.running && !model.stopping }
            let inputs = await transport.inputs, released = await transport.stopped
            XCTAssertTrue(inputs.isEmpty, loss); XCTAssertTrue(released, loss)
            source.push(); model.setScene(.active); model.setScene(.background)
            XCTAssertFalse(model.running, "A fresh frame cannot restart a revoked task")
        }
    }
    func testCaptureExecutionDoesNotSubmitSystemProcessingAndOptOutHasNoFallback() throws {
        let source = try SyntheticCapture(), system = SystemSchedulerSpy()
        let scheduler = RunExecutionScheduler(continued: system)
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true)
        scheduler.configure(context: context, allowSystemProcessing: true)
        var lease: (any RunBackgroundLease)?
        try scheduler.submit(identifier: "capture", launched: { lease = $0 })
        XCTAssertNotNil(lease); XCTAssertEqual(system.submissions, 0)
        lease?.complete(success: true); scheduler.cancel(identifier: "capture")
        let optOut = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: false)
        scheduler.configure(context: optOut, allowSystemProcessing: true)
        XCTAssertThrowsError(try scheduler.submit(identifier: "opt-out", launched: { _ in XCTFail() }))
        XCTAssertEqual(system.submissions, 0)
    }
    func testPerActionRouteRequiresForegroundApprovalAndExecutesOnlyOnce() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture(stopDelay: 350_000_000)
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.inactive); model.setScene(.background)
        XCTAssertTrue(model.running)
        try await waitUntil { model.approval != nil }
        XCTAssertEqual(model.lifecycle.checkpoint?.phase, .waitingApproval)
        XCTAssertFalse(model.lifecycle.hasLease)
        model.approve(true) // Background/lock-screen approval must be ignored.
        XCTAssertNotNil(model.approval)
        let beforeApproval = await transport.inputs; XCTAssertTrue(beforeApproval.isEmpty)
        model.setScene(.active); model.approve(true)
        // PA3 baseline 80b1c8f permits input in PhoneAgent after approval.
        // Leaving foreground is no longer an additional authorization step.
        try await waitUntil { model.lifecycle.checkpoint?.tools.contains { $0.name == "tap" && $0.delivery == .acknowledged } == true }
        model.setScene(.inactive); model.setScene(.background)
        try await waitUntil { !model.running }
        let inputs = await transport.inputs
        XCTAssertEqual(inputs.count, 1, "status=\(model.status); checkpoint=\(model.lifecycle.checkpoint?.message ?? "none")")
        XCTAssertEqual(model.activeRecord?.phase, .completed)
        XCTAssertEqual(model.lifecycle.checkpoint?.tools.first(where: { $0.name == "tap" })?.delivery, .observedResult)
    }
    func testSiriTaskGrantAndLiveActivityNavigationPreserveBackgroundUSBCompletion() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let service = SessionCommandService(sessions: model.sessions, runner: model)
        let ticker = Task {
            while !Task.isCancelled {
                if model.activitySnapshot?.state.phase == .executing { source.health.receivedPing(source.token) }
                else { source.push() }
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
        defer { ticker.cancel(); model.stop() }
        guard case .prepared(let id) = try service.perform(SessionCommand(.prepare("演示整合流程"))) else { return XCTFail() }
        model.selectConversation(id)
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.send("演示整合流程", in: id))
        XCTAssertTrue(model.send("演示整合流程", in: id, cloudConsent: true))
        model.setScene(.background)
        let run = try XCTUnwrap(model.currentRun)
        let stop = service.cancelCurrentCommand()
        XCTAssertNil(model.approval)
        XCTAssertNil(model.activitySnapshot?.state.approvalID)
        guard case .prepared(let later) = try service.perform(SessionCommand(.prepare("下一条草稿"))) else { return XCTFail() }
        XCTAssertEqual(try service.perform(SessionCommand(.open, sessionID: later)), .open(later))
        XCTAssertEqual(model.currentRun, run)
        let link = AgentActivityRoute(sessionID: run.conversationID, runID: run.runID).url
        XCTAssertTrue(model.openActivityURL(link))
        model.leaveControlDebug() // Navigation to this same run never grants/revokes inputs.
        XCTAssertTrue(model.running); XCTAssertNil(model.approval)
        try await waitUntil { !model.running && !model.stopping }
        let after = await transport.inputs; XCTAssertEqual(after.count, 1, "status=\(model.status); checkpoint=\(model.lifecycle.checkpoint?.message ?? "none")")
        XCTAssertEqual(model.activitySnapshot?.state.phase, .completed)
        XCTAssertNil(model.activitySnapshot?.state.approvalID)
        XCTAssertEqual(model.approvalRecords.records.first?.authorizationMode, .task)
        XCTAssertEqual(try service.perform(stop), .noMatchingRun)
        XCTAssertEqual(model.sessions.conversation(id)?.entry?.state, .submitted)
        XCTAssertEqual(model.sessions.conversation(later)?.entry?.state, .pendingConfirmation)
        XCTAssertTrue(model.openActivityURL(link)) // Historical link only shows records.
        model.approve(true)
        let repeated = await transport.inputs; XCTAssertEqual(repeated.count, 1)
    }
    func testSiriScopedStopRevokesApprovalAndDebugExitPreservesRun() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let service = SessionCommandService(sessions: model.sessions, runner: model)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        let run = try XCTUnwrap(model.currentRun), request = try XCTUnwrap(model.approval)
        XCTAssertEqual(try service.perform(service.cancelCurrentCommand()), .cancelled)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertFalse(model.approvalRecords.isPending(request, run: run))
        XCTAssertEqual(model.activitySnapshot?.state.phase, .stopped)
        model.setScene(.active); model.approve(true)
        let sent = await transport.inputs, released = await transport.stopped
        XCTAssertTrue(sent.isEmpty); XCTAssertTrue(released)
        let another = try self.model(source, transport: GuardedUSBFixture())
        another.start()
        let newRun = try XCTUnwrap(another.currentRun)
        XCTAssertTrue(another.openActivityURL(AgentActivityRoute(sessionID: newRun.conversationID, runID: newRun.runID, approvalID: nil).url))
        another.enterControlDebug()
        another.leaveControlDebug()
        XCTAssertTrue(another.running)
        another.stop()
        try await waitUntil { !another.running && !another.stopping }
        XCTAssertEqual(another.activeRecord?.phase, .stopped)
    }
    func testCaptureLossBeforeEnqueueStopsInputEvenWhenFramesChange() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture(delay: 500_000_000)
        let model = try model(source, transport: transport)
        let target = TargetState()
        let ticker = Task { while !Task.isCancelled { source.push(alternate: target.changed); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        model.setScene(.active); model.approve(true)
        target.changed = true; source.push(alternate: true); model.setScene(.background)
        try await Task.sleep(nanoseconds: 100_000_000)
        let inputs = await transport.inputs; XCTAssertTrue(inputs.isEmpty)
        source.frames.invalidate()
        try await waitUntil { !model.running && !model.stopping }
        let released = await transport.stopped; XCTAssertTrue(released)
        model.setScene(.active); model.approve(true)
        let after = await transport.inputs; XCTAssertTrue(after.isEmpty)
    }
    func testLockDuringApprovalStopsAndUnlockNeverResumes() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        model.setProtectedDataAvailable(false)
        try await waitUntil { !model.running && !model.stopping }
        model.setProtectedDataAvailable(true); model.setScene(.active); model.approve(true)
        let inputs = await transport.inputs, released = await transport.stopped
        XCTAssertTrue(inputs.isEmpty); XCTAssertTrue(released); XCTAssertFalse(model.running)
    }
    func testUnknownUSBExecutionPersistsUnknownAndNeverReplays() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture(fail: true)
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        model.setScene(.active); model.approve(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        model.setScene(.background)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertEqual(model.lifecycle.checkpoint?.tools.first(where: { $0.name == "tap" })?.delivery, .outcomeUnknown)
        model.setScene(.active); model.approve(true)
        let inputs = await transport.inputs; XCTAssertEqual(inputs.count, 1)
    }
    func testCaptureLossWhileAwaitingApprovalReleasesWithoutSending() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        source.frames.invalidate()
        try await waitUntil { !model.running && !model.stopping }
        let inputs = await transport.inputs, released = await transport.stopped
        XCTAssertTrue(inputs.isEmpty); XCTAssertTrue(released)
    }
    func testUSBDisconnectWhileAwaitingApprovalStopsAndCannotBeRevived() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        ticker.cancel(); source.health.invalidate()
        try await waitUntil { !model.running && !model.stopping }
        source.push(); model.setScene(.active); model.approve(true)
        let inputs = await transport.inputs, released = await transport.stopped
        XCTAssertTrue(inputs.isEmpty); XCTAssertTrue(released); XCTAssertFalse(model.running)
    }
}
