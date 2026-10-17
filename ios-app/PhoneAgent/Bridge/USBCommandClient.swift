import Foundation
import Network
import OSLog
import Darwin

/// Bounded, process-local diagnostics. Callers record protocol metadata only:
/// never command arguments, received payloads, screenshots, goals, or secrets.
final class USBDiagnosticsLog: @unchecked Sendable {
    static let revision = "usb-diag-pa3-input-4"
    private let lock = NSLock()
    private let capacity: Int
    private let console: Bool
    private let logger = Logger(subsystem: "com.ja1chen.PhoneAgent", category: "USBNetwork")
    private let formatter: ISO8601DateFormatter
    private let started = ProcessInfo.processInfo.systemUptime
    private let header: String
    private var rows: [String] = []
    private var sequence = 0
    private var dropped = 0

    init(capacity: Int = 600, console: Bool = true) {
        self.capacity = max(1, capacity); self.console = console
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let bundle = Bundle.main
        func value(_ key: String) -> String { bundle.object(forInfoDictionaryKey: key) as? String ?? "unknown" }
        let purpose = value("NSLocalNetworkUsageDescription")
        #if targetEnvironment(simulator)
        let runtime = "simulator (local-network privacy cannot be validated here)"
        #else
        let runtime = "device"
        #endif
        header = """
        PhoneAgent USB Diagnostics v1
        revision=\(Self.revision)
        imageExpiry=disabled modelImageIDParameter=false inputSceneGate=disabled inputImageMatch=disabled
        finishRequired=false
        bundle=\(bundle.bundleIdentifier ?? "unknown") version=\(value("CFBundleShortVersionString")) build=\(value("CFBundleVersion"))
        OS=\(ProcessInfo.processInfo.operatingSystemVersionString) runtime=\(runtime)
        SDK=\(value("DTSDKName")) XcodeBuild=\(value("DTXcodeBuild"))
        localNetworkUsageDescriptionPresent=\(!purpose.isEmpty && purpose != "unknown") (not permission status)
        target=192.168.7.1:28766 expectedPhone=192.168.7.2/24 binding=explicitInterfaceFromLocalIPv4 peerToPeer=false protocol=PA3 noPSK
        Times are UTC plus monotonic elapsed seconds. Copy buffer is process-local; events also appear in OSLog category USBNetwork.
        Interface inventory shows USB-subnet/link-local IPv4; other IPs are redacted. No MAC/SSID/IPv6 or command/screen/model payloads.
        Default/wired path monitors describe system paths, not proof of USB TCP reachability.
        """
    }
    func record(_ message: String, attempt: UUID? = nil) {
        let line = lock.withLock {
            sequence += 1
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            let id = attempt.map { String($0.uuidString.prefix(8)) } ?? "app"
            // Prevent multiline/error text from impersonating another log event.
            let clean = String(message.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(1600))
            let line = "\(formatter.string(from: Date())) +\(elapsed)s #\(sequence) [\(id)] \(clean)"
            rows.append(line)
            if rows.count > capacity { dropped += rows.count - capacity; rows.removeFirst(rows.count - capacity) }
            return line
        }
        if console { logger.notice("\(line, privacy: .public)") }
    }
    func report() -> String {
        lock.withLock {
            "\(header)\nexported=\(formatter.string(from: Date())) retained=\(rows.count) dropped=\(dropped)\n\n" + rows.joined(separator: "\n") + "\n"
        }
    }
    static func commandKind(_ body: String) -> String {
        if body == "PING" { return body }
        if body.hasPrefix("STOP ") { return "STOP" }
        if body.hasPrefix("TAP ") { return "TAP" }
        if body.hasPrefix("DRAG ") { return "DRAG" }
        return "OTHER"
    }
    static func visibleIPv4(_ address: String) -> String {
        if address.hasPrefix("192.168.7.") || address.hasPrefix("169.254.") { return address }
        return "<non-USB IPv4 redacted>"
    }
    func recordInterfaces(reason: String, attempt: UUID? = nil) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            record("interfaces reason=\(reason) getifaddrs_errno=\(errno)", attempt: attempt); return
        }
        defer { freeifaddrs(head) }
        var inventory: [String: (flags: UInt32, addresses: [String])] = [:]
        var cursor = head
        func address(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
            guard let pointer, pointer.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointer, socklen_t(pointer.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let row = item.pointee, name = String(cString: row.ifa_name)
            guard row.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var entry = inventory[name] ?? (row.ifa_flags, [])
            if let ip = address(row.ifa_addr) {
                let visible = Self.visibleIPv4(ip)
                let mask = visible == ip ? " mask=\(address(row.ifa_netmask) ?? "unknown")" : ""
                entry.addresses.append("\(visible)\(mask)")
            }
            inventory[name] = entry
        }
        record("interfaces reason=\(reason) count=\(inventory.count)", attempt: attempt)
        for name in inventory.keys.sorted() {
            guard let entry = inventory[name] else { continue }
            record("interface name=\(name) up=\(entry.flags & UInt32(IFF_UP) != 0) running=\(entry.flags & UInt32(IFF_RUNNING) != 0) broadcast=\(entry.flags & UInt32(IFF_BROADCAST) != 0) pointToPoint=\(entry.flags & UInt32(IFF_POINTOPOINT) != 0) ipv4=\(entry.addresses.isEmpty ? "none" : entry.addresses.joined(separator: ","))", attempt: attempt)
        }
    }
}

