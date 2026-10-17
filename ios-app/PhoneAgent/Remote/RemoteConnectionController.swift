import Foundation
import Network
import Observation
#if DEBUG
import CryptoKit
#endif

@MainActor @Observable final class RemoteConnectionController {
    private let service: RemoteToolsService
    private let store: RemoteConnectionStore
    private let journalDirectory: URL?
    private let uptime: @MainActor () -> TimeInterval
    let pairing: SimpleLANPairing
    @ObservationIgnored private var pairingTimer: Task<Void, Never>?
    private var stoppingByUser = false
    @ObservationIgnored private var foregroundActive = false
    @ObservationIgnored private var resumeRequested = false
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryAttempt = 0
    private let recoveryDelay: @MainActor (Int) -> Duration
    private(set) var isEnabled = false
    private(set) var connectionIssue: String?
    private let canConfigure: @MainActor () -> Bool
    private(set) var settings: RemoteConnectionSettings
    private(set) var status = RemoteToolsService.ConnectionState.stopped
    var message: String?
    private(set) var lastAuthenticatedAt: [String: Date] = [:]
    private var lastAuthenticatedUptime: [String: TimeInterval] = [:]
    func isPeerOnline(_ clientID: String) -> Bool {
        guard service.isListening, settings.clients.contains(where: { $0.id == clientID && $0.identityConfirmed }),
              let seen = lastAuthenticatedUptime[clientID] else { return false }
        return (0..<MuseCompanionProtocol.peerFreshness).contains(uptime() - seen)
    }
    private func recordAuthenticatedActivity(_ clientID: String) {
        lastAuthenticatedAt[clientID] = Date()
        lastAuthenticatedUptime[clientID] = uptime()
    }
    func peerStatus(_ client: RemoteClientRegistration, now: Date = Date()) -> String {
        if !client.identityConfirmed, client.bootstrapExpiresAt.map({ $0 <= now }) != false {
            return String(localized: "Pairing details expired. Remove the device and add it again.")
        }
        guard client.requestedDeviceName != nil else { return String(localized: "Waiting for the device after USB setup") }
        guard client.identityConfirmed, !client.scopes.isEmpty else { return String(localized: "Waiting for device approval") }
        guard isPeerOnline(client.id) else { return String(localized: "Authorized, not connected") }
        return String(localized: "Connected and authenticated")
    }
    var isActive: Bool { status != .stopped }
    init(service: RemoteToolsService, store: RemoteConnectionStore, journalDirectory: URL? = nil,
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         recoveryDelay: @escaping @MainActor (Int) -> Duration = { .seconds(1 << min($0, 5)) },
         canConfigure: @escaping @MainActor () -> Bool = { true }) {
        self.service = service; self.store = store; self.settings = store.settings; self.canConfigure = canConfigure
        self.journalDirectory = journalDirectory
        self.uptime = uptime
        self.recoveryDelay = recoveryDelay
        self.isEnabled = store.serviceEnabled
        self.pairing = SimpleLANPairing(store: store, fence: { [service] id in service.revoke(clientID: id) })
        message = store.loadError
        service.recordPreference("service.preference.loaded", enabled: isEnabled)
        pairing.diagnostic = { [weak service] stage, request, client, code in
            service?.recordPairing(stage, request: request, client: client, code: code)
        }
        service.connectionStateChanged = { [weak self] value in
            guard let self else { return }
            let previous = self.status; self.status = value
            if value == .stopped || value == .stopping {
                if previous != .stopped, !self.stoppingByUser, self.foregroundActive {
                    self.connectionIssue = String(localized: "Connection interrupted. Check the local network and restart Muse Gadget Service.")
                }
                self.pairing.setAvailable(false)
                self.lastAuthenticatedAt.removeAll()
                self.lastAuthenticatedUptime.removeAll()
                self.pairingTimer?.cancel(); self.pairingTimer = nil
                if value == .stopped { self.stoppingByUser = false }
                if value == .stopped, self.resumeRequested {
                    Task { @MainActor [weak self] in self?.restoreIfNeeded() }
                } else if value == .stopped, self.service.listenerFailure != nil {
                    // Authorization/storage failures stop safely and must not be
                    // mistaken for a recoverable network interruption.
                    self.scheduleRecovery()
                }
            } else if self.service.isListening {
                self.recoveryAttempt = 0
                self.cancelRecovery()
                self.pairing.setAvailable(true)
            }
        }
        pairing.changed = { [weak self] in
            guard let self else { return }
            self.settings = self.store.settings
            self.service.setPairingWindow(self.pairing.acceptingRequests)
            if self.pairing.error != nil, !self.pairing.available, self.isActive { self.service.stop() }
        }
        service.pairingRequest = { [weak self] path, body, headers in
            guard let self else { return RemoteHTTPResponse(status: 503, body: Data("{\"v\":1,\"error\":\"time_unavailable\"}".utf8)) }
            return self.pairing.handle(path: path, body: body, headers: headers)
        }
        service.companionHello = { [weak self] id, name in
            guard let self else { throw RemoteRPCError("unauthorized", "Service unavailable") }
            self.pairing.tick()
            if self.store.settings.clients.first(where: { $0.id == id })?.lanPairingState != nil {
                try self.pairing.acknowledge(clientID: id, name: name)
            } else { try self.store.recordHello(clientID: id, name: name) }
            self.settings = self.store.settings
            guard let client = self.settings.clients.first(where: { $0.id == id }) else { throw RemoteRPCError("unauthorized", "Unknown client") }
            let authorized = client.identityConfirmed && !client.scopes.isEmpty
            if client.identityConfirmed { self.recordAuthenticatedActivity(id) }
            var result: [String: Any] = ["state": authorized ? "authorized" : "pending_authorization", "scopes": client.scopes.map(\.rawValue).sorted()]
            if client.identityConfirmed { result["pairing_state"] = "active" }
            return result
        }
        service.authorizeRequest = { [weak self] id, op, params in
            self?.store.permits(clientID: id, op: op, params: params) ?? false
        }
        service.authenticatedRequest = { [weak self] id in self?.recordAuthenticatedActivity(id) }
        service.keyLookupDiagnostic = { [weak self] id in
            guard let self, self.isActive else { return "service_inactive" }
            return self.store.credentialDiagnostic(for: id)
        }
    }
    static func make(service: RemoteToolsService, model: AgentViewModel) -> RemoteConnectionController {
        let ready: @MainActor () -> Bool = { [weak model] in model?.remoteCanConfigure == true && model?.hasBusySessions == false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] == "1" {
            let vault = RemoteMemoryVault()
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-muse-preference"),
               let suite = ProcessInfo.processInfo.environment["MUSE_PREFERENCE_TEST_SUITE"],
               suite.hasPrefix("actell.muse.preference-ui."), let defaults = UserDefaults(suiteName: suite) {
                if ProcessInfo.processInfo.environment["MUSE_PREFERENCE_TEST_RESET"] == "1" {
                    defaults.removePersistentDomain(forName: suite)
                }
                // Process-relaunch fixture: real preferences, no listener, keys or device access.
                return .init(service: service, store: .init(vault: vault, defaults: defaults), canConfigure: { false })
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-muse-request") {
                let store = RemoteConnectionStore(vault: vault, defaults: nil)
                let controller = RemoteConnectionController(service: service, store: store, canConfigure: ready)
                controller.runLANPairingUIFixture(ready: ready)
                return controller
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-muse-device") || ProcessInfo.processInfo.arguments.contains("--ui-test-muse-pending") {
                let suite = "actell.muse.ui-fixture." + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                var settings = RemoteConnectionSettings()
                var client = RemoteClientRegistration(id: "11111111-1111-4111-8111-111111111111", name: "书桌上的 Muse", pairedAt: Date())
                client.identityConfirmed = !ProcessInfo.processInfo.arguments.contains("--ui-test-muse-pending")
                client.requestedDeviceName = client.name
                if client.identityConfirmed { client.bootstrapExpiresAt = nil }
                settings.clients = [client]
                defaults.set(try? JSONEncoder().encode(settings), forKey: "actell.muse.connection.v1")
                let store = RemoteConnectionStore(vault: vault, defaults: defaults)
                defaults.removePersistentDomain(forName: suite)
                return .init(service: service, store: store, canConfigure: ready)
            }
            return .init(service: service, store: .init(vault: vault, defaults: nil), canConfigure: ready)
        }
        #endif
        return .init(service: service, store: .init(vault: RemoteKeychainVault()), canConfigure: ready)
    }
    #if DEBUG
    /// Isolated UI fixture: real listener restricted to loopback, RAM credentials,
    /// synthetic peer request and real ACTELL1 ACK. Never enabled outside --ui-testing.
    private func runLANPairingUIFixture(ready: @escaping @MainActor () -> Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for _ in 0..<100 where !ready() { try await Task.sleep(for: .milliseconds(100)) }
                try self.store.prepareCompanion(); self.settings = self.store.settings
                let provider = RemoteGeneratedIdentityProvider(namespace: "actell.muse.generated-tls.v1." + self.store.settings.host)
                defer { try? provider.remove() } // This installation/fixture owns its random identity namespace.
                try self.service.start(configuration: .init(enabled: true, port: UInt16.random(in: 20000...40000), allowedSources: [RemoteSourceAddress(literal: "127.0.0.1")!]), identity: self.store.loadIdentity(), keyLookup: { [weak self] id in self?.store.key(for: id) }, directory: FileManager.default.temporaryDirectory.appendingPathComponent("slan-ui-" + UUID().uuidString))
                self.isEnabled = true
                for _ in 0..<300 where self.pairing.windowRemaining == 0 { try await Task.sleep(for: .milliseconds(100)) }
                guard self.pairing.windowRemaining > 0 else { return }
                let request = try JSONSerialization.data(withJSONObject: ["v": 1, "request_id": UUID().uuidString.lowercased(), "device_name": "书桌上的 Muse"])
                _ = self.pairing.handle(path: "/v1/pair/request", body: request, headers: ["content-type": "application/json", "authorization": "Bearer " + String(repeating: "A", count: 43)])
                for _ in 0..<300 where self.store.settings.clients.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                guard let client = self.store.settings.clients.first, let key = self.store.key(for: client.id) else { return }
                let id = UUID().uuidString.lowercased(), nonce = UUID().uuidString.lowercased(), time = String(Int64(Date().timeIntervalSince1970))
                let body = try JSONSerialization.data(withJSONObject: ["v": 1, "client_id": client.id, "request_id": id, "op": "companion.hello", "params": ["device_name": client.name, "protocol": 1]])
                let mac = HMAC<SHA256>.authenticationCode(for: RemoteRequestAuthenticator.signingMessage(clientID: client.id, requestID: id, time: time, nonce: nonce, body: body), using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
                _ = await self.service.handle(body: body, headers: ["x-actell-time": time, "x-actell-nonce": nonce, "x-actell-signature": mac])
            } catch { self.message = "测试配对未完成" }
        }
    }
    #endif
    private func idle() throws {
        guard canConfigure() else { throw RemoteSetupError(String(localized: "Unlock the phone and wait for tasks to finish before changing or starting the Muse connection.")) }
        guard !isActive else { throw RemoteSetupError(String(localized: "Stop the Muse connection before changing its settings or certificate.")) }
    }
    func prepareCompanion() throws {
        try idle(); try store.prepareCompanion(); settings = store.settings
        message = String(localized: "Connection identity ready. Add a device and transfer its pairing details through trusted USB.")
    }
    func configure(host: String, port: String, sources: String) throws {
        try idle(); try store.configure(host: host, port: port, sources: sources)
        settings = store.settings; message = String(localized: "Connection settings saved")
    }
    func importCertificate(url: URL, password: String) throws {
        try idle()
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 32 * 1024 else { throw RemoteSetupError(String(localized: "Choose a certificate file smaller than 32 KiB.")) }
        try store.importIdentity(data: Data(contentsOf: url), password: password)
        settings = store.settings; message = String(localized: "Server certificate saved in this device’s Keychain")
    }
    func removeCertificate() throws {
        try idle(); try store.removeIdentity(); settings = store.settings; message = String(localized: "Server certificate removed")
    }
    func addClient(name: String) throws -> RemoteClientInvitation {
        try idle()
        guard settings.certificate != nil else { throw RemoteSetupError(String(localized: "Configure a server certificate before creating USB pairing details.")) }
        _ = try store.loadIdentity()
        let invitation = try store.addClient(name: name)
        settings = store.settings; message = String(localized: "Client added. Transfer the connection details securely.")
        return invitation
    }
    func authorize(_ client: RemoteClientRegistration, scopes: Set<MuseCompanionScope>, identityConfirmed: Bool,
                   name: String? = nil) throws {
        let displayName = try name.map(RemoteConnectionStore.normalizedDeviceName)
        guard let current = settings.clients.first(where: { $0.id == client.id }) else { throw RemoteSetupError(String(localized: "Device Removed")) }
        let onlyReduces = current.identityConfirmed && identityConfirmed && scopes.isSubset(of: current.scopes)
        guard onlyReduces || canConfigure() else { throw RemoteSetupError(String(localized: "Unlock the phone and wait for the current task to finish before allowing more access.")) }
        // Fence accepted work BEFORE changing scopes. The live store is consulted
        // for every subsequent request; dropping a scope cannot retain old access.
        let permissionsChanged = current.scopes != scopes || current.identityConfirmed != identityConfirmed
        if permissionsChanged { service.revoke(clientID: client.id) }
        do { try store.setAuthorization(clientID: client.id, scopes: scopes, identityConfirmed: identityConfirmed, name: displayName) }
        catch { service.stop(); throw error }
        settings = store.settings
        if permissionsChanged {
            lastAuthenticatedAt.removeValue(forKey: client.id)
            lastAuthenticatedUptime.removeValue(forKey: client.id)
        }
        message = permissionsChanged ? (scopes.isEmpty ? String(localized: "All permissions are off") : String(localized: "Permissions updated. Waiting for the device to reconnect.")) : String(localized: "Device name updated")
    }
    func revoke(_ client: RemoteClientRegistration) throws {
        do { try store.revokeClient(client.id) { [service] id in service.revoke(clientID: id) } }
        catch {
            // A failed credential deletion must never leave an apparently revoked
            // client authenticated against a running listener.
            service.stop()
            throw RemoteSetupError(String(localized: "The device could not be removed. The connection stopped. Unlock the phone and try again."))
        }
        pairing.forget(clientID: client.id)
        lastAuthenticatedAt.removeValue(forKey: client.id)
        lastAuthenticatedUptime.removeValue(forKey: client.id)
        settings = store.settings; message = String(localized: "Revoked \(client.name)")
    }
    func start() throws {
        // The switch records user intent, independently of listener/identity admission.
        // Failed startup must not silently turn the saved choice back off.
        isEnabled = true
        store.setServiceEnabled(true)
        service.recordPreference("service.preference.enabled", enabled: true)
        do { try startListener() }
        catch {
            connectionIssue = error.localizedDescription
            service.recordPreference("service.start.rejected", enabled: true, error: error)
            throw error
        }
    }
    private func startListener() throws {
        try idle()
        guard store.loadError == nil else { throw RemoteSetupError(store.loadError!) }
        if settings.clients.isEmpty, !settings.usesCompanionLAN, settings.certificate == nil, settings.host.isEmpty {
            try store.prepareCompanion(); settings = store.settings
        }
        if !settings.usesCompanionLAN {
            _ = try RemoteConnectionSettings.validate(host: settings.host, port: String(settings.port), sources: settings.sources.joined(separator: "\n"))
        }
        guard settings.usesCompanionLAN || settings.clients.contains(where: { store.key(for: $0.id)?.count == 32 }) else { throw RemoteSetupError(String(localized: "Add a valid client first.")) }
        connectionIssue = nil; stoppingByUser = false
        let identity = try store.loadIdentity()
        let sources = Set(settings.sources.compactMap { RemoteSourceAddress(literal: $0) })
        do { try service.start(configuration: .init(enabled: true, port: settings.port, allowedSources: sources, advertiseCompanion: settings.usesCompanionLAN, allowCompanionLAN: settings.usesCompanionLAN, companionIdentityFingerprint: settings.certificate?.fingerprint, companionHost: settings.host), identity: identity,
                          keyLookup: { [weak self] id in
                              guard let self, self.isActive else { return nil }
                              self.pairing.tick()
                              guard self.isActive else { return nil }
                              return self.store.key(for: id)
                          }, directory: journalDirectory) }
        catch let error as RemoteRPCError {
            switch error.code {
            case "not_foreground": throw RemoteSetupError(String(localized: "Unlock the phone and open Actell to start the connection."))
            case "busy": throw RemoteSetupError(String(localized: "The previous task is still stopping. Try again shortly."))
            default: throw RemoteSetupError(String(localized: "Remote task records are unavailable. The service did not start. Check local storage."))
            }
        }
        pairingTimer?.cancel()
        pairingTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.pairing.tick()
            }
        }
        message = nil
    }
    func openPairingWindow() throws {
        guard canConfigure(), service.isListening, settings.usesCompanionLAN else { throw RemoteSetupError(String(localized: "Turn on Muse Gadget Service and keep Actell open.")) }
        try pairing.openWindow()
    }
    func cancelPairing() { pairing.cancelCurrent() }
    func approvePairing() throws {
        guard canConfigure(), service.isListening else { throw RemoteSetupError(String(localized: "Unlock the phone and keep Actell open.")) }
        _ = try store.loadIdentity() // Never hand out credentials if the prepared identity was lost.
        try pairing.approve()
    }
    func stop() {
        isEnabled = false; resumeRequested = false
        cancelRecovery(); recoveryAttempt = 0
        store.setServiceEnabled(false)
        service.recordPreference("service.preference.disabled", enabled: false)
        stoppingByUser = true; connectionIssue = nil
        pairing.stop(); service.stop(); message = String(localized: "Muse connection stopped")
    }
    /// Restore the saved user choice only when the unlocked foreground is idle.
    /// Restoring a listener never opens pairing or resumes cancelled runs.
    func setScene(active: Bool, background: Bool) {
        foregroundActive = active
        if !active { resumeRequested = false; cancelRecovery(); recoveryAttempt = 0 }
        service.setBackground(background)
        // Pairing still requires a local foreground flow; established peers keep
        // their listener and authenticated presence across ordinary scene changes.
        if background { pairing.setAvailable(false) }
        else if active, service.isListening { pairing.setAvailable(true) }
        if active { resumeIfEnabled() }
    }
    func resumeIfEnabled() {
        guard isEnabled, foregroundActive, status == .stopped || status == .stopping else { return }
        cancelRecovery()
        resumeRequested = true
        restoreIfNeeded()
    }
    private func restoreIfNeeded() {
        guard resumeRequested, isEnabled, foregroundActive, status == .stopped, canConfigure() else { return }
        resumeRequested = false
        do { try start() }
        catch {
            connectionIssue = error.localizedDescription
            if error is NWError { scheduleRecovery() }
        }
    }
    private func cancelRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil
    }
    private func scheduleRecovery() {
        guard recoveryTask == nil, isEnabled, foregroundActive, status == .stopped else { return }
        let delay = recoveryDelay(recoveryAttempt)
        recoveryAttempt = min(recoveryAttempt + 1, 5)
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            self.resumeRequested = true
            // If locked or busy, the existing unlock/idle event resumes this request.
            // Only restore the listener: never reopen pairing or replay a remote run.
            self.restoreIfNeeded()
        }
    }
}
