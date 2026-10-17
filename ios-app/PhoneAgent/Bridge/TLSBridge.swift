import Foundation
import Network
import Security

// Experimental app channel, separate from lockdown certificates/pair records.
// PSK authentication follows Apple's Network.framework TLS-PSK API. No
// verification callback returning true, cleartext fallback, or automatic retry.
actor TLSBridge: DeviceBridge {
    nonisolated private let cancellation = BridgeTransportCancellation()
    nonisolated func cancelTransport() { cancellation.cancel() }
    private var listener: NWListener?
    private var listenerID = UUID()
    private var peer: FramedConnection?
    private var sessionID = ""
    private var capabilities = Set<String>()
    private var imageLimit = Wire.maxImageBytes
    private var busy = false
    private var isReady = false
    private var lastImageID: String?
    private let state: @Sendable (String) -> Void
    init(state: @escaping @Sendable (String) -> Void) { self.state = state }

    func listen(pskHex: String) throws {
        try Task.checkCancellation()
        guard listener == nil else { return }
        cancellation.reset()
        guard pskHex.count == 64, pskHex.allSatisfy({ $0.isHexDigit }) else {
            throw AppError.invalid(String(localized: "The bridge PSK must be a random 32-byte key from a trusted source (64 hexadecimal characters)"))
        }
        let chars = Array(pskHex)
        let data = Data(stride(from: 0, to: 64, by: 2).compactMap { UInt8(String(chars[$0...$0+1]), radix: 16) })
        guard data.count == 32 else { throw AppError.invalid(String(localized: "Invalid bridge key format")) }
        let tls = NWProtocolTLS.Options()
        let key = data.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("PhoneAgent-Bridge-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options(); tcp.enableKeepalive = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let server = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Wire.port)!)
        cancellation.register { server.cancel() }
        listener = server; listenerID = UUID()
        let generation = listenerID
        server.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection, listenerGeneration: generation) }
        }
        server.stateUpdateHandler = { [weak self] status in
            if case .failed = status { Task { await self?.listenerFailed(generation: generation) } }
        }
        server.start(queue: .global(qos: .userInitiated))
        state(String(localized: "Listening for a TLS-PSK bridge connection. Firmware v0.3 does not support this connection yet."))
    }
    private func listenerFailed(generation: UUID) async {
        guard generation == listenerID else { return }
        await stop(); state(String(localized: "Could not listen. Check the port and network permissions."))
    }
    private func accept(_ connection: NWConnection, listenerGeneration: UUID) async {
        guard !cancellation.isCancelled, listenerGeneration == listenerID, peer == nil, listener != nil else { connection.cancel(); return }
        sessionID = UUID().uuidString
        let session = sessionID
        let transport = FramedConnection(connection, onDisconnect: { [weak self] in
            Task { await self?.peerClosed(session: session) }
        })
        cancellation.register { transport.cancel() }
        peer = transport; isReady = false
        do {
            try await transport.start()
            let id = UUID().uuidString
            try await transport.write(Envelope(session: session, request: id, type: "hello", payload: [
                "profile": .string("tls12-psk-aes128gcm-v1"), "max_frame_bytes": .int(Wire.maxFrameBytes),
                "max_image_bytes": .int(Wire.maxImageBytes), "max_chunk_bytes": .int(Wire.maxChunkBytes)
            ]))
            let reply = try await transport.read()
            guard reply.version == 1, reply.session_id == session, reply.request_id == id,
                  reply.type == "hello_ack", reply.payload["backend_ready"]?.bool == true,
                  reply.payload["profile"]?.string == "tls12-psk-aes128gcm-v1",
                  let list = reply.payload["capabilities"]?.array,
                  let limits = reply.payload["limits"]?.object,
                  let imageBytes = limits["max_image_bytes"]?.int, imageBytes > 0, imageBytes <= Wire.maxImageBytes,
                  limits["max_frame_bytes"]?.int == Wire.maxFrameBytes,
                  limits["max_chunk_bytes"]?.int == Wire.maxChunkBytes else {
                throw AppError.protocolViolation(String(localized: "The bridge is not ready, or its protocol, capabilities, or limits do not match"))
            }
            guard sessionID == session, peer === transport else { throw AppError.stopped }
            capabilities = Set(list.compactMap(\.string)); imageLimit = imageBytes
            guard capabilities.contains("screenshot") else { throw AppError.unavailable(String(localized: "The bridge does not support screenshots yet")) }
            isReady = true; state(String(localized: "TLS authenticated and the bridge reports ready. A screenshot and device verification are still needed."))
        } catch {
            transport.cancel()
            if peer === transport { peer = nil; isReady = false; state(String(localized: "The handshake failed or the bridge is not ready. Device tools remain disabled.")) }
        }
    }
    private func peerClosed(session: String) {
        guard session == sessionID else { return }
        isReady = false; peer = nil; capabilities.removeAll(); lastImageID = nil
        state(String(localized: "The bridge disconnected. Reconnect and get a new screenshot. Previous actions will not be resent."))
    }
    // This channel carries remote ESP PNGs, not UIKit/ReplayKit screenshots.
    // Firmware v0.3 does not implement this App channel. Keep background device
    // tools disabled until remote capture/privacy and session behavior are verified.
    func supportsBackgroundExecution(tool: String) async -> Bool { false }
    func approvalContext(imageID: String) throws -> String {
        guard !cancellation.isCancelled, isReady, peer != nil else { throw AppError.unavailable(String(localized: "The device disconnected. Reconnect and get a new screenshot.")) }
        try requireCurrent(imageID)
        return sessionID
    }
    func screenshot() async throws -> FrameImage {
        let result = try await request("screenshot", arguments: [:])
        guard let image = result.image else { throw AppError.protocolViolation(String(localized: "Screenshot response missing")) }
        lastImageID = image.id; return image
    }
    func tap(x: Int, y: Int, imageID: String) async throws {
        // Legacy Host wire compatibility only; the App supplies this identifier.
        // It is not a model tool parameter and is not used on USB NCM/HID.
        try requireCurrent(imageID)
        _ = try await request("tap", arguments: ["x": .int(x), "y": .int(y), "based_on_image_id": .string(imageID)])
        lastImageID = nil
    }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {
        try requireCurrent(imageID)
        _ = try await request("drag", arguments: ["from_x": .int(fromX), "from_y": .int(fromY), "to_x": .int(toX), "to_y": .int(toY), "duration_ms": .int(durationMS), "based_on_image_id": .string(imageID)])
        lastImageID = nil
    }
    private func requireCurrent(_ imageID: String) throws {
        guard imageID == lastImageID else { throw AppError.invalid(String(localized: "This action needs a new screenshot. A previous screenshot cannot be reused.")) }
    }
    private struct Response: Sendable { let image: FrameImage? }
    private func request(_ name: String, arguments: [String: JSONValue]) async throws -> Response {
        try Task.checkCancellation()
        guard isReady, let transport = peer, capabilities.contains(name) else { throw AppError.unavailable(String(localized: "The bridge is disconnected, unauthenticated, not ready, or does not support this tool")) }
        guard !busy else { throw AppError.unavailable(String(localized: "An action is already in progress")) }
        busy = true; defer { busy = false }
        let session = sessionID, id = UUID().uuidString
        let imageCap = imageLimit
        do {
            try await transport.write(Envelope(session: session, request: id, type: "tool_request", payload: ["name": .string(name), "arguments": .object(arguments)]))
            // Every operation has both an absolute 30s limit and per-I/O limits.
            return try await withThrowingTaskGroup(of: Response.self) { group in
                group.addTask {
                    var acknowledged = false, assembler = ImageAssembler()
                    while true {
                        try Task.checkCancellation()
                        let frame = try await transport.read()
                        guard frame.version == 1, frame.session_id == session, frame.request_id == id else { throw AppError.protocolViolation(String(localized: "Session or request ID mismatch")) }
                        if frame.type == "tool_ack" {
                            guard !acknowledged, frame.payload["accepted"]?.bool == true else { throw AppError.protocolViolation(String(localized: "Duplicate or invalid acknowledgment")) }
                            acknowledged = true; continue
                        }
                        guard acknowledged else { throw AppError.protocolViolation(String(localized: "Received a response for an unacknowledged request")) }
                        switch frame.type {
                        case "image_begin": guard name == "screenshot" else { throw AppError.protocolViolation(String(localized: "Received an image for a non-screenshot request")) }; try assembler.begin(frame.payload, limit: imageCap)
                        case "image_chunk": try assembler.chunk(frame.payload)
                        case "image_end": try assembler.end(frame.payload)
                        case "tool_result":
                            guard frame.payload["status"]?.string == "ok" else { throw AppError.unavailable(String(localized: "The bridge reported a tool failure and disconnected. Check the bridge.")) }
                            if name == "screenshot" {
                                guard let imageID = frame.payload["image_id"]?.string else { throw AppError.protocolViolation(String(localized: "Screenshot result is missing an ID")) }
                                return Response(image: try assembler.committed(imageID: imageID))
                            }
                            return Response(image: nil)
                        default: throw AppError.protocolViolation(String(localized: "Unrecognized protocol message"))
                        }
                    }
                }
                group.addTask { try await Task.sleep(nanoseconds: 30_000_000_000); transport.cancel(); throw AppError.timeout }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw AppError.stopped }
                return response
            }
        } catch {
            transport.cancel()
            if peer === transport { isReady = false; peer = nil; lastImageID = nil }
            state(String(localized: "Disconnected. Previous actions were not resent. Reconnect and get a new screenshot."))
            if name != "screenshot" { throw AppError.unknownOutcome }
            throw error
        }
    }
    func stop() async {
        cancelTransport()
        isReady = false; lastImageID = nil; capabilities.removeAll(); sessionID = UUID().uuidString
        listenerID = UUID()
        peer?.cancel(); peer = nil; listener?.cancel(); listener = nil
        state(String(localized: "The bridge stopped. Sent actions may have taken effect. Check your device before continuing."))
    }
}