/// Resolve the configured local IPv4 to one concrete Ethernet-like interface.
/// NWPathMonitor's default-route inventory can omit a local-only USB service.
/// Never fall back to an unbound connection, a hostname, or another transport.
struct USBInterfaceBinding {
    static let localIP = "192.168.7.2"
    static let remoteIP = "192.168.7.1"
    static let netmask = "255.255.255.0"
    struct Row: Equatable {
        let name: String
        let index: UInt32
        let address: String
        let mask: String
        let flags: UInt32
        let linkType: UInt8?
    }
    let row: Row
    let interface: NWInterface
    let localAddress: IPv4Address
    let remoteAddress: IPv4Address

    static func select(_ rows: [Row]) throws -> Row {
        let matches = rows.filter { $0.address == localIP }
        guard matches.count == 1, let row = matches.first else {
            throw AppError.unavailable(matches.isEmpty ? String(localized: "No interface is configured with 192.168.7.2. Check the USB Ethernet static IP.") : String(localized: "More than one interface uses 192.168.7.2. The USB interface cannot be selected safely."))
        }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let forbidden = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        guard row.index > 0, row.mask == netmask, row.flags & required == required,
              row.flags & forbidden == 0, row.linkType == UInt8(IFT_ETHER) else {
            throw AppError.unavailable(String(localized: "Interface \(row.name) does not meet the USB Ethernet requirements (up, running, broadcast, /24, Ethernet, and not a tunnel)"))
        }
        return row
    }
    static func validateType(_ type: NWInterface.InterfaceType) throws {
        switch type {
        case .wiredEthernet, .other: break // .other additionally requires IFT_ETHER and no POINTOPOINT above.
        default: throw AppError.unavailable(String(localized: "The static IP belongs to a \(type) interface and cannot be used for USB communication"))
        }
    }
    static func resolve(_ rows: [Row]) throws -> USBInterfaceBinding {
        let row = try select(rows)
        // This public parser returns the NWInterface for the explicit scope.
        // Validate the result; unsupported/stale scopes fail instead of unbinding.
        guard let remote = IPv4Address("\(remoteIP)%\(row.name)"),
              let local = IPv4Address("\(localIP)%\(row.name)"),
              let interface = remote.interface, local.interface == interface,
              interface.name == row.name, interface.index == Int(row.index) else {
            throw AppError.unavailable(String(localized: "Interface \(row.name) could not be resolved or has changed. Reconnect USB and try again manually."))
        }
        try validateType(interface.type)
        return USBInterfaceBinding(row: row, interface: interface, localAddress: local, remoteAddress: remote)
    }
    func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localAddress), port: .any)
        parameters.includePeerToPeer = false
        return parameters
    }
    static func inventory() throws -> [Row] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw AppError.unavailable(String(localized: "Could not read the interface list. Error: \(errno)")) }
        defer { freeifaddrs(head) }
        var entries: [(String, String, String, UInt32)] = []
        var linkTypes: [String: UInt8] = [:]
        var cursor = head
        func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
            guard let pointer, pointer.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointer, socklen_t(pointer.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee, name = String(cString: value.ifa_name)
            if let address = ipv4(value.ifa_addr) {
                entries.append((name, address, ipv4(value.ifa_netmask) ?? "unknown", value.ifa_flags))
            }
            if let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) {
                // Read the link type only, never link-layer addresses (MACs).
                linkTypes[name] = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee.sdl_type
            }
        }
        return entries.map { name, address, mask, flags in
            Row(name: name, index: if_nametoindex(name), address: address, mask: mask, flags: flags, linkType: linkTypes[name])
        }
    }
}

