// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import BackgroundTasks
import Observation

enum NCMControlError: Error { case unavailable(String), stopped }

@MainActor @Observable final class PairingFlow: NSObject, @preconcurrency NetServiceDelegate {
    static let shared = PairingFlow()
    static let taskID = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent.NCMProbe") + ".pairing"
    private let pairing = RemotePairingSession()
    private let backend = NativeDeveloperServices()
    private let client = NCMProbeClient()
    private let localDiscovery = LocalVPNDiscovery()
    private(set) var route: DeviceControlRoute
    private let defaults: UserDefaults
    private static let vpnConfigurationKey = "vpnLoopbackConfiguration"
    private(set) var vpnConfiguration: VPNLoopbackConfiguration
    func saveVPNConfiguration(localAddress: String, peerAddress: String) throws {
        guard canChangeRoute else { throw NCMControlError.unavailable(String(localized: "Stop the current control task before changing the connection settings")) }
        let configuration = try VPNLoopbackConfiguration(localAddress: localAddress, peerAddress: peerAddress)
        guard configuration != vpnConfiguration else { return }
        cancel()
        vpnConfiguration = configuration
        defaults.set(["localAddress": configuration.localAddress, "peerAddress": configuration.peerAddress], forKey: Self.vpnConfigurationKey)
        lastFailure = nil
        message = String(localized: "Settings saved. Reconnect to use them.")
    }
    var canChangeRoute: Bool { !running && !agentReserved && connectionUsers.isEmpty && !mediaLifetime.stopping }
    @discardableResult func selectRoute(_ selected: DeviceControlRoute) -> Bool {
        guard selected != .localCaptureUSB, canChangeRoute else { return false }
        guard selected != route else { return true }
        cancel()
        route = selected
        defaults.set(selected.rawValue, forKey: DeviceControlRoute.defaultsKey)
        lastFailure = nil
        message = hasRecord ? String(localized: "Connection method changed. Connect to verify it.") : String(localized: "Complete system pairing first")
        return true
    }
    private let store: RemotePairRecordStore
    private var service: NetService?
    private var generation = UUID()
    private(set) var connectionStopID: UUID? = UUID()
    private(set) var controlSessionID = UUID()
    private var agentOwner: UUID?
    private var connectionUsers: Set<UUID> = []
    private var agentRuns: Set<UUID> = []
    private var agentQueue: [UUID] = []
    private(set) var isBackground = false
    var agentReserved: Bool { !agentRuns.isEmpty || agentOwner != nil }
    private var registeredBackgroundTask = false
    private var mediaStarted = false
    private let mediaLifetime = ControlMediaLifetime()
    private var job: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatEpoch = UUID()
    private var maintenanceBusy = false
    private var backgroundTask: BGTask?
    private var operationLease: ExecutionTransitionLease?
    private(set) var capturing = false
    var running = false
    var pairingActive = false
    var lastFailure: String?
    var ready = false
    var hasRecord = false
    var pin: String?
    var message = String(localized: "Complete system pairing first")
    var image: UIImage?
    private(set) var screenshotData: Data?
    var statusText: String {
        if pairingActive { return message }
        if running { return ready ? String(localized: "Processing") : String(localized: "Connecting to \(route.connectionName)") }
        if ready {
            if lastFailure != nil { return String(localized: "The last action did not succeed") }
            return image == nil ? String(localized: "Screenshots and tapping are available") : String(localized: "Screenshot received")
        }
        if hasRecord { return lastFailure == nil ? String(localized: "Paired. You can connect to \(route.connectionName).") : String(localized: "Connection failed. If you revoked permission in Settings, pair again.") }
        return message
    }
    override convenience init() {
        self.init(store: RemotePairRecordStore(url: URL.applicationSupportDirectory.appending(path: "RemotePairing/identity.plist")))
    }
    init(store: RemotePairRecordStore, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults; route = DeviceControlRoute.load(from: defaults)
        let saved = defaults.dictionary(forKey: Self.vpnConfigurationKey) as? [String: String]
        vpnConfiguration = (try? VPNLoopbackConfiguration(localAddress: saved?["localAddress"] ?? VPNLoopbackConfiguration.defaults.localAddress,
            peerAddress: saved?["peerAddress"] ?? VPNLoopbackConfiguration.defaults.peerAddress)) ?? .defaults
        super.init(); hasRecord = store.exists
    }

