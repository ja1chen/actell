import XCTest
import CoreVideo
import CoreMedia
import ImageIO
import Network
import Darwin
@testable import PhoneAgent

private actor USBSpy: USBCommandTransport {
    private(set) var commands: [String] = []
    private(set) var stopped = false
    var failInput: Bool
    let beforeACK: @Sendable () -> Void
    init(failInput: Bool = false, beforeACK: @escaping @Sendable () -> Void = {}) {
        self.failInput = failInput; self.beforeACK = beforeACK
    }
    func command(_ body: String) async throws {
        commands.append(body)
        if body != "PING" {
            beforeACK()
            if failInput { throw AppError.unknownOutcome }
        }
    }
    func stopInputs(_ session: USBInputSession) async { stopped = true }
}

private struct ImmutableTestPixel: @unchecked Sendable { let pixel: CVPixelBuffer }

private actor USBSessionFixture: USBConnectionSession {
    nonisolated let health = USBTransportHealth()
    let supportsHID = true
    private var token = UUID()
    private(set) var connections = 0
    private(set) var stops = 0
    private(set) var commands: [String] = []
    func connect(attempt: UUID) async throws {
        token = attempt; connections += 1; health.begin(token)
    }
    func command(_ body: String) async throws {
        commands.append(body)
        if body == "PING" { health.receivedPing(token) }
    }
    func stopInputs(_ session: USBInputSession) async {}
    func disconnect() async { stops += 1; health.invalidate(token) }
}