enum USBConnectionStatus: Equatable {
    case idle, connecting, waiting(String), awaitingGreeting, checking, ready(hid: Bool), failed(String), disconnected(String)
    var isConnecting: Bool {
        switch self {
        case .connecting, .waiting, .awaitingGreeting, .checking: return true
        default: return false
        }
    }
    // A system permission sheet can make the scene inactive. Only initial
    // connection/PING setup may continue there; background still cancels it.
    func allowsSetup(in scene: ScreenUSBExecutionContext.Scene) -> Bool {
        scene == .active || (scene == .inactive && isConnecting)
    }
    var isReady: Bool { if case .ready = self { return true }; return false }
    var isDisconnected: Bool { if case .disconnected = self { return true }; return false }
    var isFailure: Bool { if case .failed = self { return true }; return false }
    var diagnosticState: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .waiting: return "waiting"
        case .awaitingGreeting: return "awaitingGreeting"
        case .checking: return "checking"
        case .ready(let hid): return hid ? "readyHID" : "readyNCM"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        }
    }
    var unavailableInputMessage: String {
        let prefix: String
        switch self {
        case .disconnected: prefix = String(localized: "USB disconnected. Only screen capture is available for this run.")
        case .failed: prefix = String(localized: "USB connection failed. Only screen capture is available for this run.")
        default: prefix = String(localized: "USB HID was unavailable when this run started. Only screen capture is available.")
        }
        return String(localized: "\(prefix) Before tapping or dragging, reconnect USB NCM in the control settings, confirm that NCM + HID is connected, then start a new task.")
    }
    var message: String {
        switch self {
        case .idle: return String(localized: "USB not connected")
        case .connecting: return String(localized: "Connecting to USB device 192.168.7.1:28766…")
        case .waiting(let reason): return String(localized: "Waiting for the USB network (up to 30 seconds): \(reason)")
        case .awaitingGreeting: return String(localized: "USB TCP connected. Waiting for a PA3 response…")
        case .checking: return String(localized: "Device response received. Verifying two-way PING…")
        case .ready(let hid): return hid ? String(localized: "USB NCM + HID connected without PSK. The connection stays open between tasks. Tapping and dragging are available after starting a task.") : String(localized: "USB NCM two-way PING verified without PSK. HID is disabled in this firmware.")
        case .failed(let message): return String(localized: "USB connection failed: \(message)")
        case .disconnected(let message): return String(localized: "USB disconnected: \(message)")
        }
    }
}