    /// User explicitly requests new system authorization, even if a local identity remains.
    func resetPairing() {
        guard !running, !agentReserved else { return }
        cancel()
        do {
            try store.remove(); hasRecord = false; lastFailure = nil; pin = nil
            message = String(localized: "Complete system pairing first")
        } catch {
            hasRecord = store.exists; message = String(localized: "Could not clear the saved pairing identity. Try again."); lastFailure = message
        }
    }
    func pairAgain() {
        guard !running, !agentReserved else { return }
        resetPairing()
        if !hasRecord { startPairing() }
    }

    func registerBackgroundTask() {
        guard !registeredBackgroundTask else { return }
        if #available(iOS 26.0, *) {
            registeredBackgroundTask = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: .main) { task in
                Task { @MainActor in
                    guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                    Self.shared.begin(continued)
                }
            }
        }
    }
    func startPairing() {
        guard !running else { return }
        hasRecord = store.exists
        guard !hasRecord else { message = String(localized: "Connect to \(route.connectionName)"); return }
        guard registeredBackgroundTask else { message = String(localized: "The system pairing task was not registered. Reopen the app."); return }
        guard #available(iOS 26.0, *) else { message = String(localized: "Interactive system pairing needs continued background tasks on iOS 26 or later"); return }
        generation = UUID(); running = true; pairingActive = true; message = String(localized: "Requesting a background task for pairing. Please wait.")
        let request = BGContinuedProcessingTaskRequest(identifier: Self.taskID, title: String(localized: "PhoneAgent pairing"), subtitle: String(localized: "Complete authorization in system Settings"))
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch { running = false; pairingActive = false; message = String(localized: "The system did not allow the background task. Keep the app open and try again.") }
    }
    @available(iOS 26.0, *) private func begin(_ continued: BGContinuedProcessingTask) {
        guard pairingActive, running, job == nil else { continued.setTaskCompleted(success: false); return }
        let epoch = generation
        backgroundTask = continued
        continued.progress.totalUnitCount = 4; continued.progress.completedUnitCount = 1
        continued.expirationHandler = { Task { @MainActor in
            guard Self.shared.generation == epoch else { return }
            Self.shared.cancel()
        } }
        job = Task { @MainActor in
            var success = false
            defer { if generation == epoch { finishPairing(success: success) } }
            do {
                try await pairing.pair(authorized: true, persist: { record in
                    guard self.generation == epoch else { throw CancellationError() }
                    try self.store.save(record); self.hasRecord = true
                }, update: { update in
                    guard self.generation == epoch else { throw CancellationError() }
                    switch update {
                    case .listening(let advertisement):
                        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: advertisement.identifier, port: Int32(advertisement.port))
                        service.delegate = self
                        guard service.setTXTRecord(NetService.data(fromTXTRecord: advertisement.txt.mapValues { Data($0.utf8) })) else { throw NativeBackendError.malformedEvent }
                        self.service = service; service.publish()
                        self.message = String(localized: "Preparing system pairing")
                    case .code(let value): self.pin = value; self.message = String(localized: "Enter this PIN on the system pairing page"); continued.progress.completedUnitCount = 2
                    case .persisted(let committed): self.message = committed ? String(localized: "Confirming pairing") : String(localized: "Completing pairing"); continued.progress.completedUnitCount = 3
                    case .completed: self.message = String(localized: "Pairing succeeded. Return to the app and verify the \(route.connectionName) connection."); continued.progress.completedUnitCount = 4
                    }
                })
                success = true
            } catch is CancellationError { guard generation == epoch else { return }; message = String(localized: "Pairing stopped") }
            catch { guard generation == epoch else { return }; message = String(localized: "Pairing did not finish. Check local network access and the system pairing page.") }
        }
    }
    func netServiceDidPublish(_ sender: NetService) {
        guard service === sender else { return }
        message = String(localized: "Open Settings → Privacy & Security → Developer Mode and choose to pair with the app")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard service === sender else { return }
        cancel(); message = String(localized: "Could not prepare pairing. Check local network access and try again.")
    }
    private func finishPairing(success: Bool) {
        service?.stop(); service = nil; pairing.close(); pin = nil
        backgroundTask?.setTaskCompleted(success: success); backgroundTask = nil
        running = false; pairingActive = false; job = nil; hasRecord = store.exists
    }
    func cancel() {
        connectionStopID = UUID()
        mediaLifetime.revoke()
        operationLease?.complete(success: false); operationLease = nil
        stopHeartbeat()
        generation = UUID(); controlSessionID = UUID(); agentOwner = nil; agentRuns.removeAll(); agentQueue.removeAll()
        job?.cancel(); pairing.close(); service?.stop(); service = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        if pairingActive { finishPairing(success: false) }
        backend.close(); client.cancel(); localDiscovery.cancel(); ready = false; mediaStarted = false; image = nil; screenshotData = nil; running = false; capturing = false; job = nil
        message = String(localized: "Stopped")
    }
    func background() {
        isBackground = true
        // App visibility does not revoke an authenticated device session.
        // Active runs own their system execution leases; settings operations
        // own a finite transition lease. Explicit stop/expiry/transport loss
        // still closes the session, without replaying input after reconnect.
    }
    func resume() {
        let wasBackground = isBackground
        isBackground = false
        // Cancelling an in-flight native readiness request closes its transport.
        // Scene transitions may wake an idle heartbeat, never cancel active I/O.
        if ready, wasBackground, !maintenanceBusy { startHeartbeat(immediate: true) }
        restoreConnection()
    }
    func restoreConnection() {
        hasRecord = store.exists
        if hasRecord, !pairingActive, !running, !ready { verify() }
    }
    /// Called only by a device tool or App startup, never by normal chat.
    /// Concurrent waiters share the same verification job.
    func connectIfNeeded() throws {
        hasRecord = store.exists
        if ready || pairingActive { return }
        guard hasRecord else { throw NCMControlError.unavailable(String(localized: "Complete system pairing in Settings → Phone control → Connection and verification first")) }
        if !running && !agentReserved { verify() }
    }
    func verify() {
        guard !running, !agentReserved, store.exists else { return }
        let previousMaintenance = heartbeatTask
        stopHeartbeat()
        mediaLifetime.revoke()
        generation = UUID(); controlSessionID = UUID(); let epoch = generation
        running = true; ready = false; mediaStarted = false; image = nil; screenshotData = nil; lastFailure = nil; backend.close()
        beginOperationLease(epoch: epoch)
        job = Task { @MainActor in
            defer { if generation == epoch { finishOperationLease(); running = false; job = nil } }
            do {
                await previousMaintenance?.value
                try Task.checkCancellation()
                guard generation == epoch else { return }
                var identity = try store.load().identity(); defer { identity.clearSeed() }
                let authorization = ExistingSessionAuthorization(verifyExistingIdentity: true, screen: true, screenVideoStream: true, input: true)
                if route == .vpnLoopback {
                    message = String(localized: "Finding this phone's RemotePairing service. Keep the VPN loopback connection on.")
                    let configuration = vpnConfiguration
                    let port = try await localDiscovery.discoverPort(configuration: configuration)
                    try Task.checkCancellation(); guard generation == epoch else { return }
                    message = String(localized: "Verifying identity and opening the CoreDevice tunnel through VPN loopback")
                    try await backend.connectLocalVPN(identity: identity, authorization: authorization, pairingPort: port, configuration: configuration)
                } else {
                    message = String(localized: "Finding the phone's RemotePairing service through ESP32")
                    var discovery = try await client.request(.discoverIPv4)
                    if discovery.endpoints?.contains(where: { $0.service == "remotepairing" }) != true {
                        discovery = try await client.request(.discoverIPv6)
                    }
                    try Task.checkCancellation(); guard generation == epoch else { return }
                    guard let endpoint = discovery.endpoints?.first(where: { $0.service == "remotepairing" }) else {
                        throw NCMControlError.unavailable(String(localized: "Phone service not found. Check the ESP32 connection."))
                    }
                    message = String(localized: "Verifying identity and opening the developer tunnel through ESP32")
                    try await backend.connect(identity: identity, authorization: authorization, discovery: discovery, endpoint: endpoint)
                }
                try await backend.checkDeveloperReadiness()
                try Task.checkCancellation(); guard generation == epoch else { return }
                ready = true; startHeartbeat(); message = String(localized: "\(route.connectionName) authentication, tunnel, and service checks succeeded. You can test screenshots and input.")
            } catch { guard generation == epoch else { return }; backend.close(); message = failure(error); lastFailure = message }
        }
    }
    #if DEBUG
    func videoDiagnosticKeyframe() async -> Data? { await backend.videoDiagnosticKeyframe() }
    #endif
    func capture() { operation(capturing: true) {
        try await self.prepareAgentInput(self.backend)
        let png = try await self.backend.captureVideoJPEG()
        try Task.checkCancellation()
        guard let image = UIImage(data: png) else { throw NativeBackendError.malformedEvent }
        self.screenshotData = png; self.image = image; self.message = String(localized: "Phone screenshot received")
    } }
    func tapCenter() { operation {
        try await self.prepareAgentInput(self.backend)
        _ = try await self.backend.tapDelivery(x: 32768, y: 32768)
        try Task.checkCancellation()
        self.message = String(localized: "A tap was sent to the screen center. Check your phone to confirm the result.")
    } }
    private func operation(capturing: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard ready, !running, !agentReserved else { return }
        generation = UUID(); let epoch = generation
        running = true; self.capturing = capturing
        beginOperationLease(epoch: epoch)
        job = Task { @MainActor in
            defer {
                if generation == epoch {
                    running = false; self.capturing = false; job = nil
                    finishControlMediaIfIdle()
                    if !mediaLifetime.stopping { finishOperationLease() }
                }
            }
            do {
                // User requests queue behind an in-flight keepalive; the UI only
                // becomes busy after a user operation, never for maintenance.
                while maintenanceBusy {
                    try await Task.sleep(for: .milliseconds(10))
                    guard generation == epoch else { return }
                }
                try Task.checkCancellation()
                guard generation == epoch, ready else { return }
                try await action()
                lastFailure = nil
            }
            catch {
                guard generation == epoch else { return }
                if case NativeBackendError.touchPreparationFailure = error {
                    mediaStarted = false
                    message = String(localized: "\(failure(error)). No tap was sent.")
                    lastFailure = message
                } else if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
                    BackgroundExecutionTrace.record("screenshot.failed stage=\(stage) cause=\(cause) connectionRetained=true")
                    message = failure(error)
                    lastFailure = message
                } else {
                    stopHeartbeat(); ready = false; mediaStarted = false; backend.close()
                    message = String(localized: "\(failure(error)); reconnect to \(route.connectionName)"); lastFailure = message
                }
            }
        }
    }
    /// A task pins one authenticated session. Reconnect never silently substitutes
    /// another generation; diagnostics and task traffic share the operation gate.
    func agentOperation<T>(owner: UUID, session: UUID, action: (NativeDeveloperServices) async throws -> T) async throws -> T {
        guard ready, controlSessionID == session else { throw NCMControlError.unavailable(String(localized: "Phone control is not connected. Connect in Settings → Phone control → Connection and verification.")) }
        if agentOwner != owner {
            if !agentQueue.contains(owner) { agentQueue.append(owner) }
            defer { agentQueue.removeAll { $0 == owner } }
            while running || agentOwner != nil || agentQueue.first != owner {
                try Task.checkCancellation()
                guard ready, controlSessionID == session, agentRuns.contains(owner) else { throw NCMControlError.stopped }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        try Task.checkCancellation()
        guard ready, controlSessionID == session, agentRuns.contains(owner) else { throw NCMControlError.stopped }
        agentOwner = owner
        running = true
        defer { if controlSessionID == session { running = false } }
        do {
            while maintenanceBusy {
                try await Task.sleep(for: .milliseconds(10))
                guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            }
            try Task.checkCancellation()
            guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            let value = try await action(backend)
            try Task.checkCancellation()
            guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            lastFailure = nil
            return value
        } catch {
            guard controlSessionID == session else { throw NCMControlError.stopped }
            if case NativeBackendError.touchPreparationFailure = error {
                mediaStarted = false; message = String(localized: "\(failure(error)). No input was sent."); lastFailure = message
                throw NCMControlError.unavailable(message)
            }
            if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
                BackgroundExecutionTrace.record("screenshot.failed stage=\(stage) cause=\(cause) connectionRetained=true")
                message = failure(error)
                lastFailure = message
                throw NCMControlError.unavailable(message)
            }
            if case NativeBackendError.applicationQueryFailure(let stage, let cause) = error {
                BackgroundExecutionTrace.record("apps.query.failed stage=\(stage) cause=\(cause)")
                throw NCMControlError.unavailable(String(localized: "Could not list installed apps. Try again later."))
            }
            if error is CancellationError || (error as? NCMControlError) != nil {
                cancel(); throw NCMControlError.stopped
            }
            message = String(localized: "\(failure(error)); reconnect to \(route.connectionName)"); lastFailure = message
            stopHeartbeat(); ready = false; mediaStarted = false; backend.close()
            invalidateAgentSession(); running = false
            throw NCMControlError.unavailable(message)
        }
    }
    func prepareAgentInput(_ services: NativeDeveloperServices) async throws {
        if !mediaStarted {
            try await services.startTouchMedia()
            try Task.checkCancellation()
            mediaStarted = true
            mediaLifetime.didOpen()
        }
    }
    private func invalidateAgentSession() {
        mediaLifetime.revoke()
        controlSessionID = UUID(); agentOwner = nil
        agentRuns.removeAll(); agentQueue.removeAll()
    }
    func mediaLifetimeWait() async { await mediaLifetime.wait() }
    func canActivateApplication(owner: UUID, session: UUID) -> Bool {
        ready && controlSessionID == session && !running &&
            (agentOwner == owner || (agentOwner == nil && agentQueue.isEmpty))
    }
    func retainConnection(owner: UUID) { connectionUsers.insert(owner) }
    func releaseConnection(owner: UUID) {
        connectionUsers.remove(owner)
    }
    func registerAgent(owner: UUID, session: UUID) {
        guard ready, controlSessionID == session else { return }
        agentRuns.insert(owner)
    }
    func releaseAgent(owner: UUID, session: UUID) {
        guard controlSessionID == session else { return }
        agentRuns.remove(owner); agentQueue.removeAll { $0 == owner }
        guard agentOwner == owner else {
            finishControlMediaIfIdle()
            return
        }
        // Partial/cancelled operations remain fatal. Completed runs release media
        // only after the final registered controller finishes; queued runs share it.
        if running { cancel() } else {
            agentOwner = nil
            finishControlMediaIfIdle()
        }
    }
    private func finishControlMediaIfIdle() {
        guard ready, !running, mediaStarted else { return }
        let session = controlSessionID
        let accepted = mediaLifetime.finishIfIdle(hasUsers: !agentRuns.isEmpty || agentOwner != nil,
            stop: { [weak self] in
                guard let self else { throw CancellationError() }
                while self.maintenanceBusy {
                    try await Task.sleep(for: .milliseconds(10))
                    guard self.controlSessionID == session else { throw CancellationError() }
                }
                guard self.controlSessionID == session, self.ready else { throw CancellationError() }
                BackgroundExecutionTrace.record("control.mediaStopRequested scoped=true")
                try await self.backend.stopTouchMedia()
            }, completed: { [weak self] success in
                guard let self, self.controlSessionID == session else { return }
                self.running = false; self.mediaStarted = false
                self.finishOperationLease()
                if success {
                    BackgroundExecutionTrace.record("control.mediaReleased peerConfirmed=true connectionRetained=true")
                    self.message = String(localized: "Screen control ended")
                } else {
                    self.cancel()
                    self.message = String(localized: "Could not end screen control. Reconnect.")
                    self.lastFailure = self.message
                }
            })
        if accepted { running = true }
    }
    /// Termination notification is best-effort; synchronous native handle close
    /// revokes all App-owned transports without waiting for an async stop reply.
    func applicationWillTerminate() { cancel() }
    private func beginOperationLease(epoch: UUID) {
        finishOperationLease()
        let lease = ExecutionTransitionLease()
        lease.expirationHandler = { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.cancel()
            self.message = String(localized: "Background execution expired. The action was stopped.")
            self.lastFailure = self.message
        }
        lease.begin(); operationLease = lease
    }
    private func finishOperationLease() {
        operationLease?.complete(success: true); operationLease = nil
    }
    private func stopHeartbeat() {
        heartbeatEpoch = UUID(); heartbeatTask?.cancel(); heartbeatTask = nil; maintenanceBusy = false
    }
    /// Read-only service traffic keeps the ESP32's 60-second relay idle lease alive.
    /// Shares the operation gate; never overlaps a screenshot or touch request.
    private func startHeartbeat(immediate: Bool = false) {
        stopHeartbeat(); let epoch = heartbeatEpoch
        heartbeatTask = Task { @MainActor [weak self] in
            var delay: Duration = immediate ? .zero : .seconds(20)
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                delay = .seconds(20)
                guard let self, self.heartbeatEpoch == epoch, self.ready else { return }
                if self.running { continue }
                self.maintenanceBusy = true
                do {
                    try await self.backend.checkDeveloperReadiness()
                    guard self.heartbeatEpoch == epoch else { return }
                    self.maintenanceBusy = false
                } catch {
                    guard self.heartbeatEpoch == epoch else { return }
                    self.maintenanceBusy = false; self.ready = false; self.mediaStarted = false; self.running = false
                    self.backend.close(); self.invalidateAgentSession()
                    self.message = String(localized: "Connection keep-alive failed: \(self.failure(error)); reconnect to \(route.connectionName)")
                    self.lastFailure = self.message
                    return
                }
            }
        }
    }
    private func failure(_ error: Error) -> String {
        if case NCMControlError.unavailable(let message) = error { return message }
        if let vpnError = error as? LocalVPNError {
            switch vpnError {
            case .inactive: return String(localized: "VPN interface \(vpnConfiguration.localAddress) was not found. Check that VPN is on and its addresses are correct.")
            case .ambiguousInterface: return String(localized: "Multiple matching VPN interfaces were found. Check your connection settings.")
            case .serviceNotFound: return String(localized: "This phone's RemotePairing service was not found. Check Developer Mode, system pairing, and local network access.")
            case .ambiguousService: return String(localized: "Multiple local RemotePairing ports were found. Reconnect and try again.")
            case .invalidConfiguration: return String(localized: "Enter two different, valid IPv4 interface and peer addresses")
            case .discoveryDenied: return String(localized: "Local service discovery failed. Allow local network access.")
            }
        }

        if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
            return failure(NativeBackendError.protocolFailure(stage: stage, cause: cause))
        }

        if case NativeBackendError.touchPreparationFailure(let stage, let cause) = error {
            let labels: [UInt32: String] = [10:String(localized: "Video service availability"), 11:String(localized: "Touch service availability"), 13:String(localized: "Video receive port"), 14:String(localized: "Video service connection"), 15:String(localized: "Video session request"), 16:String(localized: "Video negotiation response"), 17:String(localized: "Valid video packet reception"), 18:String(localized: "Touch service connection")]
            let reasons: [UInt32: String] = [1:String(localized: "Protocol error"), 2:String(localized: "Timed out"), 3:String(localized: "Invalid parameter"), 4:String(localized: "Service missing"), 5:String(localized: "Not ready")]
            return String(localized: "Could not prepare touch input: \(labels[stage] ?? String(localized: "Video preparation")), \(reasons[cause] ?? String(localized: "Reason \(cause)"))")
        }
        if case NativeBackendError.protocolFailure(let stage, let cause) = error {
            if stage == 19 || stage == 20 {
                let reasons: [UInt32: String] = [1:String(localized: "Protocol error"), 2:String(localized: "Timed out"), 3:String(localized: "Invalid parameter"), 4:String(localized: "Service missing"), 5:String(localized: "Not ready"), 8:String(localized: "Timed out without receiving video data"), 9:String(localized: "Timed out without receiving a matching video packet"), 10:String(localized: "Timed out before a complete video frame was received"), 11:String(localized: "Timed out before video image integrity could be confirmed"), 12:String(localized: "Timed out because the video image exceeded the receive limit"), 13:String(localized: "Video decoding session is no longer valid"), 14:String(localized: "Video decoding failed")]
                return String(localized: "Screenshot \(stage == 19 ? String(localized: "connection") : String(localized: "request and reception")) failed (\(reasons[cause] ?? String(localized: "Reason \(cause)")))")
            }
            let labels: [UInt32: String] = [1:String(localized: "Pairing identity"), 2:String(localized: "\(route.connectionName) connection"), 3:String(localized: "Phone authentication"), 4:String(localized: "Dynamic tunnel discovery"), 5:String(localized: "Tunnel TLS"), 6:String(localized: "Remote service list"), 7:String(localized: "Developer Mode"), 8:String(localized: "Developer image"), 9:String(localized: "Screenshot"), 10:String(localized: "Screen video session"), 11:String(localized: "Input delivery"), 12:String(localized: "Session close"), 21:String(localized: "App service")]
            let reasons: [UInt32: String] = [1:String(localized: "Protocol error"), 2:String(localized: "Timed out"), 3:String(localized: "Invalid parameter"), 4:String(localized: "Service missing"), 5:String(localized: "Not ready"), 6:String(localized: "Screen session is no longer valid"), 7:String(localized: "Delivery result unknown")]
            return String(localized: "\(labels[stage] ?? String(localized: "Protocol")) failed (\(reasons[cause] ?? String(localized: "Reason \(cause)")))")
        }
        if error is CancellationError { return String(localized: "Stopped") }
        return route == .vpnLoopback
            ? String(localized: "Connection failed. Check VPN loopback settings, Developer Mode, and local network access.")
            : String(localized: "Connection failed. Check ESP32 firmware, the NCM interface, and local network access.")
    }
    #if DEBUG
    private var backgroundProbeStarted = false
    /// Opt-in real-device acceptance probe. Uses the production bridge and
    /// scheduler; logs state/dimensions. The additional input-probe flag saves
    /// three local verification images for the reversible Home-screen swipe.
    func runBackgroundProbeIfRequested(pip: StatusPiPController? = nil) async {
        guard (ProcessInfo.processInfo.arguments.contains("--ncm-background-probe") || pip != nil), !backgroundProbeStarted else { return }
        backgroundProbeStarted = true
        let url = URL.documentsDirectory.appending(path: "ncm-background-probe.txt")
        var lines: [String] = []
        func record(_ value: String) {
            lines.append("\(Date().ISO8601Format()) \(value)")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        record("start paired=\(hasRecord)")
        if !ready && !running { verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !ready && running && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { record("connect failed: \(message)"); return }
        let systemScheduler = ContinuedProcessingScheduler()
        systemScheduler.diagnostic = { record($0) }
        let scheduler: any RunBackgroundScheduler = pip == nil
            ? systemScheduler : CompositeRunScheduler(allowed: { [.pictureInPicture] })
        let identifier = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun." + UUID().uuidString
        var lease: (any RunBackgroundLease)?
        var expired = false
        var activeBridge: NCMDeviceBridge?
        do {
            try scheduler.submit(identifier: identifier, launched: { grant in
                lease = grant
                grant.expirationHandler = { expired = true; activeBridge?.cancelTransport(); record("execution expired") }
            })
            if pip != nil { record("PiP-only acceptance active=\(pip?.active == true); combined lease=\(lease != nil); no system execution lease requested") }
            let bridge = try NCMDeviceBridge(flow: self)
            activeBridge = bridge
            defer { lease?.complete(success: !expired); scheduler.cancel(identifier: identifier) }
            do {
                let frame = try await bridge.screenshot()
                record("foreground capture \(frame.width)x\(frame.height) bytes=\(frame.png.count); background switch window=15s")
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
                for step in 1...3 {
                    try await Task.sleep(for: .seconds(15))
                    guard !expired else { throw AppError.stopped }
                    record("readiness \(step) start background=\(isBackground) pip=\(pip?.active == true)")
                    while maintenanceBusy { try await Task.sleep(for: .milliseconds(10)) }
                    running = true
                    do { try await backend.checkDeveloperReadiness(); running = false }
                    catch { running = false; throw error }
                    record("readiness \(step) ok")
                    let start = ContinuousClock.now
                    let frame = try await bridge.screenshot()
                    record("capture \(step) background=\(isBackground) ready=\(ready) \(frame.width)x\(frame.height) bytes=\(frame.png.count) elapsed=\(start.duration(to: .now))")
                    lease?.report(completed: step, subtitle: String(localized: "Background screenshot verification \(step)/3"))
                    if step == 1 && ProcessInfo.processInfo.arguments.contains("--ncm-background-input-probe") {
                        try frame.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-before.png"))
                        try await bridge.authorizeTaskInput(imageID: frame.id)
                        try await bridge.drag(fromX: 52428, fromY: 32768, toX: 13107, toY: 32768, durationMS: 300, imageID: frame.id)
                        record("background swipe-left reports written")
                        lease?.report(completed: step + 1, subtitle: String(localized: "Background swipe sent. Checking the screen."))
                        try await Task.sleep(for: .seconds(1))
                        let changed = try await bridge.screenshot()
                        try changed.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-after.png"))
                        lease?.report(completed: step + 2, subtitle: String(localized: "Screenshot received after swiping. Restoring the Home Screen."))
                        try await bridge.authorizeTaskInput(imageID: changed.id)
                        try await bridge.drag(fromX: 13107, fromY: 32768, toX: 52428, toY: 32768, durationMS: 300, imageID: changed.id)
                        record("background swipe-right reports written")
                        lease?.report(completed: step + 3, subtitle: String(localized: "Restore swipe sent. Checking the Home Screen."))
                        try await Task.sleep(for: .seconds(1))
                        let restored = try await bridge.screenshot()
                        try restored.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-restored.png"))
                        record("background swipe verification images saved")
                        record("complete"); break
                    }
                }
                record("complete")
            } catch { record("capture failed background=\(isBackground): \(message); \(error)") }
            await bridge.stop()
        } catch { record("probe failed: \(error)") }
    }
    #endif
}

struct PairingSection: View {
    @State private var flow = PairingFlow.shared
    let showTouchTest: () -> Void
    private var stateText: String {
        if flow.pairingActive { return String(localized: "Pairing") }
        if flow.ready { return String(localized: "Connected") }
        if flow.running { return String(localized: "Connecting") }
        return flow.hasRecord ? String(localized: "Not connected") : String(localized: "Not paired")
    }
    private var showsDetail: Bool {
        (flow.running && !flow.ready) ||
        (!flow.hasRecord && flow.message != String(localized: "Complete system pairing first"))
    }
    var body: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(stateText).foregroundStyle(flow.ready ? .green : .secondary)
                        if flow.running && !flow.ready { ProgressView().controlSize(.small) }
                    }
                    if showsDetail {
                        Text(flow.lastFailure ?? flow.statusText)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("pairingResult")
                    }
                    if let pin = flow.pin {
                        Text(pin).font(.title.monospacedDigit())
                            .accessibilityIdentifier("pairingPIN")
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if !flow.ready && !flow.running && !flow.agentReserved {
                        Button(flow.hasRecord ? String(localized: "Connect") : String(localized: "Pair")) {
                            if flow.hasRecord { flow.verify() }
                            else { flow.startPairing() }
                        }.disabled(flow.running || flow.agentReserved)
                    }
                    if !flow.ready && flow.hasRecord && !flow.running && !flow.agentReserved {
                        Button(String(localized: "Pair again")) { flow.pairAgain() }
                            .accessibilityIdentifier("pairAgain")
                    }
                    if flow.running || flow.ready || flow.agentReserved {
                        Button(String(localized: "Stop")) { flow.cancel() }
                    }
                }
                .buttonStyle(.bordered)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        if flow.ready {
            Section(String(localized: "Service verification")) {
                Button { flow.capture() } label: {
                    HStack {
                        Text(flow.capturing ? String(localized: "Taking a screenshot") : String(localized: "Take screenshot"))
                        if flow.capturing { ProgressView().controlSize(.small) }
                    }
                }.disabled(flow.running || flow.agentReserved)
                Button(String(localized: "Verify tap"), action: showTouchTest).disabled(flow.running || flow.agentReserved)
            }
            if let image = flow.image {
                Section {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(String(localized: "Phone screenshot"))
                } header: {
                    HStack {
                        Text(String(localized: "Screenshot"))
                        Spacer()
                        if let data = flow.screenshotData {
                            SaveScreenshotButton(data: data).disabled(flow.capturing)
                        }
                    }
                }
            }
        }
    }
}

