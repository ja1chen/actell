import Foundation

enum USBBridgeStopReason: String, Error, Sendable {
    case sessionInvalid, screenshotTimeout, inputFailed
    var message: String {
        switch self {
        case .sessionInvalid: return String(localized: "The capture session, image, or USB connection is no longer valid. This run has stopped.")
        case .screenshotTimeout: return String(localized: "Timed out waiting for a valid screenshot. Input has stopped for this run.")
        case .inputFailed: return String(localized: "The USB action was not fully acknowledged. This run has stopped. Check your device.")
        }
    }
}

actor USBDeviceBridge: DeviceBridge {
    nonisolated let executionContext: ScreenUSBExecutionContext?
    private let frames: LatestScreenFrame
    private let transport: any USBCommandTransport
    private var stopped = false
    private var image: FrameImage?
    private var barrierSequence: UInt64 = 0
    private var barrierTime: TimeInterval = 0
    private var monitor: Task<Void, Never>?
    private var healthObserver: UUID?
    private var inputInFlight = false
    private var approvedImageID: String?
    private var inputSession: USBInputSession?
    private var openingSession: Task<USBInputSession, Error>?
    private var stopTask: Task<Void, Never>?
    private let diagnostics: USBDiagnosticsLog?
    private let onLoss: @Sendable (USBBridgeStopReason) -> Void
    init(frames: LatestScreenFrame, transport: any USBCommandTransport,
         context: ScreenUSBExecutionContext? = nil, diagnostics: USBDiagnosticsLog? = nil,
         onLoss: @escaping @Sendable (USBBridgeStopReason) -> Void = { _ in }) {
        self.frames = frames; self.transport = transport; self.onLoss = onLoss
        executionContext = context; self.diagnostics = diagnostics
    }
    nonisolated func cancelTransport() { executionContext?.revoke() }
    func supportsBackgroundExecution(tool: String) async -> Bool { executionContext?.backgroundEnabled == true }
    func approvalContext(imageID: String) async throws -> String {
        guard !stopped, image?.id == imageID else { throw AppError.stopped }
        try executionContext?.requireHealthy()
        return try frames.sessionID().uuidString
    }
    func acceptApproval(imageID: String) async throws {
        guard !stopped, image?.id == imageID else { throw AppError.stopped }
        try executionContext?.requireForegroundApproval()
        _ = try await requireInputSession()
        guard !stopped else { throw AppError.stopped }
        approvedImageID = imageID
    }
    func authorizeTaskInput(imageID: String) async throws {
        guard !stopped, image?.id == imageID, let context = executionContext else { throw AppError.stopped }
        diagnostics?.record("input.authorization.begin mode=task \(context.diagnosticSummary)")
        // The task-start grant applies in PhoneAgent and other apps. Scene,
        // pixel changes and frame age do not invalidate that grant.
        try context.requireHealthy()
        _ = try await requireInputSession()
        guard !stopped else { throw AppError.stopped }
        approvedImageID = imageID
        diagnostics?.record("input.authorization.ready mode=task epoch=\(inputSession?.generation ?? 0)")
    }
    private func requireInputSession() async throws -> USBInputSession {
        guard !stopped else { throw AppError.stopped }
        if let inputSession { return inputSession }
        let opening: Task<USBInputSession, Error>
        if let openingSession { opening = openingSession }
        else {
            opening = Task { try await transport.openInputSession() }
            openingSession = opening
        }
        let session = try await opening.value
        guard !stopped else { throw AppError.stopped }
        inputSession = session; openingSession = nil
        return session
    }
    func arm() async throws {
        if executionContext == nil { _ = try frames.latestStamp() }
        try executionContext?.requireHealthy()
        guard !stopped else { throw AppError.stopped }
        _ = try await requireInputSession()
        if let context = executionContext {
            if healthObserver == nil {
                healthObserver = context.observeHealth { [weak self] in
                    Task { await self?.lost(.sessionInvalid) }
                }
            }
            return
        }
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.checkHealth(); try await Task.sleep(nanoseconds: 200_000_000) }
                catch { if !Task.isCancelled { await self?.lost(error as? USBBridgeStopReason ?? .sessionInvalid) }; return }
            }
        }
    }
    private func checkHealth() throws {
        do {
            guard !stopped else { throw AppError.stopped }
            if executionContext == nil { _ = try frames.latestStamp() }
            try executionContext?.requireHealthy()
        } catch { throw USBBridgeStopReason.sessionInvalid }
    }
    private func lost(_ reason: USBBridgeStopReason) async {
        guard !stopped else { return }
        // STOP may await a device ACK. Keep the originating failure visible if
        // the lifecycle/watchdog observes revocation before onLoss is delivered.
        executionContext?.revoke(message: reason.message)
        diagnostics?.record("bridge.stop reason=\(reason.rawValue) \(executionContext?.diagnosticSummary ?? frames.diagnostics().summary)")
        await stop(); onLoss(reason)
    }
    func screenshot() async throws -> FrameImage {
        guard !stopped else { throw AppError.stopped }
        let started = ProcessInfo.processInfo.systemUptime
        diagnostics?.record("screenshot.begin \(executionContext?.diagnosticSummary ?? "context=none")")
        let deadline = started + (executionContext?.backgroundEnabled == true ? 15 : 2)
        repeat {
            try Task.checkCancellation()
            guard !stopped else { throw AppError.stopped }
            var observation: ScreenUSBExecutionContext.Observation?
            if let context = executionContext {
                // Reading the App's stream is valid in the foreground too.
                // Input is also allowed in PhoneAgent under the task grant.
                guard let scope = try context.captureObservation() else {
                    try await Task.sleep(nanoseconds: 40_000_000); continue
                }
                observation = scope
            }
            if let frame = try? frames.encoded(after: barrierSequence, notBefore: max(barrierTime, observation?.after ?? 0)) {
                // A scene transition during PNG encoding invalidates this observation.
                if let context = executionContext {
                    guard let current = try context.captureObservation(), current.revision == observation?.revision,
                          frame.capture!.uptime > current.after else { continue }
                }
                diagnostics?.record("screenshot.ready sequence=\(frame.capture?.sequence ?? 0) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) \(executionContext?.diagnosticSummary ?? "context=none")")
                approvedImageID = nil; image = frame; return frame
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        await lost(.screenshotTimeout); throw AppError.unavailable(USBBridgeStopReason.screenshotTimeout.message)
    }
    func tap(x: Int, y: Int, imageID: String) async throws {
        try await input("TAP \(x) \(y)", coordinates: [x, y], imageID: imageID)
    }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {
        guard (100...2000).contains(durationMS) else { throw AppError.invalid(String(localized: "Invalid drag duration")) }
        try await input("DRAG \(fromX) \(fromY) \(toX) \(toY) \(durationMS)",
                        coordinates: [fromX, fromY, toX, toY], imageID: imageID)
    }
    private func input(_ body: String, coordinates: [Int], imageID: String) async throws {
        try Task.checkCancellation()
        guard !stopped, !inputInFlight, coordinates.allSatisfy({ (0...65535).contains($0) }),
              let approved = image, approved.id == imageID, approved.capture != nil else { throw AppError.stopped }
        guard executionContext == nil || approvedImageID == imageID else { throw AppError.stopped }
        let session = try await requireInputSession()
        guard !stopped, !inputInFlight, image?.id == imageID else { throw AppError.stopped }
        image = nil; approvedImageID = nil; inputInFlight = true
        defer { inputInFlight = false }
        do {
            // A one-use task capability, not a screenshot-equality check. The
            // final enqueue still serializes capture/USB loss and explicit stop.
            let permit = executionContext.map { USBInputPermit(context: $0, inputSession: session) }
            diagnostics?.record("input.dispatch sceneAndImageGates=disabled epoch=\(session.generation) \(executionContext?.diagnosticSummary ?? "context=none")")
            try await transport.command(body, permit: permit)
            guard !stopped else { throw AppError.stopped }
            // Require an arrival after executed ACK; a pre-ACK frame is insufficient.
            barrierSequence = (try frames.latestStamp()).sequence
            barrierTime = ProcessInfo.processInfo.systemUptime
        } catch { await lost(.inputFailed); throw error }
    }
    func stop() async {
        if let stopTask { await stopTask.value; return }
        if let healthObserver { executionContext?.removeHealthObserver(healthObserver) }
        healthObserver = nil
        executionContext?.revoke()
        stopped = true; image = nil; monitor?.cancel(); monitor = nil
        let session = inputSession, opening = openingSession
        let task = Task {
            let owned: USBInputSession?
            if let session { owned = session } else { owned = try? await opening?.value }
            if let owned { await transport.stopInputs(owned) }
        }
        stopTask = task
        await task.value
    }
}