// All reads/writes belong to a single serialized bridge operation. NWConnection
// handles byte-stream segmentation; reads never assume one TCP packet = frame.
final class FramedConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PhoneAgent.Bridge.Connection")
    private let onDisconnect: @Sendable () -> Void
    init(_ connection: NWConnection, onDisconnect: @escaping @Sendable () -> Void) {
        self.connection = connection; self.onDisconnect = onDisconnect
    }
    func cancel() { connection.cancel() }
    func start() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = OnceContinuation(continuation)
                connection.stateUpdateHandler = { [onDisconnect] state in
                    switch state {
                    case .ready: gate.finish(.success(Void()))
                    case .failed: gate.finish(.failure(AppError.unavailable(String(localized: "TLS authentication or connection failed")))); onDisconnect()
                    case .cancelled: gate.finish(.failure(AppError.stopped)); onDisconnect()
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) { [connection] in
                    if gate.finish(.failure(AppError.timeout)) { connection.cancel() }
                }
            }
        }, onCancel: { self.cancel() })
    }
    func write(_ envelope: Envelope) async throws {
        try Task.checkCancellation()
        let bytes = try Wire.encode(envelope)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let gate = OnceContinuation(c)
                connection.send(content: bytes, completion: .contentProcessed { error in
                    gate.finish(error == nil ? .success(Void()) : .failure(AppError.unavailable(String(localized: "Could not write to the bridge"))))
                })
                queue.asyncAfter(deadline: .now() + 10) { [connection] in
                    if gate.finish(.failure(AppError.timeout)) { connection.cancel() }
                }
            }
        }, onCancel: { self.cancel() })
    }
    func read() async throws -> Envelope {
        let header = try await exact(4)
        let body = try await exact(Wire.length(header))
        return try JSONDecoder().decode(Envelope.self, from: body)
    }
    private func exact(_ count: Int) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                let gate = OnceContinuation(c)
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                    if error == nil, let data, data.count == count { gate.finish(.success(data)) }
                    else { gate.finish(.failure(AppError.unavailable(complete ? String(localized: "Bridge disconnected") : String(localized: "Could not read from the bridge")))) }
                }
                queue.asyncAfter(deadline: .now() + 10) { [connection] in
                    if gate.finish(.failure(AppError.timeout)) { connection.cancel() }
                }
            }
        }, onCancel: { self.cancel() })
    }
}
private final class OnceContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result); return c != nil
    }
}

/// Allows expiration/user Stop to close sockets synchronously before the OS
/// lease is completed, without waiting for an actor currently reading a frame.
private final class BridgeTransportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = true
    private var closures: [@Sendable () -> Void] = []
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func reset() { lock.lock(); cancelled = false; closures = []; lock.unlock() }
    func register(_ close: @escaping @Sendable () -> Void) {
        lock.lock()
        let closeNow = cancelled
        if !closeNow { closures.append(close) }
        lock.unlock()
        if closeNow { close() }
    }
    func cancel() {
        lock.lock(); cancelled = true
        let pending = closures; closures = []
        lock.unlock()
        for close in pending { close() }
    }
}
