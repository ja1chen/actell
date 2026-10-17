import Foundation
import ImageIO

enum NCMRemoteAdmissionError: LocalizedError {
    case notConnected(String?), busy, reserved
    var code: String {
        switch self {
        case .notConnected: return "control_not_connected"
        case .busy: return "control_busy"
        case .reserved: return "control_reserved"
        }
    }
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Phone control is disconnected. Connect in Settings → Phone Control → Connection & Validation.")
        case .busy: return String(localized: "Phone control setup is in progress. Wait for it to finish and try again.")
        case .reserved: return String(localized: "Another task is using phone control. Stop it first.")
        }
    }
}

/// Persisted developer route; active bridges retain the shared connection and
/// prevent route changes until their run has released it.
enum DeviceControlRoute: String, Sendable {
    case vpnLoopback = "localDevVPN"
    case ncmDeveloper
    case localCaptureUSB
    static let defaultsKey = "deviceControlRoute"
    static var current: Self { load(from: .standard) }
    static func load(from defaults: UserDefaults) -> Self {
        // Retained capture route is not exposed by this setting.
        defaults.string(forKey: defaultsKey) == Self.ncmDeveloper.rawValue ? .ncmDeveloper : .vpnLoopback
    }
    var title: String { self == .vpnLoopback ? String(localized: "VPN loopback") : "ESP32 NCM" }
    var connectionName: String { self == .vpnLoopback ? String(localized: "VPN loopback") : "ESP32" }
    var controlTitle: String { self == .vpnLoopback ? String(localized: "VPN loopback control") : String(localized: "ESP32 control") }
    var modelContext: String {
        switch self {
        case .ncmDeveloper:
            return "Screenshots and touch input use the authenticated ESP32 NCM developer connection. Background execution needs an active execution source. Device tools wait for a paired connection internally; reconnecting invalidates old frames and action grants, while read tools can bind the new session."
        case .vpnLoopback:
            return "Screenshots and touch input use authenticated CoreDevice services through a local VPN loopback on this phone, without ESP32. A compatible packet-reflection VPN must already be enabled with the configured interface and peer addresses. Device tools verify the paired connection internally; reconnecting invalidates old frames and action grants. Follow actual readiness errors."
        case .localCaptureUSB:
            return "Screenshots use this App's authorized ScreenCaptureKit capture, independently of USB. Touch input uses the retained USB HID route. Follow the tools' actual foreground/background capabilities."
        }
    }
}

@MainActor protocol NCMControlConnection: AnyObject {
    var ready: Bool { get }
    var connectionFailure: String? { get }
    var running: Bool { get }
    var agentReserved: Bool { get }
    var controlSessionID: UUID { get }
    var connectionStopID: UUID? { get }
    func connectIfNeeded() throws
    func agentCapture(owner: UUID, session: UUID) async throws -> Data
    func agentInputGeometry(owner: UUID, session: UUID) async throws -> String
    func agentCaptureWithGeometry(owner: UUID, session: UUID) async throws -> (Data, String?)
    func agentValidateGeometry(owner: UUID, session: UUID, token: String) async throws
    func agentTap(owner: UUID, session: UUID, x: UInt16, y: UInt16, validate: () throws -> Void) async throws
    func agentDrag(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, validate: () throws -> Void) async throws
    func agentTapWithGeometry(owner: UUID, session: UUID, x: UInt16, y: UInt16, geometry: String, validate: () throws -> Void) async throws
    func agentDragWithGeometry(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, geometry: String, validate: () throws -> Void) async throws
    func agentApplications(owner: UUID, session: UUID) async throws -> Data
    func agentSystemAction(owner: UUID, session: UUID, name: String, text: String, arguments: [String], validate: () throws -> Void) async throws
    func canActivateApplication(owner: UUID, session: UUID) -> Bool
    func retainConnection(owner: UUID)
    func awaitControlRelease() async
    func releaseConnection(owner: UUID)
    func registerAgent(owner: UUID, session: UUID)
    func releaseAgent(owner: UUID, session: UUID)
}