final class USBCaptureTests: XCTestCase {
    @MainActor private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for USB view-model transition")
    }
    @MainActor func testIdleHIDConnectionSurvivesInactivePickerWithoutInputPermission() async throws {
        let transport = USBSessionFixture()
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  makeUSBClient: { _, _ in transport })
        model.connectUSB()
        try await waitUntil { !model.isListening }
        XCTAssertEqual(model.usbConnectionStatus, .ready(hid: true))
        model.setScene(.inactive)
        XCTAssertFalse(model.stopping)
        XCTAssertEqual(model.usbConnectionStatus, .ready(hid: true))
        XCTAssertFalse(model.running)
        model.setScene(.active)
        let stops = await transport.stops, commands = await transport.commands
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(commands, ["PING"], "Preserving an idle connection never sends input")
        XCTAssertTrue(model.usbDiagnosticReport().contains("idleUSB.preserved reason=scene_inactive"))
        model.disconnect()
        try await waitUntil { !model.stopping }
        let closed = await transport.stops; XCTAssertEqual(closed, 1)
    }
    @MainActor func testIdleConnectionSurvivesBackgroundAndRepeatedConnectIsNoOp() async throws {
        let transport = USBSessionFixture()
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  makeUSBClient: { _, _ in transport })
        model.connectUSB(); try await waitUntil { !model.isListening }
        model.setScene(.inactive); model.setScene(.background)
        XCTAssertEqual(model.usbConnectionStatus, .ready(hid: true))
        model.setScene(.active); model.connectUSB()
        try await waitUntil { !model.isListening }
        let connections = await transport.connections, stops = await transport.stops
        XCTAssertEqual(connections, 1); XCTAssertEqual(stops, 0)
        XCTAssertTrue(model.usbDiagnosticReport().contains("idleUSB.preserved reason=scene_background"))
        model.disconnect(); try await waitUntil { !model.stopping }
        let closed = await transport.stops; XCTAssertEqual(closed, 1)
    }
    @MainActor func testLockAndCaptureLossPreserveIdleConnectionWithoutGrantingInputs() async throws {
        for locked in [true, false] {
            let transport = USBSessionFixture()
            let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                      makeUSBClient: { _, _ in transport })
            model.connectUSB(); try await waitUntil { !model.isListening }
            model.setScene(.inactive)
            if locked { model.setProtectedDataAvailable(false) } else { model.capture.onLoss?() }
            try await waitUntil { !model.stopping }
            let stops = await transport.stops, commands = await transport.commands
            XCTAssertEqual(stops, 0); XCTAssertEqual(commands, ["PING"])
            XCTAssertEqual(model.usbConnectionStatus, .ready(hid: true))
            model.disconnect(); try await waitUntil { !model.stopping }
        }
    }
    @MainActor func testTwoCompletedTasksReuseConnectionAndUserStopDoesNotDisconnect() async throws {
        let transport = USBSessionFixture()
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  makeUSBClient: { _, _ in transport })
        model.connectUSB(); try await waitUntil { !model.isListening }
        for _ in 0..<2 {
            model.start(); try await waitUntil { model.approval != nil }
            model.approve(true); try await waitUntil { !model.running && !model.stopping }
            XCTAssertEqual(model.activeRecord?.phase, .completed)
            XCTAssertEqual(model.usbConnectionStatus, .ready(hid: true))
        }
        model.start(); model.stop(); try await waitUntil { !model.stopping }
        XCTAssertEqual(model.usbConnectionStatus, .ready(hid: true))
        let connections = await transport.connections, stops = await transport.stops
        XCTAssertEqual(connections, 1); XCTAssertEqual(stops, 0)
        model.disconnect(); try await waitUntil { !model.stopping }
        let closed = await transport.stops; XCTAssertEqual(closed, 1)
    }
    func testMissingUSBRouteReportsReconnectAndLogsMetadataWithoutRawStatus() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin()
        frames.put(try pixel(), orientation: 1, presentationSeconds: 1, epoch: epoch)
        let diagnostics = USBDiagnosticsLog(console: false)
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true, usb: nil,
            backgroundEnabled: true, usbStatus: .disconnected("private-task-text"), diagnostics: diagnostics)
        let image = try await bridge.screenshot()
        do { try await bridge.approvalContext(imageID: image.id); XCTFail("No USB cannot approve input") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("USB 已断开"))
            XCTAssertTrue(error.localizedDescription.contains("重新连接"))
            XCTAssertTrue(error.localizedDescription.contains("新任务"))
            XCTAssertFalse(error.localizedDescription.contains("private-task-text"))
        }
        XCTAssertTrue(diagnostics.report().contains("selected=localScreen reason=usbClientMissing usbState=disconnected"))
        XCTAssertFalse(diagnostics.report().contains("private-task-text"))
        await bridge.stop()
    }
    private func pixel() throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let result = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(result, [])
        memset(CVPixelBufferGetBaseAddress(result), 120, CVPixelBufferGetDataSize(result))
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
    func testLatestOnlyOrientationEncodingAndEpochFence() throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        for i in 0..<100 { frames.put(image, orientation: 6, presentationSeconds: Double(i), epoch: epoch) }
        let encoded = try frames.encoded(maxDimension: 4)
        XCTAssertEqual(encoded.capture?.sequence, 100)
        XCTAssertEqual(encoded.capture?.width, 8); XCTAssertEqual(encoded.capture?.height, 4)
        XCTAssertEqual(encoded.capture?.videoOrientation, 6)
        XCTAssertEqual(encoded.width, 2); XCTAssertEqual(encoded.height, 4)
        XCTAssertEqual(Array(encoded.png.prefix(8)), [137,80,78,71,13,10,26,10])
        frames.invalidate()
        frames.put(image, orientation: 1, presentationSeconds: 101, epoch: epoch)
        XCTAssertThrowsError(try frames.encoded())
        let newEpoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 102, epoch: epoch)
        XCTAssertThrowsError(try frames.latestStamp())
        frames.put(image, orientation: 1, presentationSeconds: 103, epoch: newEpoch)
        frames.invalidate(epoch: epoch) // A late stop from the old stream cannot stop the new one.
        XCTAssertNoThrow(try frames.latestStamp())
    }
    func testStaticFrameDoesNotExpireButInvalidOrientationAndCaptureLossStillFail() throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 0, presentationSeconds: 1, epoch: epoch)
        XCTAssertThrowsError(try frames.latestStamp())
        let arrived = ProcessInfo.processInfo.systemUptime - 3_600
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch, now: arrived)
        XCTAssertEqual(try frames.latestStamp().uptime, arrived)
        XCTAssertEqual(try frames.encoded().capture?.uptime, arrived, "Reading must not pretend an old sample just arrived")
        XCTAssertNoThrow(try frames.requireSession(epoch))
        frames.invalidate()
        XCTAssertThrowsError(try frames.latestStamp())
        XCTAssertThrowsError(try frames.encoded())
        XCTAssertThrowsError(try frames.requireSession(epoch))
    }
    func testLocalCaptureRoutesWithoutUSB() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin()
        frames.put(try pixel(), orientation: 6, presentationSeconds: 1, epoch: epoch)
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true, usb: nil, backgroundEnabled: false)
        let frame = try await bridge.screenshot()
        XCTAssertFalse(frame.isDemo)
        XCTAssertEqual(frame.capture?.sequence, 1)
        XCTAssertEqual(frame.width, 4); XCTAssertEqual(frame.height, 8)
        XCTAssertEqual(Array(frame.png.prefix(8)), [137,80,78,71,13,10,26,10])
        let background = await bridge.supportsBackgroundExecution(tool: "screenshot")
        XCTAssertFalse(background, "Capture-only does not grant background Agent execution")
        await bridge.stop()
        XCTAssertNoThrow(try frames.encoded(), "Ending a reader must not revoke the shared system capture")
    }
    func testCaptureRouteRequiresSystemAuthorizationButNoExtraUploadToggle() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin()
        frames.put(try pixel(), orientation: 1, presentationSeconds: 1, epoch: epoch)
        let blocked = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: false,
            usb: nil, backgroundEnabled: false)
        do { _ = try await blocked.screenshot(); XCTFail("System authorization is mandatory") }
        catch { XCTAssertEqual(error.localizedDescription, UnavailableBridge.screenshotMessage) }
        let allowed = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true,
            usb: nil, backgroundEnabled: false)
        let image = try await allowed.screenshot()
        XCTAssertNotNil(image.capture)
    }
    func testReaderCreatedBeforeFirstFrameWaitsForTheSameCaptureSession() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin()
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true,
            usb: nil, backgroundEnabled: false)
        let read = Task { try await bridge.screenshot() }
        try await Task.sleep(nanoseconds: 100_000_000)
        frames.put(try pixel(), orientation: 6, presentationSeconds: 1, epoch: epoch)
        let image = try await read.value
        XCTAssertEqual(image.capture?.sequence, 1)
        XCTAssertEqual(image.capture?.videoOrientation, 6)
        await bridge.stop()
    }
    func testFirstFrameWaitTimesOutWithMetadataAndRejectsReplacementSession() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin()
        frames.recordSample(epoch: epoch, rejection: "missingVideoOrientation")
        do { _ = try await frames.waitForFrame(epoch: epoch, timeout: 0.05); XCTFail("Must time out") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("samples=1"))
            XCTAssertTrue(error.localizedDescription.contains("missingVideoOrientation=1"))
        }
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true,
            usb: nil, backgroundEnabled: false)
        let read = Task { try await bridge.screenshot() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let replacement = frames.begin()
        frames.put(try pixel(), orientation: 1, presentationSeconds: 1, epoch: replacement)
        do { _ = try await read.value; XCTFail("A reader cannot adopt a later authorization") } catch {}
        let cancel = Task { try await frames.waitForFrame(epoch: replacement, notBefore: .greatestFiniteMagnitude) }
        cancel.cancel()
        do { _ = try await cancel.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCaptureOnlyBackgroundNeedsPreferenceAndNewTargetFrameButNeverAuthorizesInput() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin(), image = try pixel()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true,
            usb: nil, backgroundEnabled: true)
        let supports = await bridge.supportsBackgroundExecution(tool: "screenshot")
        XCTAssertTrue(supports)
        let supportsInput = await bridge.supportsBackgroundExecution(tool: "tap")
        XCTAssertFalse(supportsInput)
        let context = try XCTUnwrap(bridge.executionContext)
        context.setScene(.inactive); context.setScene(.background)
        let read = Task { try await bridge.screenshot() }
        try await Task.sleep(nanoseconds: 250_000_000)
        frames.put(image, orientation: 1, presentationSeconds: 2, epoch: epoch)
        let result = try await read.value
        XCTAssertEqual(result.capture?.sequence, 2)
        let scope = try XCTUnwrap(context.captureObservation())
        XCTAssertThrowsError(try context.enqueue(observation: scope, sequence: 2) { XCTFail("Read-only cannot send HID") })
        context.revoke()
        do { _ = try await bridge.screenshot(); XCTFail("Revoked") } catch {}
    }
    func testOrientationMetadataAcceptsTypedAndNumericValuesWithoutGuessing() {
        XCTAssertEqual(CaptureSampleMetadata.orientation(CGImagePropertyOrientation.right), 6)
        XCTAssertEqual(CaptureSampleMetadata.orientation(NSNumber(value: 8)), 8)
        let invalidValues: [Any?] = [nil, NSNumber(value: true), NSNumber(value: 0), NSNumber(value: 9), NSNumber(value: 1.5), "6"]
        for invalid in invalidValues {
            XCTAssertNil(CaptureSampleMetadata.orientation(invalid))
        }
    }
    private let orientationKey = "fixture.videoOrientation"
    private func sampleBuffer() throws -> CMSampleBuffer {
        let image = try pixel()
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: 1, timescale: 60), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing, sampleBufferOut: &buffer), noErr)
        return try XCTUnwrap(buffer)
    }
    private func setSampleOrientation(_ value: NSNumber, in buffer: CMSampleBuffer) throws {
        let array = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        let key = orientationKey as CFString
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
    }
    func testBufferLevelOrientationReachesEncodedFrameEvenWhenSampleDictionaryHasNoOrientation() throws {
        for orientation in 1...8 {
            let buffer = try sampleBuffer()
            CMSetAttachment(buffer, key: orientationKey as CFString,
                value: NSNumber(value: orientation), attachmentMode: kCMAttachmentMode_ShouldPropagate)
            let perSample = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [[String: Any]])?.first
            XCTAssertNil(perSample?[orientationKey], "The old per-sample-only reader would discard this valid buffer")
            let metadata = CaptureSampleMetadata.videoOrientation(in: buffer, key: orientationKey)
            XCTAssertEqual(metadata.value, UInt32(orientation)); XCTAssertNil(metadata.rejection)
            XCTAssertTrue(metadata.diagnostic.contains("sample=absent buffer=number:"))
            XCTAssertTrue(metadata.diagnostic.contains("source=buffer"))
            let frames = LatestScreenFrame(), epoch = frames.begin()
            frames.recordSample(epoch: epoch, orientation: metadata.diagnostic)
            frames.put(try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer)), orientation: try XCTUnwrap(metadata.value),
                presentationSeconds: buffer.presentationTimeStamp.seconds, epoch: epoch)
            let image = try frames.encoded()
            XCTAssertEqual(image.capture?.videoOrientation, UInt32(orientation))
            XCTAssertEqual(image.width, orientation <= 4 ? 8 : 4)
            XCTAssertEqual(image.height, orientation <= 4 ? 4 : 8)
            XCTAssertEqual(frames.diagnostics().accepted, 1)
            XCTAssertTrue(frames.diagnostics().summary.contains("source=buffer"))
        }
    }
    func testPerSampleOrientationAndMatchingBufferMetadataRemainSupported() throws {
        let buffer = try sampleBuffer()
        try setSampleOrientation(NSNumber(value: 6), in: buffer)
        XCTAssertNil(CMGetAttachment(buffer, key: orientationKey as CFString, attachmentModeOut: nil))
        var metadata = CaptureSampleMetadata.videoOrientation(in: buffer, key: orientationKey)
        XCTAssertEqual(metadata.value, 6); XCTAssertNil(metadata.rejection)
        XCTAssertTrue(metadata.diagnostic.contains("source=sample"))
        CMSetAttachment(buffer, key: orientationKey as CFString, value: NSNumber(value: 6),
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        metadata = CaptureSampleMetadata.videoOrientation(in: buffer, key: orientationKey)
        XCTAssertEqual(metadata.value, 6); XCTAssertNil(metadata.rejection)
        XCTAssertTrue(metadata.diagnostic.contains("source=both"))
    }
    func testConflictingOrMalformedOrientationCannotFallBackToAnotherValue() throws {
        let buffer = try sampleBuffer()
        try setSampleOrientation(NSNumber(value: 6), in: buffer)
        CMSetAttachment(buffer, key: orientationKey as CFString, value: NSNumber(value: 8),
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        var metadata = CaptureSampleMetadata.videoOrientation(in: buffer, key: orientationKey)
        XCTAssertNil(metadata.value); XCTAssertEqual(metadata.rejection, "conflictingVideoOrientation")
        for invalid in [NSNumber(value: 0), NSNumber(value: 9), NSNumber(value: 1.5), NSNumber(value: true)] {
            CMSetAttachment(buffer, key: orientationKey as CFString, value: invalid,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            metadata = CaptureSampleMetadata.videoOrientation(in: buffer, key: orientationKey)
            XCTAssertNil(metadata.value); XCTAssertEqual(metadata.rejection, "invalidVideoOrientation")
        }
    }
    func testOrientationDiagnosticsDistinguishMissingAndInvalidWithoutExportingAttachmentContents() throws {
        let buffer = try sampleBuffer()
        let missing = CaptureSampleMetadata.videoOrientation(in: buffer, key: orientationKey)
        XCTAssertNil(missing.value); XCTAssertEqual(missing.rejection, "missingVideoOrientation")
        XCTAssertEqual(missing.diagnostic, "sample=absent buffer=absent")
        let privateValue = "private-content-must-not-be-logged"
        CMSetAttachment(buffer, key: orientationKey as CFString, value: privateValue as CFString,
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        CMSetAttachment(buffer, key: "unrelated" as CFString, value: privateValue as CFString,
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let invalid = CaptureSampleMetadata.videoOrientation(in: buffer, key: orientationKey)
        XCTAssertNil(invalid.value); XCTAssertEqual(invalid.rejection, "invalidVideoOrientation")
        XCTAssertEqual(invalid.diagnostic, "sample=absent buffer=string")
        let frames = LatestScreenFrame(), old = frames.begin()
        frames.recordSample(epoch: old, rejection: invalid.rejection, orientation: invalid.diagnostic)
        XCTAssertFalse(frames.diagnostics().summary.contains(privateValue))
        XCTAssertFalse(frames.diagnostics().summary.contains("unrelated"))
        _ = frames.begin()
        frames.recordSample(epoch: old, orientation: invalid.diagnostic)
        XCTAssertNil(frames.diagnostics().orientationMetadata, "Late metadata must not cross capture epochs")
    }
    func testSystemStopAndFailedStartNeverRequestAnotherSDKStop() throws {
        for didStart in [false, true] {
            var state = CaptureStreamLifecycle()
            let first = try XCTUnwrap(state.begin())
            if didStart { XCTAssertFalse(state.started(first)) }
            XCTAssertTrue(state.ended(first)) // delegate stop or failed start
            XCTAssertFalse(state.requestStop())
            XCTAssertFalse(state.ended(first))
            let next = try XCTUnwrap(state.begin())
            XCTAssertFalse(state.ended(first), "Old callbacks cannot end a new stream")
            XCTAssertTrue(state.owns(next))
        }
    }
    func testStopDuringStartWaitsAndRepeatedStopsAreIdempotent() throws {
        for stopDuringStart in [false, true] {
            var state = CaptureStreamLifecycle()
            let token = try XCTUnwrap(state.begin())
            if stopDuringStart {
                XCTAssertFalse(state.requestStop(), "Never stop an unstarted stream")
                XCTAssertFalse(state.requestStop())
                XCTAssertTrue(state.started(token), "Start completion owns the deferred stop")
            } else {
                XCTAssertFalse(state.started(token))
                XCTAssertTrue(state.requestStop())
            }
            XCTAssertFalse(state.requestStop(), "Exactly one SDK stop per stream")
            XCTAssertNil(state.begin(), "Do not overlap a new capture with shutdown")
            XCTAssertTrue(state.ended(token))
            XCTAssertFalse(state.started(token), "Late start completion must not stop again")
        }
    }
    func testNCMOnlyCaptureFeedsAgentToolButRejectsInputsBeforeApproval() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin(), transport = USBSpy()
        frames.put(try pixel(), orientation: 1, presentationSeconds: 1, epoch: epoch)
        // Deliberately no healthy PING: read-only capture cannot depend on USB.
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true, usb: .init(transport: transport, health: USBTransportHealth(), supportsHID: false), backgroundEnabled: true)
        let action = ActionCoordinator(bridge: bridge, limits: AgentLimits(),
            approve: { _ in XCTFail("NCM-only must not present a useless input approval"); return true },
            onImage: { _, _ in }, onReceipt: { _ in })
        let shot = try await action.execute(name: "screenshot", parameters: [:], callID: "local-shot")
        XCTAssertEqual(shot.images.count, 1)
        do {
            _ = try await action.execute(name: "tap", parameters: ["x": 1, "y": 1, "purpose": "fixture"], callID: "no-hid")
            XCTFail("NCM-only cannot send input")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HID")) }
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty, "Capturing must not issue USB commands")
        await action.stop()
    }
    func testUnhealthyHIDTransportDoesNotBlockLocalScreenshotOrGainInputPermission() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin(), transport = USBSpy()
        frames.put(try pixel(), orientation: 1, presentationSeconds: 1, epoch: epoch)
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true, usb: .init(transport: transport, health: USBTransportHealth(), supportsHID: true), backgroundEnabled: false)
        let frame = try await bridge.screenshot()
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("No USB lease") }
        catch { XCTAssertTrue(error.localizedDescription.contains("USB 输入条件已失效")) }
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
        await bridge.stop()
    }
    func testCaptureReaderRetainsStaticFrameButRejectsCancellationOrNewCaptureEpoch() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true, usb: nil, backgroundEnabled: false)
        _ = try await bridge.screenshot()
        frames.put(image, orientation: 1, presentationSeconds: 2, epoch: epoch, now: ProcessInfo.processInfo.systemUptime - 3_600)
        let retained = try await bridge.screenshot()
        XCTAssertEqual(retained.capture?.sequence, 2)
        let replacement = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 3, epoch: replacement)
        do { _ = try await bridge.screenshot(); XCTFail("Must not cross system capture authorization epochs") } catch {}
        let current = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true, usb: nil, backgroundEnabled: false)
        current.cancelTransport()
        do { _ = try await current.screenshot(); XCTFail("Synchronous scene/lock cancellation must revoke reads") } catch {}
        XCTAssertNoThrow(try frames.encoded())
    }
    func testHealthyHIDRouteKeepsApprovalAndDisconnectFences() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let health = USBTransportHealth(), token = UUID(), transport = USBSpy()
        health.begin(token); health.receivedPing(token)
        let bridge = try LiveDeviceBridgeRouter.make(frames: frames, captureActive: true, usb: .init(transport: transport, health: health, supportsHID: true), backgroundEnabled: false)
        XCTAssertTrue(bridge is USBDeviceBridge)
        let frame = try await bridge.screenshot()
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("Approval is required") } catch {}
        var commands = await transport.commands; XCTAssertTrue(commands.isEmpty)
        try await bridge.acceptApproval(imageID: frame.id)
        try await bridge.tap(x: 0, y: 0, imageID: frame.id)
        commands = await transport.commands; XCTAssertEqual(commands, ["TAP 0 0"])
        health.invalidate(token)
        do { _ = try await bridge.screenshot(); XCTFail("Input-capable runs still stop on USB loss") } catch {}
        await bridge.stop()
    }
    func testUSBInputAcceptsUnchangedFrameOlderThanAllFormerImageDeadlines() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin(), transport = USBSpy()
        frames.put(try pixel(), orientation: 1, presentationSeconds: 1, epoch: epoch,
                   now: ProcessInfo.processInfo.systemUptime - 3_600)
        let health = USBTransportHealth(), token = UUID()
        health.begin(token); health.receivedPing(token)
        let context = try ScreenUSBExecutionContext(frames: frames, health: health, backgroundEnabled: false)
        // Use the same protocol dispatch as ActionCoordinator, including the
        // actor-isolated approval witness rather than the extension default.
        let bridge: any DeviceBridge = USBDeviceBridge(frames: frames, transport: transport, context: context)
        let frame = try await bridge.screenshot()
        try await bridge.acceptApproval(imageID: frame.id)
        try await bridge.tap(x: 1, y: 2, imageID: frame.id)
        let commands = await transport.commands
        XCTAssertEqual(commands, ["TAP 1 2"])
        await bridge.stop()
    }
    func testPostACKBarrierRejectsFrameThatArrivedDuringAction() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let immutable = ImmutableTestPixel(pixel: image)
        let transport = USBSpy(beforeACK: { frames.put(immutable.pixel, orientation: 1, presentationSeconds: 2, epoch: epoch) })
        let bridge = USBDeviceBridge(frames: frames, transport: transport)
        let first = try await bridge.screenshot()
        try await bridge.tap(x: 65535, y: 0, imageID: first.id)
        let waiting = Task { try await bridge.screenshot() }
        try await Task.sleep(nanoseconds: 100_000_000)
        frames.put(image, orientation: 1, presentationSeconds: 3, epoch: epoch)
        let next = try await waiting.value
        XCTAssertEqual(next.capture?.sequence, 3)
        let commands = await transport.commands
        XCTAssertEqual(commands, ["TAP 65535 0"])
        await bridge.stop()
    }
    func testRotationCannotReviveStoppedInputSession() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let transport = USBSpy(), bridge = USBDeviceBridge(frames: frames, transport: transport)
        try await bridge.arm()
        let first = try await bridge.screenshot()
        await bridge.stop()
        frames.put(image, orientation: 6, presentationSeconds: 2, epoch: epoch)
        do { try await bridge.tap(x: 1, y: 1, imageID: first.id); XCTFail("New pixels cannot revive a stopped session") } catch {}
        let commands = await transport.commands, stopped = await transport.stopped
        XCTAssertTrue(commands.isEmpty); XCTAssertTrue(stopped)
    }
    func testUnknownOutcomeStopsAndNeverReplays() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let transport = USBSpy(failInput: true), bridge = USBDeviceBridge(frames: frames, transport: transport)
        let first = try await bridge.screenshot()
        for _ in 0..<2 {
            do { try await bridge.tap(x: 1, y: 1, imageID: first.id); XCTFail("input must fail") } catch {}
        }
        let commands = await transport.commands, stopped = await transport.stopped
        XCTAssertEqual(commands.count, 1); XCTAssertTrue(stopped)
    }
    func testStopInvalidatesScreenshotAndFurtherInput() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let transport = USBSpy(), bridge = USBDeviceBridge(frames: frames, transport: transport)
        let first = try await bridge.screenshot(); await bridge.stop()
        do { try await bridge.tap(x: 0, y: 0, imageID: first.id); XCTFail() } catch {}
        do { _ = try await bridge.screenshot(); XCTFail() } catch {}
        let commands = await transport.commands; XCTAssertTrue(commands.isEmpty)
    }
    func testPersistentGreetingRequiresPA3AndRejectsOldFirmware() throws {
        XCTAssertFalse(try USBWire.supportsHID("PA3 READY 0"))
        XCTAssertTrue(try USBWire.supportsHID("PA3 READY 1"))
        for line in ["PA1 LOCKED", "PA1 CHALLENGE " + String(repeating: "0", count: 64),
                     "PA2 READY 0", "PA2 READY 1", "READY 1", "PA3 READY 2", "PA3 READY 1 ", " PA3 READY 1", "PA3  READY 1"] {
            XCTAssertThrowsError(try USBWire.supportsHID(line), line)
        }
    }
    func testACKRequiresCanonicalIDAndExactPhase() throws {
        let ack = try USBWire.parseACK("4294967295 executed")
        XCTAssertEqual(ack.id, UInt64(UInt32.max)); XCTAssertEqual(ack.phase, "executed")
        XCTAssertEqual(try USBWire.parseACK("1 received").phase, "received")
        XCTAssertEqual(try USBWire.parseACK("1 cancelled").phase, "cancelled")
        for line in ["0 executed", "01 executed", "+1 executed", "4294967296 executed", "1 EXECUTED",
                     "1 executed mac", "1  executed", "1 executed ", "1\texecuted", "1 rejected"] {
            XCTAssertThrowsError(try USBWire.parseACK(line), line)
        }
    }
    func testReceivedIsNotExecutedAndOutOfOrderACKFails() throws {
        var received = false
        XCTAssertThrowsError(try USBWire.acceptACK("executed", needsReceipt: true, received: &received))
        XCTAssertFalse(try USBWire.acceptACK("received", needsReceipt: true, received: &received))
        XCTAssertTrue(received)
        XCTAssertThrowsError(try USBWire.acceptACK("received", needsReceipt: true, received: &received))
        XCTAssertTrue(try USBWire.acceptACK("executed", needsReceipt: true, received: &received))
        XCTAssertThrowsError(try USBWire.acceptACK("rejected", needsReceipt: true, received: &received))
    }
    func testTransportFailureReportsNetworkErrorBeforeInputButPreservesUnknownInputOutcome() {
        let error = NWError.posix(.ENETUNREACH)
        let beforeInput = USBWire.transportError(error, inputInFlight: false)
        guard case .unavailable(let message) = beforeInput else { return XCTFail("A failed connection is not a sent HID action") }
        XCTAssertTrue(message.contains(String(POSIXErrorCode.ENETUNREACH.rawValue)))
        XCTAssertEqual(USBWire.transportError(error, inputInFlight: true), .unknownOutcome)
        XCTAssertEqual(USBWire.transportError(nil, inputInFlight: true), .unknownOutcome)
    }
    func testHeartbeatTimeoutKeepsConcurrentInputOutcomeUnknown() {
        XCTAssertEqual(USBWire.receiptTimeout(isPing: true, inputInFlight: true), .unknownOutcome)
        XCTAssertEqual(USBWire.receiptTimeout(isPing: false, inputInFlight: true), .unknownOutcome)
        guard case .unavailable(let message) = USBWire.receiptTimeout(isPing: true, inputInFlight: false) else { return XCTFail() }
        XCTAssertTrue(message.contains("PING"))
        var received = false
        XCTAssertThrowsError(try USBWire.acceptACK("received", needsReceipt: false, received: &received)) { error in
            XCTAssertEqual(error as? AppError, .protocolViolation("USB ACK 阶段不匹配"))
        }
    }
    func testPermissionSheetOnlyPreservesInitialUSBSetupAndNeverBackground() {
        let setup: [USBConnectionStatus] = [.connecting, .waiting("localNetworkDenied"), .awaitingGreeting, .checking]
        for state in setup {
            XCTAssertTrue(state.allowsSetup(in: .active))
            XCTAssertTrue(state.allowsSetup(in: .inactive), "An initial permission sheet must not cancel setup")
            XCTAssertFalse(state.allowsSetup(in: .background), "Leaving the app must still cancel setup")
        }
        for state in [USBConnectionStatus.idle, .ready(hid: false), .ready(hid: true), .failed("down"), .disconnected("stopped")] {
            XCTAssertFalse(state.allowsSetup(in: .inactive), "Existing input sessions must retain the old stop policy")
            XCTAssertFalse(state.allowsSetup(in: .background))
        }
    }
    private func interfaceRow(name: String = "en77", index: UInt32 = 77,
                              address: String = "192.168.7.2", mask: String = "255.255.255.0",
                              flags: UInt32 = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST),
                              linkType: UInt8? = UInt8(IFT_ETHER)) -> USBInterfaceBinding.Row {
        USBInterfaceBinding.Row(name: name, index: index, address: address, mask: mask, flags: flags, linkType: linkType)
    }
    func testUSBInterfaceSelectionUsesFixedIPNotInterfaceNameOrDefaultPath() throws {
        let usb = interfaceRow(name: "en77")
        let unrelated = interfaceRow(name: "en0", address: "192.168.1.2")
        XCTAssertEqual(try USBInterfaceBinding.select([unrelated, usb]), usb)
    }
    func testUSBInterfaceSelectionRejectsMissingAmbiguousAndUnsafeInterfaces() {
        XCTAssertThrowsError(try USBInterfaceBinding.select([]))
        XCTAssertThrowsError(try USBInterfaceBinding.select([interfaceRow(), interfaceRow(name: "en88", index: 88)]))
        let complete = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let invalid = [interfaceRow(index: 0), interfaceRow(mask: "255.255.0.0"),
                       interfaceRow(flags: complete & ~UInt32(IFF_UP)),
                       interfaceRow(flags: complete & ~UInt32(IFF_RUNNING)),
                       interfaceRow(flags: complete & ~UInt32(IFF_BROADCAST)),
                       interfaceRow(flags: complete | UInt32(IFF_POINTOPOINT)),
                       interfaceRow(flags: complete | UInt32(IFF_LOOPBACK)),
                       interfaceRow(linkType: nil), interfaceRow(linkType: 0)]
        for row in invalid { XCTAssertThrowsError(try USBInterfaceBinding.select([row]), "\(row)") }
    }
    func testUSBInterfaceTypeNeverPermitsWiFiCellularOrLoopback() {
        XCTAssertNoThrow(try USBInterfaceBinding.validateType(.wiredEthernet))
        XCTAssertNoThrow(try USBInterfaceBinding.validateType(.other)) // Physical checks precede this classification.
        for type in [NWInterface.InterfaceType.wifi, .cellular, .loopback] {
            XCTAssertThrowsError(try USBInterfaceBinding.validateType(type))
        }
    }
    func testScopedAddressAndParametersRequireExactInterfaceWithoutConnecting() throws {
        // Exercise the actual public Network parser and parameter objects on
        // loopback; no socket/connection or device traffic is created.
        let address = try XCTUnwrap(IPv4Address("127.0.0.1%lo0"))
        let interface = try XCTUnwrap(address.interface)
        XCTAssertEqual(interface.name, "lo0")
        XCTAssertEqual(interface.index, Int(if_nametoindex("lo0")))
        XCTAssertNil(IPv4Address("192.168.7.1%phoneagent_missing_interface_999"))
        let binding = USBInterfaceBinding(row: interfaceRow(name: "lo0", index: UInt32(interface.index)),
                                          interface: interface, localAddress: address, remoteAddress: address)
        let parameters = binding.parameters()
        XCTAssertEqual(parameters.requiredInterface, interface)
        XCTAssertEqual(parameters.requiredLocalEndpoint, .hostPort(host: .ipv4(address), port: .any))
        XCTAssertFalse(parameters.includePeerToPeer)
    }
    func testUSBResolveRejectsStaleIndexAndDoesNotTrustInventedPhysicalFlags() {
        let loopback = if_nametoindex("lo0")
        XCTAssertGreaterThan(loopback, 0)
        XCTAssertThrowsError(try USBInterfaceBinding.resolve([interfaceRow(name: "lo0", index: loopback + 10000)]))
        // Even if a row claims to be Ethernet, the framework's loopback type
        // must still prevent the connection from being created.
        XCTAssertThrowsError(try USBInterfaceBinding.resolve([interfaceRow(name: "lo0", index: loopback)]))
    }
    func testDiagnosticRingKeepsRecentEventsAndAttemptIdentity() throws {
        let log = USBDiagnosticsLog(capacity: 3, console: false)
        let first = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let second = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        log.record("connect.begin", attempt: first)
        log.record("timeout.setup", attempt: first)
        log.record("connect.begin", attempt: second)
        log.record("connection.state=preparing", attempt: second)
        let report = log.report()
        XCTAssertTrue(report.contains("retained=3 dropped=1"))
        XCTAssertFalse(report.contains("#1 [11111111]"))
        XCTAssertTrue(report.contains("#2 [11111111] timeout.setup"))
        XCTAssertTrue(report.contains("#4 [22222222] connection.state=preparing"))
        XCTAssertTrue(report.contains(USBDiagnosticsLog.revision))
    }
    func testDiagnosticConcurrentWritesRemainBoundedAndCannotForgeLines() {
        let log = USBDiagnosticsLog(capacity: 16, console: false)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in log.record("state\nforged\rline") }
        log.record(String(repeating: "x", count: 10_000))
        let report = log.report()
        let events = report.split(separator: "\n").filter { $0.contains(" [app] ") }
        XCTAssertEqual(events.count, 16)
        XCTAssertTrue(report.contains("retained=16 dropped=185"))
        XCTAssertTrue(events.first?.contains("#186 [app]") == true)
        XCTAssertTrue(events.last?.contains("#201 [app]") == true)
        XCTAssertFalse(report.contains("\nforged"))
        XCTAssertLessThan(events.last?.count ?? Int.max, 1750)
    }
    func testDiagnosticCommandLabelsAndInterfaceAddressesOmitUnrelatedData() {
        let log = USBDiagnosticsLog(console: false)
        for body in ["TAP 12345 54321", "DRAG 12345 54321 23456 65432 100", "UNRECOGNIZED secret-value"] {
            log.record("kind=\(USBDiagnosticsLog.commandKind(body)); arguments omitted")
        }
        XCTAssertFalse(log.report().contains("12345"))
        XCTAssertFalse(log.report().contains("secret-value"))
        XCTAssertEqual(USBDiagnosticsLog.commandKind("PING"), "PING")
        XCTAssertEqual(USBDiagnosticsLog.visibleIPv4("192.168.7.2"), "192.168.7.2")
        XCTAssertEqual(USBDiagnosticsLog.visibleIPv4("169.254.10.20"), "169.254.10.20")
        XCTAssertFalse(USBDiagnosticsLog.visibleIPv4("10.20.30.40").contains("10.20.30.40"))
    }
    @MainActor func testUSBConnectGuardShowsFailureWithoutOpeningTransport() {
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
        model.goal = "private-task-must-not-appear-in-diagnostics"
        model.setForeground(false)
        model.connectUSB()
        XCTAssertTrue(model.usbConnectionStatus.isFailure)
        XCTAssertTrue(model.usbConnectionStatus.message.contains("前台"))
        XCTAssertFalse(model.isListening)
        model.setForeground(true); model.stopping = true
        model.connectUSB()
        XCTAssertTrue(model.usbConnectionStatus.isFailure)
        XCTAssertTrue(model.usbConnectionStatus.message.contains("停止"))
        XCTAssertFalse(model.isListening)
        let report = model.usbDiagnosticReport()
        XCTAssertTrue(report.contains("rejected=notForeground"))
        XCTAssertTrue(report.contains("rejected=runningOrStopping"))
        XCTAssertFalse(report.contains("connect.begin"))
        XCTAssertFalse(report.contains(model.goal))
    }
}