/// The counter is changed only by UIKit/SwiftUI delivering a real button action,
/// never by an HID send acknowledgement. Keep this page foreground during test.
struct TouchVerificationView: View {
    let flow: PairingFlow
    @Environment(\.dismiss) private var dismiss
    @State private var count = 0
    @State private var baseline = 0
    @State private var testing = false
    @State private var result = String(localized: "Do not touch the center button during the test")
    @State private var task: Task<Void, Never>?
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Button { count += 1 } label: {
                VStack {
                    Text(String(localized: "Center touch target")).font(.title2)
                    Text(String(localized: "Touches received: \(count)")).font(.title.monospacedDigit())
                }.frame(width: 260, height: 160)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("touchVerificationTarget")
            VStack {
                HStack { Text(String(localized: "Verify actual taps")).font(.headline); Spacer(); Button(String(localized: "Close")) { dismiss() }.disabled(testing) }
                Spacer()
                Text(result).multilineTextAlignment(.center).accessibilityIdentifier("touchVerificationResult")
                Text(flow.message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !flow.ready {
                    Button(String(localized: "Reconnect to \(flow.route.connectionName)")) { flow.verify() }.disabled(flow.running || flow.agentReserved)
                }
                if testing { ProgressView() }
                Button(String(localized: "Tap the center target through \(flow.route.connectionName)")) { test() }.buttonStyle(.bordered).disabled(testing || !flow.ready || flow.running || flow.agentReserved)
                Text(String(localized: "Keep this page open. An increased count confirms that the screen received the tap. A successful send alone does not confirm delivery."))
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .interactiveDismissDisabled()
        .onDisappear { task?.cancel(); if testing { flow.cancel() } }
    }
    private func test() {
        baseline = count; testing = true; result = String(localized: "Preparing the video session and sending one center tap. Do not touch the screen.")
        task = Task { @MainActor in
            defer { testing = false; task = nil }
            flow.tapCenter()
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    if !flow.running {
                        try await Task.sleep(for: .milliseconds(500))
                        result = count > baseline ? String(localized: "Verified: the test page received a tap and the count increased") : String(localized: "Tap not confirmed: the count did not change.\n\(flow.message)")
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                flow.cancel()
                result = String(localized: "Timed out without confirming a tap. It will not be resent automatically.")
            } catch { result = String(localized: "Test stopped") }
        }
    }
}