extension NCMControlConnection {
    func agentInputGeometry(owner: UUID, session: UUID) async throws -> String { throw RemoteRPCError("geometry_unavailable", "Current input display geometry is unavailable") }

    func agentTapWithGeometry(owner: UUID, session: UUID, x: UInt16, y: UInt16, geometry: String, validate: () throws -> Void) async throws { throw AppError.unavailable(String(localized: "This connection cannot verify screen changes before input.")) }
    func agentDragWithGeometry(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, geometry: String, validate: () throws -> Void) async throws { throw AppError.unavailable(String(localized: "This connection cannot verify screen changes before input.")) }

    func agentCaptureWithGeometry(owner: UUID, session: UUID) async throws -> (Data, String?) { (try await agentCapture(owner: owner, session: session), nil) }
    func agentValidateGeometry(owner: UUID, session: UUID, token: String) async throws { throw AppError.unavailable(String(localized: "This connection cannot verify the current screen layout.")) }

    func canActivateApplication(owner: UUID, session: UUID) -> Bool { !running && !agentReserved }
    var connectionStopID: UUID? { nil }
    func connectIfNeeded() throws {
        guard ready else { throw NCMControlError.unavailable(connectionFailure ?? String(localized: "ESP32 not connected")) }
    }
    var connectionFailure: String? { nil }
    func agentApplications(owner: UUID, session: UUID) async throws -> Data { throw AppError.unavailable(String(localized: "This connection does not support app queries")) }
    func agentSystemAction(owner: UUID, session: UUID, name: String, text: String, arguments: [String], validate: () throws -> Void) async throws { throw AppError.unavailable(String(localized: "This connection does not support this action")) }
    func awaitControlRelease() async {}
    func retainConnection(owner: UUID) {}
    func releaseConnection(owner: UUID) {}
    func registerAgent(owner: UUID, session: UUID) {}
}

extension PairingFlow: NCMControlConnection {
    func agentInputGeometry(owner: UUID, session: UUID) async throws -> String {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            return try await services.inputDisplayGeometry()
        }
    }

    func agentTapWithGeometry(owner: UUID, session: UUID, x: UInt16, y: UInt16, geometry: String, validate: () throws -> Void) async throws {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            try await services.validateVideoGeometry(geometry)
            try Task.checkCancellation(); try validate()
            _ = try await services.tapDelivery(x: x, y: y, geometryToken: geometry)
        }
    }
    func agentDragWithGeometry(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, geometry: String, validate: () throws -> Void) async throws {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            try await services.validateVideoGeometry(geometry)
            try Task.checkCancellation(); try validate()
            _ = try await services.dragDelivery(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMS: durationMS, geometryToken: geometry)
        }
    }

    func agentCaptureWithGeometry(owner: UUID, session: UUID) async throws -> (Data, String?) {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            defer { if let diagnostic = services.videoSnapshotDiagnostics { BackgroundExecutionTrace.record(diagnostic) } }
            let data = try await services.captureVideoJPEG()
            return (data, services.capturedVideoGeometryToken)
        }
    }
    func agentValidateGeometry(owner: UUID, session: UUID, token: String) async throws {
        try await agentOperation(owner: owner, session: session) { services in try await services.validateVideoGeometry(token) }
    }

    var connectionFailure: String? { lastFailure }
    func awaitControlRelease() async { await mediaLifetimeWait() }
    func agentApplications(owner: UUID, session: UUID) async throws -> Data {
        try await agentOperation(owner: owner, session: session) { try await $0.installedApplications() }
    }
    func agentSystemAction(owner: UUID, session: UUID, name: String, text: String, arguments: [String], validate: () throws -> Void) async throws {
        try await agentOperation(owner: owner, session: session) { services in
            if name == "home" || name == "type_text" { try await self.prepareAgentInput(services) }
            try Task.checkCancellation(); try validate()
            switch name {
            case "home": try await services.home()
            case "type_text": try await services.typeText(text)
            case "launch_app": try await services.launchApplication(bundleID: text, arguments: arguments)
            default: throw AppError.invalid(String(localized: "Unregistered system action"))
            }
        }
    }
    func agentCapture(owner: UUID, session: UUID) async throws -> Data {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            defer { if let diagnostic = services.videoSnapshotDiagnostics { BackgroundExecutionTrace.record(diagnostic) } }
            return try await services.captureVideoJPEG()
        }
    }
    func agentTap(owner: UUID, session: UUID, x: UInt16, y: UInt16, validate: () throws -> Void) async throws {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            try Task.checkCancellation()
            try validate()
            _ = try await services.tapDelivery(x: x, y: y)
        }
    }
    func agentDrag(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, validate: () throws -> Void) async throws {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            try Task.checkCancellation()
            try validate()
            _ = try await services.dragDelivery(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMS: durationMS)
        }
    }
}