// Real NWConnection tests against a loopback-only scripted peer. No USB device,
// Local Network permission, captured phone content or external service is used.
private final class PersistentUSBPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "phoneagent.tests.usb-peer")
    private let lock = NSLock()
    private let listener: NWListener
    private var readyPort: NWEndpoint.Port?
    private var peer: NWConnection?
    private var buffer = Data() // Accessed only on queue.
    private var heldInput: String?
    private var rows: [String] = []
    private var connections = 0
    private var delayPings = false
    let holdInput: Bool
    let dropStop: Bool
    init(holdInput: Bool = false, dropStop: Bool = false) throws {
        self.holdInput = holdInput; self.dropStop = dropStop
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.lock.withLock { self.readyPort = self.listener.port } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections += 1; self.peer = connection }
            connection.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.send("PA3 READY 1", on: connection)
                    self?.receive(on: connection)
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }
    func endpoint() async throws -> NWEndpoint.Port {
        for _ in 0..<300 {
            if let port = lock.withLock({ readyPort }) { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.timeout
    }
    var lines: [String] { lock.withLock { rows } }
    var connectionCount: Int { lock.withLock { connections } }
    func delayPingReplies(_ value: Bool) { lock.withLock { delayPings = value } }
    func closePeer() { lock.withLock { peer }?.cancel() }
    func stop() { listener.cancel(); closePeer() }
    private func send(_ line: String, on connection: NWConnection) {
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let end = self.buffer.firstIndex(of: 10) {
                let line = String(decoding: self.buffer[..<end], as: UTF8.self)
                self.buffer.removeSubrange(...end)
                self.lock.withLock { self.rows.append(line) }
                let fields = line.split(separator: " ").map(String.init)
                guard fields.count >= 2 else { connection.cancel(); return }
                let id = fields[0]
                switch fields[1] {
                case "PING":
                    if self.lock.withLock({ self.delayPings }) {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.send("\(id) executed", on: connection) }
                    } else { self.send("\(id) executed", on: connection) }
                case "TAP", "DRAG":
                    self.send("\(id) received", on: connection)
                    if self.holdInput { self.heldInput = id }
                    else { self.send("\(id) executed", on: connection) }
                case "STOP":
                    if !self.dropStop {
                        if let held = self.heldInput { self.send("\(held) cancelled", on: connection); self.heldInput = nil }
                        self.send("\(id) executed", on: connection)
                    }
                default: connection.cancel()
                }
            }
            if !complete, error == nil { self.receive(on: connection) }
        }
    }
}

