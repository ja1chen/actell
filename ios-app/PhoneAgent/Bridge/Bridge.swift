import Foundation

protocol DeviceBridge: Sendable {
    var executionContext: ScreenUSBExecutionContext? { get }
    func setRemoteDeadline(_ deadline: Date) async throws
    func supportsBackgroundExecution(tool: String) async -> Bool
    func approvalContext(imageID: String) async throws -> String
    func acceptApproval(imageID: String) async throws
    func authorizeTaskInput(imageID: String) async throws
    func screenshot() async throws -> FrameImage
    func validateRemoteObservation(_ frame: FrameImage) async throws
    func tap(x: Int, y: Int, imageID: String) async throws
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws
    func installedApplications() async throws -> Data
    func systemActionContext() async throws -> String
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws
    func bringApplicationToForeground(bundleID: String) async throws -> Bool
    func cancelTransport()
    func stop() async
}

extension DeviceBridge {
    func validateRemoteObservation(_ frame: FrameImage) async throws { throw AppError.unavailable(String(localized: "This connection cannot verify the current screen layout.")) }
    func setRemoteDeadline(_ deadline: Date) async throws { throw AppError.unavailable(String(localized: "This connection does not support remote task deadlines.")) }
    func bringApplicationToForeground(bundleID: String) async throws -> Bool { false }
    func systemActionContext() async throws -> String { throw AppError.unavailable(String(localized: "This connection does not support separate system actions")) }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws { throw AppError.unavailable(String(localized: "This connection does not support separate system actions")) }
    func installedApplications() async throws -> Data { throw AppError.unavailable(String(localized: "This connection does not support app queries")) }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws { throw AppError.unavailable(String(localized: "This connection does not support this action")) }
    var executionContext: ScreenUSBExecutionContext? { nil }
    func cancelTransport() {}
    func supportsBackgroundExecution(tool: String) async -> Bool { false }
    func approvalContext(imageID: String) async throws -> String { "foreground-only" }
    func acceptApproval(imageID: String) async throws {}
    func authorizeTaskInput(imageID: String) async throws {
        throw AppError.unavailable(String(localized: "This input connection does not support automatic authorization within a task"))
    }
}

struct UnavailableBridge: DeviceBridge {
    static let screenshotMessage = String(localized: "Screen capture has not been authorized. Authorize full-screen capture in the control settings. An ESP32 is not needed to view the screen.")
    func screenshot() async throws -> FrameImage { throw AppError.unavailable(Self.screenshotMessage) }
    func tap(x: Int, y: Int, imageID: String) async throws { throw AppError.unavailable(String(localized: "Device not connected")) }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { throw AppError.unavailable(String(localized: "Device not connected")) }
    func stop() async {}
}

/// Snapshot the capture and input capabilities separately for each run.
/// A local screenshot never requires a working USB connection or HID firmware.
enum LiveDeviceBridgeRouter {
    struct USBInput {
        let transport: any USBCommandTransport
        let health: USBTransportHealth
        let supportsHID: Bool
    }
    static func make(frames: LatestScreenFrame, captureActive: Bool,
                     usb: USBInput?, backgroundEnabled: Bool, legacy: (any DeviceBridge)? = nil,
                     usbStatus: USBConnectionStatus = .idle, diagnostics: USBDiagnosticsLog? = nil,
                     onLoss: @escaping @Sendable (USBBridgeStopReason) -> Void = { _ in }) throws -> any DeviceBridge {
        func record(_ route: String, reason: String) {
            diagnostics?.record("run.route selected=\(route) reason=\(reason) usbState=\(usbStatus.diagnosticState) hasClient=\(usb != nil) captureActive=\(captureActive) backgroundEnabled=\(backgroundEnabled)")
        }
        guard captureActive else {
            // The explicitly started legacy Host service remains available.
            if usb == nil, let legacy { record("legacy", reason: "explicitLegacyService"); return legacy }
            record("unavailable", reason: "captureNotActive")
            return UnavailableBridge()
        }
        var inputFailure = usbStatus.unavailableInputMessage
        var reason = "usbClientMissing"
        if let usb {
            reason = "firmwareNCMOnly"
            inputFailure = String(localized: "This USB firmware supports NCM only. HID support is needed to tap or drag.")
            if usb.supportsHID {
                do {
                    let context = try ScreenUSBExecutionContext(frames: frames, health: usb.health, backgroundEnabled: backgroundEnabled)
                    record("usbHID", reason: "captureAndUSBHealthy")
                    return USBDeviceBridge(frames: frames, transport: usb.transport, context: context, diagnostics: diagnostics, onLoss: onLoss)
                } catch {
                    // Never grant inputs on an invalid capture/USB lease. The
                    // local read path independently validates its capture session.
                    inputFailure = String(localized: "USB input is no longer available. Reconnect and get a new screenshot before starting a control task.")
                    reason = "inputConditionsInvalid"
                }
            }
        }
        record("localScreen", reason: reason)
        return try LocalScreenBridge(frames: frames, backgroundEnabled: backgroundEnabled, inputFailure: inputFailure)
    }
}

/// Read-only Agent access to the App's existing capture session.
/// Stopping a run revokes this reader, not the user's system capture session.
struct LocalScreenBridge: DeviceBridge {
    private let frames: LatestScreenFrame
    let executionContext: ScreenUSBExecutionContext?
    private let context: ScreenUSBExecutionContext
    private let inputFailure: String
    init(frames: LatestScreenFrame, backgroundEnabled: Bool, inputFailure: String) throws {
        self.frames = frames; self.inputFailure = inputFailure
        context = try ScreenUSBExecutionContext(frames: frames, backgroundEnabled: backgroundEnabled)
        executionContext = context
    }
    func supportsBackgroundExecution(tool: String) async -> Bool {
        context.backgroundEnabled && ["screenshot", "wait", "finish"].contains(tool)
    }
    func screenshot() async throws -> FrameImage {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            try Task.checkCancellation()
            if let scope = try context.captureObservation(),
               let stamp = try? frames.latestStamp(), stamp.uptime > scope.after {
                let frame = try frames.encoded(notBefore: scope.after)
                try Task.checkCancellation()
                if let current = try context.captureObservation(), current.revision == scope.revision { return frame }
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        context.revoke()
        throw AppError.unavailable(String(localized: "Timed out waiting for a valid captured image. \(frames.diagnostics().summary). Copy the diagnostic log to check reception."))
    }
    func approvalContext(imageID: String) throws -> String { throw AppError.unavailable(inputFailure) }
    func acceptApproval(imageID: String) throws { throw AppError.unavailable(inputFailure) }
    func tap(x: Int, y: Int, imageID: String) async throws { throw AppError.unavailable(inputFailure) }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { throw AppError.unavailable(inputFailure) }
    func cancelTransport() { context.revoke() }
    func stop() async { context.revoke() }
}