enum USBWire {
    static func transportError(_ error: NWError?, inputInFlight: Bool, path: NWPath? = nil) -> AppError {
        // A connection failure before any input is not an unknown HID result.
        // Preserve unknown-outcome semantics once an input is in flight.
        if inputInFlight { return .unknownOutcome }
        let detail = error.map { String(describing: $0) } ?? String(localized: "Connection closed")
        return .unavailable(String(localized: "\(detail). \(pathDetails(path)) Check USB Ethernet, the static IP, and local network permissions, then connect manually."))
    }
    static func pathDetails(_ path: NWPath?) -> String {
        guard let path else { return String(localized: "The system did not provide network path information for this connection.") }
        let reason: String
        if path.status == .unsatisfied {
            switch path.unsatisfiedReason {
            case .localNetworkDenied: reason = String(localized: "Local network access has not been allowed (localNetworkDenied)")
            case .notAvailable: reason = String(localized: "No path meets the wired connection requirements (notAvailable)")
            case .wifiDenied: reason = String(localized: "The system does not allow the Wi-Fi path (wifiDenied)")
            case .cellularDenied: reason = String(localized: "The system does not allow the cellular path (cellularDenied)")
            case .vpnInactive: reason = String(localized: "The system reports that VPN is inactive (vpnInactive)")
            @unknown default: reason = String(describing: path.unsatisfiedReason)
            }
        } else { reason = String(localized: "No unsatisfied reason") }
        let interfaces = path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", ")
        return String(localized: "Path: \(path.status); reason: \(reason); available interfaces: \(interfaces.isEmpty ? String(localized: "None") : interfaces); IPv4: \(path.supportsIPv4 ? String(localized: "Yes") : String(localized: "No")).")
    }
    static func receiptTimeout(isPing: Bool, inputInFlight: Bool) -> AppError {
        // A PING/STOP timeout also revokes any concurrent input, whose result
        // remains unknown even though the timed-out request was not an input.
        if inputInFlight { return .unknownOutcome }
        return .unavailable(String(localized: "USB \(isPing ? "PING" : "STOP") acknowledgment timed out. Disconnected. Reconnect manually."))
    }
    static func acceptACK(_ phase: String, needsReceipt: Bool, received: inout Bool) throws -> Bool {
        if phase == "received", needsReceipt, !received { received = true; return false }
        if phase == "executed", !needsReceipt || received { return true }
        if phase == "cancelled" { return true }
        throw needsReceipt ? AppError.unknownOutcome : AppError.protocolViolation(String(localized: "USB acknowledgment phase mismatch"))
    }
    // PA3 deliberately has no identity authentication or encryption. Never
    // silently interpret a PA1 challenge/LOCKED response as a usable session.
    static func supportsHID(_ greeting: String) throws -> Bool {
        switch greeting {
        case "PA3 READY 0": return false
        case "PA3 READY 1": return true
        default: throw AppError.protocolViolation(String(localized: "USB protocol mismatch. The app and firmware must both use PA3 without PSK."))
        }
    }
    static func parseACK(_ line: String) throws -> (id: UInt64, phase: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UInt32(parts[0]), id > 0, String(id) == parts[0],
              parts[1] == "received" || parts[1] == "executed" || parts[1] == "cancelled" else {
            throw AppError.protocolViolation(String(localized: "Invalid USB acknowledgment format"))
        }
        return (UInt64(id), String(parts[1]))
    }
}

struct USBInputSession: Equatable, Sendable {
    let connection: UUID
    let generation: UInt32
}

protocol USBCommandTransport: Sendable {
    func command(_ body: String) async throws
    func command(_ body: String, permit: USBInputPermit?) async throws
    func openInputSession() async throws -> USBInputSession
    func stopInputs(_ session: USBInputSession) async
}
extension USBCommandTransport {
    // In-memory test transports have no shared TCP ownership. The production
    // client allocates and checks a connection-scoped input generation.
    func openInputSession() async throws -> USBInputSession {
        USBInputSession(connection: UUID(), generation: 1)
    }
    // Test transports can use this default. The production client overrides it
    // to consume the permit at NWConnection.send, after its actor hop.
    func command(_ body: String, permit: USBInputPermit?) async throws {
        try permit?.enqueue({})
        try await command(body)
    }
}

// Dedicated Ethernet connection only. No default-route/VPN changes, HTTP redirects,
// DNS discovery, automatic reconnect, or automatic replay of input.
protocol USBConnectionSession: USBCommandTransport {
    var health: USBTransportHealth { get }
    var supportsHID: Bool { get async }
    func connect(attempt: UUID) async throws
    func disconnect() async
}