final class USBPersistentConnectionTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.timeout
    }
    private func connected(_ peer: PersistentUSBPeer, diagnostics: USBDiagnosticsLog) async throws -> USBCommandClient {
        let port = try await peer.endpoint()
        let client = USBCommandClient(diagnostics: diagnostics, makeConnection: { _, _ in
            NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        })
        try await client.connect()
        try await client.command("PING")
        return client
    }
    private func permit(_ client: USBCommandClient, session: USBInputSession) throws -> USBInputPermit {
        let frames = LatestScreenFrame(), epoch = frames.begin()
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        frames.put(try XCTUnwrap(pixel), orientation: 1, presentationSeconds: 1, epoch: epoch)
        let context = try ScreenUSBExecutionContext(frames: frames, health: client.health, backgroundEnabled: false)
        return USBInputPermit(context: context, observation: try XCTUnwrap(context.observation()), sequence: try frames.latestStamp().sequence, inputSession: session)
    }
    func testTwoInputTasksReuseSocketAndLateOldStopCannotRevokeNextTask() async throws {
        let peer = try PersistentUSBPeer(); defer { peer.stop() }
        let log = USBDiagnosticsLog(console: false), client = try await connected(peer, diagnostics: log)
        let first = try await client.openInputSession()
        try await client.command("TAP 1 2", permit: permit(client, session: first))
        await client.stopInputs(first)
        let second = try await client.openInputSession()
        XCTAssertEqual(second.connection, first.connection)
        XCTAssertEqual(second.generation, first.generation + 1)
        await client.stopInputs(first) // Late cleanup from a completed run.
        do { try await client.command("TAP 3 4", permit: permit(client, session: first)); XCTFail("Old task sent input") } catch {}
        try await client.command("TAP 5 6", permit: permit(client, session: second))
        await client.stopInputs(second)
        try await client.command("PING")
        XCTAssertEqual(peer.connectionCount, 1)
        XCTAssertEqual(peer.lines.filter { $0.contains(" TAP ") }.map { $0.split(separator: " ").dropFirst().joined(separator: " ") }, ["TAP 1 1 2", "TAP 2 5 6"])
        XCTAssertEqual(peer.lines.filter { $0.contains(" STOP ") }.count, 2)
        XCTAssertFalse(log.report().contains("connection.close"))
        await client.disconnect()
        XCTAssertTrue(log.report().contains("connection.close"))
    }
    func testCancelledPingConsumesLateReplyWithoutClosingConnection() async throws {
        let peer = try PersistentUSBPeer(); defer { peer.stop() }
        let log = USBDiagnosticsLog(console: false), client = try await connected(peer, diagnostics: log)
        peer.delayPingReplies(true)
        let before = peer.lines.count
        let ping = Task { try await client.command("PING") }
        try await waitUntil { peer.lines.count > before }
        ping.cancel()
        do { try await ping.value; XCTFail("Cancelled wait returned success") } catch { XCTAssertTrue(error is CancellationError) }
        try await waitUntil { log.report().contains("request.cancel") }
        try await Task.sleep(nanoseconds: 350_000_000)
        peer.delayPingReplies(false)
        try await client.command("PING")
        XCTAssertNoThrow(try client.health.requireHealthy(now: ProcessInfo.processInfo.systemUptime))
        XCTAssertEqual(peer.connectionCount, 1)
        XCTAssertFalse(log.report().contains("connection.close"))
        await client.disconnect()
    }
    func testCancelledInputReleasesOnceAndCoalescesTaskCleanup() async throws {
        let peer = try PersistentUSBPeer(holdInput: true); defer { peer.stop() }
        let log = USBDiagnosticsLog(console: false), client = try await connected(peer, diagnostics: log)
        let session = try await client.openInputSession(), allowed = try permit(client, session: session)
        let input = Task { try await client.command("DRAG 1 2 3 4 2000", permit: allowed) }
        try await waitUntil { peer.lines.contains { $0.contains(" DRAG ") } }
        input.cancel()
        do { try await input.value; XCTFail("Cancelled input returned success") } catch { XCTAssertTrue(error is CancellationError) }
        await client.stopInputs(session)
        try await client.command("PING")
        XCTAssertEqual(peer.lines.filter { $0.contains(" STOP ") }.count, 1)
        XCTAssertFalse(log.report().contains("connection.close"))
        let next = try await client.openInputSession()
        XCTAssertEqual(next.generation, session.generation + 1)
        await client.stopInputs(next)
        await client.disconnect()
    }
    func testMissingReleaseACKClosesConnectionAndRevokesLease() async throws {
        let peer = try PersistentUSBPeer(dropStop: true); defer { peer.stop() }
        let log = USBDiagnosticsLog(console: false), client = try await connected(peer, diagnostics: log)
        let session = try await client.openInputSession()
        await client.stopInputs(session)
        XCTAssertTrue(log.report().contains("connection.close"))
        XCTAssertThrowsError(try client.health.requireHealthy(now: ProcessInfo.processInfo.systemUptime))
        do { _ = try await client.openInputSession(); XCTFail("Failed release retained authority") } catch {}
        await client.disconnect()
    }
    @MainActor func testPeerDisconnectUpdatesIdleViewModelStatus() async throws {
        let peer = try PersistentUSBPeer(); defer { peer.stop() }
        let port = try await peer.endpoint()
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            makeUSBClient: { diagnostics, onProgress in
                USBCommandClient(diagnostics: diagnostics, onProgress: onProgress, makeConnection: { _, _ in
                    NWConnection(host: "127.0.0.1", port: port, using: .tcp)
                })
            })
        model.connectUSB()
        for _ in 0..<300 {
            if model.usbConnectionStatus.isReady { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.usbConnectionStatus.isReady)
        peer.closePeer()
        for _ in 0..<300 {
            if model.usbConnectionStatus.isFailure { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.usbConnectionStatus.isFailure)
        XCTAssertFalse(model.running)
        model.disconnect()
    }
}