private final class NCMRunFence: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw AppError.stopped }
    }
}

/// Uses the Settings connection, never a second relay or the old HID route.
/// Images and approval are bound to this run and authenticated generation.
@MainActor final class NCMDeviceBridge: DeviceBridge {
    private let flow: any NCMControlConnection
    private var session: UUID?
    private let owner = UUID()
    private nonisolated let fence = NCMRunFence()
    private var remoteDeadline: Date?
    func setRemoteDeadline(_ deadline: Date) async throws {
        guard deadline > Date() else { throw AppError.stopped }
        remoteDeadline = deadline
    }
    private var checkedRemoteGeometry: (token: String, expires: Date)?
    private var imageID: String?
    private var approvedImageID: String?
    private var systemAuthorizationID: String?
    private let connectionTimeout: Duration
    private let remoteExclusive: Bool
    private let connectionDiagnostic: (@MainActor (String) -> Void)?
    init(flow: any NCMControlConnection = PairingFlow.shared, connectionTimeout: Duration = .seconds(20), remoteExclusive: Bool = false,
         connectionDiagnostic: (@MainActor (String) -> Void)? = nil) throws {
        self.flow = flow; self.connectionTimeout = connectionTimeout
        self.remoteExclusive = remoteExclusive; self.connectionDiagnostic = connectionDiagnostic
        if remoteExclusive {
            // Reserve a ready route atomically. An in-flight connection setup is
            // awaited by the tool, after the run has configured background demand.
            guard !flow.running || !flow.ready else { throw NCMRemoteAdmissionError.busy }
            guard !flow.agentReserved else { throw NCMRemoteAdmissionError.reserved }
            if flow.ready {
                session = flow.controlSessionID
                flow.registerAgent(owner: owner, session: flow.controlSessionID)
            }
        }
        flow.retainConnection(owner: owner)
    }
    // Scheduling capability is independent of connection readiness; transport
    // failures are reported by tools, never used to pause ordinary chat.
    func supportsBackgroundExecution(tool: String) async -> Bool { (try? fence.check()) != nil }
    /// Connection preparation never sends/replays an input. Fresh observation
    /// and system actions may bind a new session; old coordinates/grants cannot.
    private func prepareConnection() async throws {
        let waiting = !flow.ready
        if waiting { connectionDiagnostic?("control.connection_wait") }
        do {
            try await awaitConnection()
            if waiting { connectionDiagnostic?("control.connection_ready") }
        } catch {
            connectionDiagnostic?("control.connection_failed")
            throw error
        }
    }
    private func awaitConnection() async throws {
        let deadline = ContinuousClock.now.advanced(by: connectionTimeout)
        let stopID = flow.connectionStopID
        var nextAttempt = ContinuousClock.now
        while !flow.ready {
            try Task.checkCancellation(); try fence.check()
            guard stopID == flow.connectionStopID else { throw AppError.unavailable(String(localized: "Stopped waiting for the phone control connection")) }
            if ContinuousClock.now >= nextAttempt {
                do { try flow.connectIfNeeded() }
                catch NCMControlError.unavailable(let message) {
                    connectionDiagnostic?("control.connection_unavailable")
                    throw AppError.unavailable(message)
                }
                nextAttempt = ContinuousClock.now.advanced(by: .seconds(1))
            }
            if flow.ready { break }
            guard ContinuousClock.now < deadline else {
                connectionDiagnostic?("control.connection_timeout")
                throw AppError.unavailable(String(localized: "Timed out waiting for the phone control connection. \(flow.connectionFailure ?? String(localized: "Check your device connection"))"))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation(); try fence.check()
        guard stopID == flow.connectionStopID else { throw AppError.unavailable(String(localized: "Stopped waiting for the phone control connection")) }
        if session != flow.controlSessionID {
            // Setup may have overlapped a local diagnostic operation. Do not
            // capture its session or dispatch until exclusive ownership is free.
            if remoteExclusive, session == nil {
                guard !flow.running else { throw NCMRemoteAdmissionError.busy }
                guard !flow.agentReserved else { throw NCMRemoteAdmissionError.reserved }
            }
            if let session { flow.releaseAgent(owner: owner, session: session) }
            imageID = nil; approvedImageID = nil; systemAuthorizationID = nil
            session = flow.controlSessionID
            flow.registerAgent(owner: owner, session: flow.controlSessionID)
        }
        try check()
    }
    private func check() throws {
        try fence.check()
        if let remoteDeadline, Date() >= remoteDeadline { throw AppError.stopped }
        guard flow.ready else {
            throw AppError.unavailable(flow.connectionFailure ?? String(localized: "Phone control is not connected. Connect in Settings → Phone control → Connection and verification."))
        }
        if let session {
            guard flow.controlSessionID == session else {
                throw AppError.unavailable(String(localized: "The phone control connection changed. Start a new control task."))
            }
        } else {
            session = flow.controlSessionID
            flow.registerAgent(owner: owner, session: flow.controlSessionID)
        }
    }
    private func requireSession() throws -> UUID {
        try check()
        guard let session else { throw AppError.stopped }
        return session
    }
    private var independentGrant: String?
    func inputDisplaySnapshot() async throws -> InputDisplaySnapshot {
        try await prepareConnection()
        let session = try requireSession()
        let token: String
        do { token = try await perform { try await flow.agentInputGeometry(owner: owner, session: session) } }
        catch { throw RemoteRPCError("geometry_unavailable", "Current input display geometry is unavailable", underlying: error) }
        try check()
        return InputDisplaySnapshot(context: "ncm:\(session.uuidString):\(owner.uuidString)", token: token, sampledAt: Date())
    }
    func authorizeIndependentInput(_ snapshot: InputDisplaySnapshot, authorizationID: String) async throws {
        let current = try await inputDisplaySnapshot()
        guard current.context == snapshot.context, current.token == snapshot.token else { throw RemoteRPCError("geometry_changed", "Input display changed before dispatch") }
        independentGrant = authorizationID
    }
    func independentInput(name: String, coordinates: [Int], durationMS: Int, snapshot: InputDisplaySnapshot, authorizationID: String) async throws {
        try await prepareConnection()
        let session = try requireSession()
        guard independentGrant == authorizationID, snapshot.context == "ncm:\(session.uuidString):\(owner.uuidString)",
              coordinates.allSatisfy({ (0...65535).contains($0) }),
              (name == "tap" && coordinates.count == 2) || (name == "drag" && coordinates.count == 4 && (100...2000).contains(durationMS)) else { throw AppError.stopped }
        independentGrant = nil
        let validate = { try self.check() }
        if name == "tap" {
            try await perform { try await flow.agentTapWithGeometry(owner: owner, session: session, x: UInt16(coordinates[0]), y: UInt16(coordinates[1]), geometry: snapshot.token, validate: validate) }
        } else {
            try await perform { try await flow.agentDragWithGeometry(owner: owner, session: session, fromX: UInt16(coordinates[0]), fromY: UInt16(coordinates[1]), toX: UInt16(coordinates[2]), toY: UInt16(coordinates[3]), durationMS: UInt16(durationMS), geometry: snapshot.token, validate: validate) }
        }
    }
    func approvalContext(imageID: String) async throws -> String {
        try await prepareConnection()
        let session = try requireSession()
        guard self.imageID == imageID else { throw AppError.invalid(String(localized: "Get a new screenshot first")) }
        return "ncm:\(session.uuidString):\(owner.uuidString)"
    }
    func acceptApproval(imageID: String) async throws {
        _ = try await approvalContext(imageID: imageID)
        approvedImageID = imageID
    }
    func authorizeTaskInput(imageID: String) async throws {
        try await acceptApproval(imageID: imageID)
    }
    func screenshot() async throws -> FrameImage {
        try await prepareConnection()
        imageID = nil; approvedImageID = nil; checkedRemoteGeometry = nil
        let session = try requireSession()
        let (png, geometryToken) = try await perform { try await flow.agentCaptureWithGeometry(owner: owner, session: session) }
        try check()
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw AppError.protocolViolation(String(localized: "Invalid NCM screenshot format"))
        }
        let id = UUID().uuidString
        imageID = id; approvedImageID = nil
        return FrameImage(id: id, png: png, width: width, height: height, capturedAt: Date(), isDemo: false, remoteGeometryToken: geometryToken)
    }
    func validateRemoteObservation(_ frame: FrameImage) async throws {
        try await prepareConnection()
        guard Date().timeIntervalSince(frame.capturedAt) < RemoteImageGeometry.maxAge, imageID == frame.id, let token = frame.remoteGeometryToken else { throw AppError.invalid(String(localized: "This screenshot cannot be used for phone control. Take another screenshot.")) }
        let session = try requireSession()
        try await perform { try await flow.agentValidateGeometry(owner: owner, session: session, token: token) }
        try check()
        checkedRemoteGeometry = (token, frame.capturedAt.addingTimeInterval(RemoteImageGeometry.maxAge))
        guard imageID == frame.id else { throw AppError.invalid(String(localized: "The screen changed. Take another screenshot.")) }
    }
    private func consumeInputApproval(_ id: String, coordinates: [Int]) throws {
        try check()
        guard imageID == id, approvedImageID == id else { throw AppError.invalid(String(localized: "Input requires a valid coordinate reference and permission for this action")) }
        guard coordinates.allSatisfy({ (0...65535).contains($0) }) else { throw AppError.invalid(String(localized: "Input coordinates are out of bounds")) }
        // Consume only this dispatch's approval, retaining the coordinate reference.
        approvedImageID = nil
    }
    func tap(x: Int, y: Int, imageID: String) async throws {
        try await prepareConnection()
        try consumeInputApproval(imageID, coordinates: [x, y])
        let session = try requireSession()
        let geometry = checkedRemoteGeometry; checkedRemoteGeometry = nil
        let validate = {
            try self.check()
            guard self.imageID == imageID, geometry.map({ Date() < $0.expires }) ?? true else { throw AppError.invalid(String(localized: "The screen changed or the screenshot expired. Take another screenshot.")) }
        }
        if let geometry {
            try await perform { try await flow.agentTapWithGeometry(owner: owner, session: session, x: UInt16(x), y: UInt16(y), geometry: geometry.token, validate: validate) }
        } else {
            try await perform { try await flow.agentTap(owner: owner, session: session, x: UInt16(x), y: UInt16(y), validate: validate) }
        }
    }

    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {
        guard (100...2000).contains(durationMS) else { throw AppError.invalid(String(localized: "Drag duration must be 100–2000 milliseconds")) }
        try await prepareConnection()
        try consumeInputApproval(imageID, coordinates: [fromX, fromY, toX, toY])
        let session = try requireSession()
        let geometry = checkedRemoteGeometry; checkedRemoteGeometry = nil
        let validate = {
            try self.check()
            guard self.imageID == imageID, geometry.map({ Date() < $0.expires }) ?? true else { throw AppError.invalid(String(localized: "The screen changed or the screenshot expired. Take another screenshot.")) }
        }
        if let geometry {
            try await perform { try await flow.agentDragWithGeometry(owner: owner, session: session, fromX: UInt16(fromX), fromY: UInt16(fromY), toX: UInt16(toX), toY: UInt16(toY), durationMS: UInt16(durationMS), geometry: geometry.token, validate: validate) }
        } else {
            try await perform { try await flow.agentDrag(owner: owner, session: session, fromX: UInt16(fromX), fromY: UInt16(fromY), toX: UInt16(toX), toY: UInt16(toY), durationMS: UInt16(durationMS), validate: validate) }
        }
    }
    func installedApplications() async throws -> Data {
        try await prepareConnection()
        let session = try requireSession()
        return try await perform { try await flow.agentApplications(owner: owner, session: session) }
    }
    func systemActionContext() async throws -> String {
        try await prepareConnection()
        return "ncm:\(try requireSession().uuidString):\(owner.uuidString)"
    }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws {
        _ = try requireSession()
        systemAuthorizationID = authorizationID
    }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws {
        try check()
        if systemAuthorizationID == imageID {
            systemAuthorizationID = nil
            approvedImageID = nil
        } else {
            // Retain direct diagnostic callers using a real approved frame.
            try consumeInputApproval(imageID, coordinates: [])
        }
        let session = try requireSession()
        try await perform { try await flow.agentSystemAction(owner: owner, session: session, name: name, text: text, arguments: arguments, validate: { try self.check() }) }
    }
    /// Completion handoff uses the existing authenticated app service. It does
    /// not capture a frame, reconnect, or wait behind another task's control lease.
    func bringApplicationToForeground(bundleID: String) async throws -> Bool {
        try Task.checkCancellation(); try fence.check()
        guard flow.ready, flow.canActivateApplication(owner: owner, session: session ?? flow.controlSessionID) else { return false }
        let session = try requireSession()
        try await perform {
            try await flow.agentSystemAction(owner: owner, session: session, name: "launch_app", text: bundleID, arguments: [], validate: { try self.check() })
        }
        return true
    }
    private func perform<T>(_ action: () async throws -> T) async throws -> T {
        do {
            try check()
            let value = try await action()
            try check()
            return value
        }
        catch NCMControlError.unavailable(let message) { throw AppError.unavailable(message) }
        catch NCMControlError.stopped {
            // Connection generation loss is a tool failure; only this run's
            // explicit cancellation fence should end the Agent loop.
            try fence.check()
            throw AppError.unavailable(flow.connectionFailure ?? String(localized: "The phone control connection was interrupted. The result may be unknown. Check your device before continuing."))
        }
    }

    nonisolated func cancelTransport() {
        fence.cancel()
        Task { @MainActor in
            if let session = self.session { self.flow.releaseAgent(owner: self.owner, session: session) }
            self.flow.releaseConnection(owner: self.owner)
        }
    }
    func stop() async {
        fence.cancel(); imageID = nil; approvedImageID = nil; systemAuthorizationID = nil
        if let session {
            flow.releaseAgent(owner: owner, session: session)
            if flow.controlSessionID == session { await flow.awaitControlRelease() }
        }
        flow.releaseConnection(owner: owner)
    }
}

/// Owns asynchronous media cleanup independently of UI visibility. A revoked
/// generation can never publish cleanup completion into a newer connection.
@MainActor final class ControlMediaLifetime {
    private(set) var active = false
    private(set) var stopping = false
    private var generation = UUID()
    private var cleanup: Task<Void, Never>?
    func didOpen() { active = true }
    @discardableResult func finishIfIdle(hasUsers: Bool,
        stop: @escaping @MainActor () async throws -> Void,
        completed: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard active, !hasUsers, !stopping else { return false }
        stopping = true
        let epoch = generation
        cleanup = Task { [weak self] in
            var success = false
            do { try Task.checkCancellation(); try await stop(); success = true } catch {}
            guard let self, self.generation == epoch else { return }
            self.active = false; self.stopping = false; self.cleanup = nil
            completed(success)
        }
        return true
    }
    func wait() async { await cleanup?.value }
    func revoke() {
        generation = UUID(); active = false; stopping = false
        cleanup?.cancel(); cleanup = nil
    }
}