actor USBCommandClient: USBConnectionSession {
    nonisolated let health = USBTransportHealth()
    private var keepalive: Task<Void, Never>?
    private var connection: NWConnection?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "phoneagent.usb.transport")
    private var incoming = Data()
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var ready = false
    private var tcpReady = false
    private var lastWaitingError: NWError?
    private var lastPath: NWPath?
    private var pathMonitors: [NWPathMonitor] = []
    private var receivedBytes = 0
    private var receivedLines = 0
    private var pingReplies = 0
    private let diagnostics: USBDiagnosticsLog
    private let onProgress: @Sendable (USBConnectionStatus) -> Void
    private(set) var supportsHID = false
    private var nextID: UInt64 = 0
    private var inputGeneration: UInt32 = 1
    private var inputSession: USBInputSession?
    private var releasing: (session: USBInputSession, task: Task<Void, Never>)?
    private let makeConnection: @Sendable (USBDiagnosticsLog, UUID) throws -> NWConnection
    private struct Pending {
        var continuation: CheckedContinuation<Void, Error>?
        var received = false
        let needsReceipt: Bool
        let isPing: Bool
        let kind: String
        let logDetails: Bool
        let sentAt: TimeInterval
        let inputSession: USBInputSession?
    }
    private var pending: [UInt64: Pending] = [:]

    init(diagnostics: USBDiagnosticsLog = USBDiagnosticsLog(), onProgress: @escaping @Sendable (USBConnectionStatus) -> Void = { _ in },
         makeConnection: @escaping @Sendable (USBDiagnosticsLog, UUID) throws -> NWConnection = { try USBCommandClient.ethernetConnection($0, $1) }) {
        self.diagnostics = diagnostics; self.onProgress = onProgress; self.makeConnection = makeConnection
    }

    static func ethernetConnection(_ diagnostics: USBDiagnosticsLog, _ token: UUID) throws -> NWConnection {
        let binding: USBInterfaceBinding
        do {
            let rows = try USBInterfaceBinding.inventory()
            for row in rows where row.address == USBInterfaceBinding.localIP {
                diagnostics.record("binding.candidate name=\(row.name) index=\(row.index) mask=\(row.mask) flags=\(row.flags) linkType=\(row.linkType.map { String($0) } ?? "unknown")", attempt: token)
            }
            binding = try USBInterfaceBinding.resolve(rows)
        } catch {
            diagnostics.record("binding.rejected reason=\(error.localizedDescription)", attempt: token)
            throw error
        }
        let parameters = binding.parameters()
        diagnostics.record("binding.selected name=\(binding.interface.name) index=\(binding.interface.index) networkType=\(binding.interface.type) local=\(binding.localAddress) remote=\(binding.remoteAddress) requiredInterface=true; no unbound fallback", attempt: token)
        return NWConnection(host: .ipv4(binding.remoteAddress), port: 28766, using: parameters)
    }

    func connect(attempt: UUID = UUID()) async throws {
        fail(.stopped, publish: false)
        let token = attempt; generation = token
        health.begin(token)
        diagnostics.record("connect.begin target=192.168.7.1:28766 binding=explicitInterface setupDeadline=30s greetingDeadline=3s", attempt: token)
        diagnostics.recordInterfaces(reason: "connect", attempt: token)
        let c: NWConnection
        do { c = try makeConnection(diagnostics, token) }
        catch { fail((error as? AppError) ?? .unavailable(String(localized: "Could not bind the USB interface"))); throw error }
        startPathMonitors(token)
        connection = c
        c.pathUpdateHandler = { [weak self] path in
            Task { await self?.pathChanged(path, source: "connection", token: token) }
        }
        c.viabilityUpdateHandler = { [diagnostics] viable in
            diagnostics.record("connection.viability=\(viable)", attempt: token)
        }
        c.betterPathUpdateHandler = { [diagnostics] available in
            diagnostics.record("connection.betterPath=\(available) (no automatic reconnect)", attempt: token)
        }
        c.stateUpdateHandler = { [weak self, health, diagnostics] state in
            switch state {
            case .failed, .waiting, .cancelled: health.invalidate(token)
            default: break
            }
            diagnostics.record("connection.state=\(state)", attempt: token)
            // currentPath can lack an endpoint handler during setup/teardown.
            // Consume pathUpdateHandler snapshots instead of querying here.
            Task { await self?.stateChanged(state, token: token) }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectWaiter = continuation
                c.start(queue: queue)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    await self?.expireSetup(token)
                }
            }
        } onCancel: { Task { await self.cancelSetup(token) } }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.command("PING"); try await Task.sleep(nanoseconds: 200_000_000) }
                catch { return }
            }
        }
    }
    private func startPathMonitors(_ token: UUID) {
        for (source, monitor) in [("system.default", NWPathMonitor()), ("system.wired", NWPathMonitor(requiredInterfaceType: .wiredEthernet))] {
            monitor.pathUpdateHandler = { [weak self] path in
                Task { await self?.pathChanged(path, source: source, token: token) }
            }
            pathMonitors.append(monitor); monitor.start(queue: queue)
        }
    }
    private func pathChanged(_ path: NWPath, source: String, token: UUID) {
        guard generation == token else { return }
        diagnostics.record("path source=\(source) \(USBWire.pathDetails(path))", attempt: token)
        if source == "connection" {
            lastPath = path
            if let error = lastWaitingError, !tcpReady {
                onProgress(.waiting("\(error)。\(USBWire.pathDetails(path))"))
            }
        }
    }
    private func stateChanged(_ state: NWConnection.State, token: UUID) {
        guard generation == token else { return }
        switch state {
        case .waiting(let error):
            if !tcpReady, !ready, pending.isEmpty {
                // First-use local network permission may put NWConnection in
                // waiting before the user answers. There are no commands yet.
                // Once TCP has connected, any later waiting state is fatal.
                lastWaitingError = error
                diagnostics.record("connect.waiting tcpReady=false error=\(error); cachedConnectionPath=\(USBWire.pathDetails(lastPath))", attempt: token)
                onProgress(.waiting("\(error)。\(USBWire.pathDetails(lastPath))"))
            } else { transportFailed(token, error: error) }
        case .ready:
            guard !tcpReady else { return }
            tcpReady = true; lastWaitingError = nil
            diagnostics.record("tcp.ready; PA3 greeting deadline started", attempt: token)
            onProgress(.awaitingGreeting)
            receive(token)
            timeout(token, id: nil, seconds: 3)
        case .failed(let error): transportFailed(token, error: error)
        case .cancelled: transportFailed(token, error: nil)
        default: break
        }
    }
    private func expireSetup(_ token: UUID) {
        guard generation == token, !ready else { return }
        let detail = "\(lastWaitingError.map { String(describing: $0) } ?? "no waiting error"); \(USBWire.pathDetails(lastPath))"
        diagnostics.record("timeout.setup 30s tcpReady=\(tcpReady) greetingReady=\(ready)", attempt: token)
        diagnostics.recordInterfaces(reason: "setup-timeout", attempt: token)
        fail(.unavailable(String(localized: "USB connection timed out after 30 seconds. \(detail) Allow local network access if prompted, then try again manually. Otherwise, keep these network diagnostics.")))
    }
    func openInputSession() async throws -> USBInputSession {
        if let release = releasing {
            await release.task.value
            if releasing?.session == release.session { releasing = nil }
        }
        try Task.checkCancellation()
        guard ready, supportsHID else { throw AppError.unavailable(String(localized: "USB HID not connected")) }
        guard inputSession == nil else { throw AppError.unavailable(String(localized: "Input from the previous USB run has not been released")) }
        let session = USBInputSession(connection: generation, generation: inputGeneration)
        inputSession = session
        diagnostics.record("input.session.begin epoch=\(session.generation)", attempt: generation)
        return session
    }
    func command(_ body: String) async throws { try await command(body, permit: nil) }
    func command(_ body: String, permit: USBInputPermit?) async throws {
        let isInput = body.hasPrefix("TAP ") || body.hasPrefix("DRAG ")
        if isInput {
            guard supportsHID, let session = permit?.inputSession,
                  session == inputSession, session.connection == generation, releasing == nil else { throw AppError.stopped }
            let parts = body.split(separator: " ", maxSplits: 1)
            try await request("\(parts[0]) \(session.generation) \(parts[1])", permit: permit, session: session)
        } else {
            guard body == "PING" else { throw AppError.invalid(String(localized: "USB control commands must use the connection lifecycle")) }
            try await request(body)
        }
    }
    private func request(_ body: String, permit: USBInputPermit? = nil, session: USBInputSession? = nil) async throws {
        try Task.checkCancellation()
        guard ready, !body.isEmpty, body.utf8.allSatisfy({ (32...126).contains($0) }), body.utf8.count < 128 else { throw AppError.unavailable(String(localized: "USB is not connected or the command format is invalid")) }
        let kind = USBDiagnosticsLog.commandKind(body)
        // Reserve a slot so cancellation can always send the release barrier.
        guard pending.count < (kind == "STOP" ? 9 : 8), nextID < UInt64(UInt32.max) else { throw AppError.unavailable(String(localized: "USB request limit reached")) }
        nextID += 1; let id = nextID, token = generation
        let payload = "\(id) \(body)"
        let logDetails = kind != "PING" || id <= 4 || id % 25 == 0
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    let enqueue = {
                        self.pending[id] = Pending(continuation: continuation, needsReceipt: session != nil, isPing: body == "PING", kind: kind, logDetails: logDetails, sentAt: ProcessInfo.processInfo.systemUptime, inputSession: session)
                        self.send(payload, token, id: id, logDetails: logDetails)
                    }
                    if let permit { try permit.enqueue(enqueue) } else { enqueue() }
                    if logDetails { diagnostics.record("send.enqueued id=\(id) kind=\(kind) bytes=\(payload.utf8.count + 1); arguments omitted", attempt: token) }
                    timeout(token, id: id, seconds: kind == "DRAG" ? 3 : 1)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { Task { await self.cancelRequest(id, token: token) } }
    }
    func stopInputs(_ session: USBInputSession) async {
        if let releasing, releasing.session == session { await releasing.task.value; return }
        guard session == inputSession, session.connection == generation else { return }
        inputSession = nil // Revoke before the first suspension; late sends fail.
        let task = Task { await self.release(session) }
        releasing = (session, task)
        await task.value
        if releasing?.session == session { releasing = nil }
    }
    private func release(_ session: USBInputSession) async {
        diagnostics.record("input.release.begin epoch=\(session.generation)", attempt: session.connection)
        do {
            try await request("STOP \(session.generation)")
            guard generation == session.connection, ready else { return }
            guard session.generation < UInt32.max else { throw AppError.unavailable(String(localized: "USB input identifiers exhausted")) }
            inputGeneration = session.generation + 1
            diagnostics.record("input.release.completed connectionRetained=true nextEpoch=\(inputGeneration)", attempt: generation)
        } catch {
            if generation == session.connection { fail(.unavailable(String(localized: "HID release could not be confirmed. USB was disconnected. Check your device before reconnecting."))) }
        }
    }
    func disconnect() async {
        diagnostics.record("client.disconnect requested tcpReady=\(tcpReady) greetingReady=\(ready)", attempt: generation)
        let token = generation
        if let session = inputSession { await stopInputs(session) }
        else if let releasing { await releasing.task.value }
        if generation == token { fail(.stopped) }
    }
    private func send(_ line: String, _ token: UUID, id: UInt64, logDetails: Bool) {
        connection?.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self, diagnostics] error in
            if error != nil || logDetails { diagnostics.record("send.processed id=\(id) error=\(error.map { String(describing: $0) } ?? "none") (not device ACK)", attempt: token) }
            if let error { Task { await self?.transportFailed(token, error: error) } }
        })
    }
    private func receive(_ token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            Task { await self?.consume(data, closed: complete || error != nil, error: error, token: token) }
        }
    }
    private func consume(_ data: Data?, closed: Bool, error: NWError?, token: UUID) {
        guard generation == token else { return }
        receivedBytes += data?.count ?? 0
        if !ready || closed {
            diagnostics.record("receive bytes=\(data?.count ?? 0) total=\(receivedBytes) closed=\(closed) error=\(error.map { String(describing: $0) } ?? "none"); payload omitted", attempt: token)
        }
        if let data { incoming.append(data) }
        guard incoming.count <= 2048 else { fail(.protocolViolation(String(localized: "USB response is too long"))); return }
        while let newline = incoming.firstIndex(of: 10) {
            let bytes = incoming[..<newline]; incoming.removeSubrange(...newline)
            guard bytes.count <= 256, let line = String(data: bytes, encoding: .ascii) else { fail(.protocolViolation(String(localized: "Invalid USB response format"))); return }
            do { try handle(line, token) } catch { fail((error as? AppError) ?? .unknownOutcome); return }
        }
        if closed { transportFailed(token, error: error) } else if generation == token { receive(token) }
    }
    private func handle(_ line: String, _ token: UUID) throws {
        receivedLines += 1
        if !ready {
            supportsHID = try USBWire.supportsHID(line); ready = true
            diagnostics.record("greeting.valid protocol=PA3 hid=\(supportsHID)", attempt: token)
            connectWaiter?.resume(); connectWaiter = nil; return
        }
        let (id, phase) = try USBWire.parseACK(line)
        guard var request = pending[id] else {
            throw AppError.protocolViolation(String(localized: "USB acknowledgment command ID mismatch"))
        }
        if phase == "cancelled", !request.needsReceipt, request.kind != "STOP" {
            throw AppError.protocolViolation(String(localized: "PING cannot return an input cancellation acknowledgment"))
        }
        if request.logDetails {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - request.sentAt) * 1000)
            diagnostics.record("ack id=\(id) kind=\(request.kind) phase=\(phase) elapsedMs=\(elapsed)", attempt: token)
        }
        if try USBWire.acceptACK(phase, needsReceipt: request.needsReceipt, received: &request.received) {
            if request.isPing { health.receivedPing(token); pingReplies += 1 }
            pending.removeValue(forKey: id)
            if phase == "cancelled" { request.continuation?.resume(throwing: AppError.stopped) }
            else { request.continuation?.resume() }
        } else { pending[id] = request }
    }
    private func timeout(_ token: UUID, id: UInt64?, seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self?.expire(token, id: id)
        }
    }
    private func expire(_ token: UUID, id: UInt64?) {
        guard generation == token else { return }
        if let id, let request = pending[id] {
            diagnostics.record("timeout.receipt id=\(id) kind=\(request.kind) received=\(request.received) inputInFlight=\(pending.values.contains { $0.needsReceipt })", attempt: token)
            fail(USBWire.receiptTimeout(isPing: request.isPing, inputInFlight: pending.values.contains { $0.needsReceipt }))
        } else if id == nil, !ready {
            diagnostics.record("timeout.greeting 3s receivedBytes=\(receivedBytes)", attempt: token)
            fail(.unavailable(String(localized: "TCP connected, but no PA3 response was received from the USB device within 3 seconds. Check the firmware version. \(USBWire.pathDetails(lastPath))")))
        }
    }
    private func transportFailed(_ token: UUID, error: NWError?) {
        if generation == token {
            diagnostics.record("transport.failed error=\(error.map { String(describing: $0) } ?? "closed")", attempt: token)
            fail(USBWire.transportError(error, inputInFlight: pending.values.contains { $0.needsReceipt }, path: lastPath))
        }
    }
    private func cancelSetup(_ token: UUID) { if generation == token, !ready { fail(.stopped) } }
    private func cancelRequest(_ id: UInt64, token: UUID) async {
        guard generation == token, var request = pending[id], let waiter = request.continuation else { return }
        request.continuation = nil; pending[id] = request
        waiter.resume(throwing: CancellationError())
        diagnostics.record("request.cancel id=\(id) kind=\(request.kind) connectionRetained=true awaitingWireReceipt=true", attempt: token)
        // Keep the receipt slot until the peer's terminal ACK, so late ACKs are
        // consumed correctly. Cancelling an input also releases its whole task.
        if let session = request.inputSession { await stopInputs(session) }
    }
    private func fail(_ error: AppError, publish: Bool = true) {
        health.invalidate(); keepalive?.cancel(); keepalive = nil
        if connection != nil {
            diagnostics.record("connection.close reason=\(error.localizedDescription) tcpReady=\(tcpReady) greetingReady=\(ready) sent=\(nextID) receivedBytes=\(receivedBytes) receivedLines=\(receivedLines) pingReplies=\(pingReplies) pending=\(pending.count)", attempt: generation)
            for id in pending.keys.sorted() {
                guard let request = pending[id] else { continue }
                diagnostics.record("pending id=\(id) kind=\(request.kind) received=\(request.received) input=\(request.needsReceipt)", attempt: generation)
            }
        }
        for monitor in pathMonitors { monitor.cancel() }
        pathMonitors.removeAll()
        inputSession = nil; inputGeneration = 1; releasing = nil
        generation = UUID(); ready = false; tcpReady = false; supportsHID = false; lastWaitingError = nil; lastPath = nil
        receivedBytes = 0; receivedLines = 0; pingReplies = 0
        connection?.cancel(); connection = nil; incoming.removeAll(); nextID = 0
        connectWaiter?.resume(throwing: error); connectWaiter = nil
        let waiting = pending; pending.removeAll()
        for request in waiting.values { request.continuation?.resume(throwing: error) }
        if publish { onProgress(error == .stopped ? .disconnected(String(localized: "Connection closed")) : .failed(error.localizedDescription)) }
    }
}
