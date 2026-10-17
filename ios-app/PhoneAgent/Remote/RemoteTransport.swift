import Foundation
import Network
import Security

/// Exact numeric peer addresses. No DNS names, CIDR expansion, wildcard, proxy
/// headers, or claimed client address are accepted as source authorization.
struct RemoteSourceAddress: Hashable, Sendable, CustomStringConvertible {
    private let family: UInt8
    private let bytes: Data
    let description: String

    init?(literal: String) {
        guard !literal.contains("%") else { return nil }
        if let address = IPv4Address(literal) {
            self.init(address)
        } else if let address = IPv6Address(literal) {
            self.init(address)
        } else {
            return nil
        }
    }

    private init(_ address: IPv4Address) {
        family = 4; bytes = address.rawValue; description = address.debugDescription
    }

    private init(_ address: IPv6Address) {
        family = 6; bytes = address.rawValue; description = address.debugDescription
    }

    init?(endpoint: NWEndpoint) {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): self.init(address)
        case .ipv6(let address): self.init(address)
        default: return nil
        }
    }

    /// A locator filter, never an authentication decision. HMAC + OOB-pinned TLS
    /// remain mandatory, including for other devices on a shared Wi-Fi network.
    var isPrivateLAN: Bool {
        let octets = Array(bytes)
        if family == 4, octets.count == 4 {
            return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
        }
        if family == 6, octets.count == 16 {
            return octets[0] & 0xfe == 0xfc || (octets[0] == 0xfe && octets[1] & 0xc0 == 0x80)
        }
        return false
    }

    var isRFC1918: Bool {
        let b = Array(bytes)
        return family == 4 && b.count == 4 && (b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.family == rhs.family && lhs.bytes == rhs.bytes
    }

    func hash(into hasher: inout Hasher) { hasher.combine(family); hasher.combine(bytes) }
}

enum RemoteHTTPTrace {
    @TaskLocal static var connectionID: String?
    static func errorFields(_ error: Error) -> [String: String] {
        let value = error as NSError
        return ["error_domain": value.domain, "error_code": String(value.code)]
    }
}

struct RemoteHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int = 200, headers: [String: String] = [:], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }
}

enum RemoteHTTPFailure: Error, Equatable {
    case badRequest
    case unauthorized
    case payloadTooLarge
    case unavailable
    case timeout
    case internalFailure

    var status: Int {
        switch self {
        case .badRequest: return 400
        case .unauthorized: return 401
        case .payloadTooLarge: return 413
        case .unavailable: return 503
        case .timeout: return 408
        case .internalFailure: return 500
        }
    }

    var response: RemoteHTTPResponse {
        let code: String
        switch self {
        case .badRequest: code = "invalid_http_request"
        case .unauthorized: code = "unauthorized"
        case .payloadTooLarge: code = "payload_too_large"
        case .unavailable: code = "unavailable"
        case .timeout: code = "request_timeout"
        case .internalFailure: code = "internal_error"
        }
        return RemoteHTTPResponse(status: status, body: Data("{\"error\":\"\(code)\"}".utf8))
    }
}

struct RemoteHTTPRequest: Sendable {
    let path: String
    let headers: [String: String]
    let body: Data
}

/// Narrow, deliberately non-general HTTP/1.1 framing. Exposed internally for
/// offline tests; it never normalizes or re-encodes the authenticated body.
struct RemoteHTTPRequestParser {
    static let maximumHeaderBytes = 16_384
    static let maximumBodyBytes = 1_024 * 1_024
    static let maximumHeaders = 64

    private(set) var path = "/v1/rpc"
    var isPairingRequest: Bool { path.hasPrefix("/v1/pair/") }
    private var buffer = Data()
    private var headers: [String: String]?
    private var bodyOffset = 0
    private var contentLength = 0
    private var completed = false

    mutating func append(_ data: Data) throws -> RemoteHTTPRequest? {
        guard !completed else { throw RemoteHTTPFailure.badRequest }
        guard buffer.count + data.count <= Self.maximumHeaderBytes + 4 + Self.maximumBodyBytes else {
            throw RemoteHTTPFailure.payloadTooLarge
        }
        buffer.append(data)
        if headers == nil {
            guard let separator = buffer.range(of: Data([13, 10, 13, 10])) else {
                guard buffer.count <= Self.maximumHeaderBytes + 3 else {
                    throw RemoteHTTPFailure.payloadTooLarge
                }
                return nil
            }
            guard separator.lowerBound <= Self.maximumHeaderBytes else {
                throw RemoteHTTPFailure.payloadTooLarge
            }
            let head = buffer.prefix(separator.lowerBound)
            guard head.allSatisfy({ $0 < 128 }), let text = String(data: head, encoding: .ascii) else {
                throw RemoteHTTPFailure.badRequest
            }
            let lines = text.components(separatedBy: "\r\n")
            let routes = ["/v1/rpc", "/v1/pair/request", "/v1/pair/claim"]
            guard let first = lines.first, let route = routes.first(where: { first == "POST " + $0 + " HTTP/1.1" }), lines.count - 1 <= Self.maximumHeaders else {
                throw RemoteHTTPFailure.badRequest
            }
            path = route
            var parsed: [String: String] = [:]
            for line in lines.dropFirst() {
                // Reject obs-fold, whitespace before ':', empty names, invalid
                // tokens and duplicate fields (even identical Content-Length).
                guard let colon = line.firstIndex(of: ":") else { throw RemoteHTTPFailure.badRequest }
                let name = String(line[..<colon])
                guard Self.isToken(name) else { throw RemoteHTTPFailure.badRequest }
                let rawValue = line[line.index(after: colon)...]
                guard rawValue.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                    throw RemoteHTTPFailure.badRequest
                }
                let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                let key = name.lowercased()
                guard parsed[key] == nil else { throw RemoteHTTPFailure.badRequest }
                parsed[key] = value
            }
            guard let host = parsed["host"], !host.isEmpty,
                  host.utf8.allSatisfy({ (33...126).contains($0) }),
                  let lengthText = parsed["content-length"], !lengthText.isEmpty,
                  lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(lengthText), String(length) == lengthText, length > 0 else {
                throw RemoteHTTPFailure.badRequest
            }
            guard length <= Self.maximumBodyBytes else { throw RemoteHTTPFailure.payloadTooLarge }
            for forbidden in ["transfer-encoding", "expect", "upgrade", "trailer", "content-encoding"] {
                guard parsed[forbidden] == nil else { throw RemoteHTTPFailure.badRequest }
            }
            if let connection = parsed["connection"] {
                guard connection.lowercased() == "close" else { throw RemoteHTTPFailure.badRequest }
            }
            let mediaType = parsed["content-type"]?.lowercased()
            guard mediaType == "application/json" || mediaType == "application/json; charset=utf-8" else {
                throw RemoteHTTPFailure.badRequest
            }
            if isPairingRequest {
                guard length <= 512, mediaType == "application/json",
                      !["cookie", "forwarded", "x-forwarded-for", "via"].contains(where: { parsed[$0] != nil }) else { throw RemoteHTTPFailure.badRequest }
            }
            headers = parsed; bodyOffset = separator.upperBound; contentLength = length
        }
        let end = bodyOffset + contentLength
        // Anything beyond the single framed body is an unsupported pipeline.
        guard buffer.count <= end else { throw RemoteHTTPFailure.badRequest }
        guard buffer.count == end, let headers else { return nil }
        completed = true
        return RemoteHTTPRequest(path: path, headers: headers, body: Data(buffer[bodyOffset..<end]))
    }

    static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || Array("!#$%&'*+-.^_`|~".utf8).contains($0)
        }
    }
}

/// Opt-in TLS listener. Constructing it does nothing; there is no default
/// identity, certificate import, plaintext fallback, Bonjour advertisement,
/// automatic launch, or listener retry. The owner must stop it on backgrounding.
@MainActor
final class RemoteHTTPTransport {
    struct Configuration {
        var enabled: Bool = false
        var port: UInt16 = 8_765
        var allowedSources: Set<RemoteSourceAddress> = []
        // Explicit local opt-in. This advertises no credentials or trusted identity.
        var advertiseCompanion: Bool = false
        var allowCompanionLAN: Bool = false
        var companionIdentityFingerprint: String?
        var companionHost: String?
    }

    enum StartFailure: Error {
        case disabled
        case invalidConfiguration
        case unusableIdentity
        case alreadyStarted
    }

    typealias PairingHandler = @MainActor @Sendable (String, Data, [String: String], RemoteSourceAddress) -> RemoteHTTPResponse
    typealias Handler = @MainActor @Sendable (Data, [String: String], RemoteSourceAddress) async throws -> RemoteHTTPResponse

    static let maximumConnections = 4
    static let maximumResponseBytes = 25 * 1_024 * 1_024
    static let requestTimeoutNanoseconds: UInt64 = 10_000_000_000
    static let operationTimeoutNanoseconds: UInt64 = 30_000_000_000
    static let writeTimeoutNanoseconds: UInt64 = 10_000_000_000

    private let configuration: Configuration
    private let handler: Handler
    private let pairingHandler: PairingHandler?
    private let onStateChange: @MainActor @Sendable (Bool) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let diagnostic: @MainActor @Sendable (String, [String: String]) -> Void
    private var listener: NWListener?
    private var generation = UUID()
    private var sessions: [UUID: Session] = [:]
    private(set) var isListening = false

    init(
        configuration: Configuration = Configuration(),
        onStateChange: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
        onFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        pairingHandler: PairingHandler? = nil,
        diagnostic: @escaping @MainActor @Sendable (String, [String: String]) -> Void = { _, _ in },
        handler: @escaping Handler
    ) {
        self.configuration = configuration; self.handler = handler; self.onStateChange = onStateChange; self.pairingHandler = pairingHandler
        self.onFailure = onFailure; self.diagnostic = diagnostic
    }

    func start(identity: SecIdentity) throws {
        guard configuration.enabled else { throw StartFailure.disabled }
        guard listener == nil else { throw StartFailure.alreadyStarted }
        guard (!configuration.allowedSources.isEmpty || configuration.allowCompanionLAN), configuration.allowedSources.count <= 64,
              configuration.port != 0, let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw StartFailure.invalidConfiguration
        }
        guard let protocolIdentity = sec_identity_create(identity) else { throw StartFailure.unusableIdentity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = false
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if configuration.allowCompanionLAN { parameters.requiredInterfaceType = .wifi }
        let server = try NWListener(using: parameters, on: port)
        if configuration.advertiseCompanion { server.service = companionService(pairing: false) }
        diagnostic("listener.configured", ["bonjour_configured": String(configuration.advertiseCompanion),
                                           "wifi_required": String(configuration.allowCompanionLAN), "port": String(configuration.port)])
        generation = UUID()
        let listenerGeneration = generation
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.accept(connection, generation: listenerGeneration)
            }
        }
        server.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == listenerGeneration else { return }
                switch state {
                case .ready:
                    self.isListening = true; self.diagnostic("listener.ready", [:]); self.onStateChange(true)
                case .failed(let error):
                    self.diagnostic("listener.failed", RemoteHTTPTrace.errorFields(error))
                    self.onFailure(error.localizedDescription); self.stop()
                case .waiting(let error):
                    self.diagnostic("listener.waiting", RemoteHTTPTrace.errorFields(error))
                    self.onFailure(error.localizedDescription); self.stop()
                case .cancelled: self.diagnostic("listener.cancelled", [:]); self.stop()
                default: break
                }
            }
        }
        server.start(queue: .main)
    }

    private var advertisedPairing = false
    static func companionTXT(identity: String, host: String, pairing: Bool) -> [String: String] {
        var txt = ["v": "1", "kind": "actell-muse-companion", "identity": identity, "host": host]
        if pairing { txt["pair"] = "1" }
        return txt
    }
    private func companionService(pairing: Bool) -> NWListener.Service {
        NWListener.Service(name: "Actell", type: MuseCompanionProtocol.serviceType,
                           txtRecord: NWTXTRecord(Self.companionTXT(identity: configuration.companionIdentityFingerprint ?? "", host: configuration.companionHost ?? "", pairing: pairing)))
    }
    func setPairingWindow(_ enabled: Bool) {
        guard configuration.advertiseCompanion, let listener, advertisedPairing != enabled else { return }
        advertisedPairing = enabled; listener.service = companionService(pairing: enabled)
    }

    func stop() {
        diagnostic("listener.stop", ["was_listening": String(isListening), "connections": String(sessions.count)])
        generation = UUID()
        listener?.cancel(); listener = nil
        let active = Array(sessions.values)
        for session in active { session.close() }
        isListening = false
        onStateChange(false)
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard self.generation == generation, listener != nil,
              sessions.count < Self.maximumConnections,
              let source = RemoteSourceAddress(endpoint: connection.endpoint),
              (configuration.allowedSources.contains(source) || (configuration.allowCompanionLAN && source.isRFC1918)) else {
            connection.cancel(); return
        }
        let id = UUID()
        let session = Session(connection: connection, source: source, handler: handler, pairingHandler: pairingHandler, diagnostic: diagnostic) { [weak self] in
            self?.sessions.removeValue(forKey: id)
        }
        sessions[id] = session
        session.start()
    }

    @MainActor
    private final class Session {
        private let connection: NWConnection
        private let source: RemoteSourceAddress
        private let handler: Handler
        private let pairingHandler: PairingHandler?
        private let onClose: @MainActor () -> Void
        private var parser = RemoteHTTPRequestParser()
        private var deadline: Task<Void, Never>?
        private var operation: Task<Void, Never>?
        private var closed = false
        private var receivedRequest = false
        private var sending = false
        private var operationInFlight = false
        private var notifiedClose = false
        private var phase = "read"
        private let traceID = MuseDiagnosticsLog.tag(UUID().uuidString)
        private let diagnostic: @MainActor @Sendable (String, [String: String]) -> Void
        private func report(_ stage: String, _ fields: [String: String] = [:]) {
            diagnostic(stage, fields.merging(["connection": traceID, "phase": phase], uniquingKeysWith: { _, new in new }))
        }

        init(connection: NWConnection, source: RemoteSourceAddress, handler: @escaping Handler, pairingHandler: PairingHandler?, diagnostic: @escaping @MainActor @Sendable (String, [String: String]) -> Void,
             onClose: @escaping @MainActor () -> Void) {
            self.diagnostic = diagnostic
            self.connection = connection; self.source = source; self.handler = handler; self.pairingHandler = pairingHandler; self.onClose = onClose
        }

        func start() {
            report("http.connection.accepted")
            armDeadline(RemoteHTTPTransport.requestTimeoutNanoseconds)
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    switch state {
                    case .ready: self.report("http.connection.ready"); self.receive()
                    case .failed(let error): self.report("http.connection.failed", RemoteHTTPTrace.errorFields(error)); self.close()
                    case .cancelled: self.report("http.connection.cancelled"); self.close()
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        }

        private func receive() {
            guard !closed, !sending else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self, !self.closed, !self.sending else { return }
                    if let error { self.report("http.read.failed", RemoteHTTPTrace.errorFields(error)); self.close(); return }
                    if self.receivedRequest {
                        // Never dispatch another request. If a later segment is
                        // pipelined while the first RPC runs, cancel its task and
                        // reject the stream; already-issued actions cannot be undone.
                        if let data, !data.isEmpty {
                            self.operation?.cancel()
                            self.send(RemoteHTTPFailure.badRequest.response)
                        } else if !complete {
                            self.receive()
                        }
                        return
                    }
                    do {
                        if let data, !data.isEmpty, let request = try self.parser.append(data) {
                            self.dispatch(request)
                            if !complete { self.receive() }
                            return
                        }
                        if complete { self.send(RemoteHTTPFailure.badRequest.response) }
                        else { self.receive() }
                    } catch let failure as RemoteHTTPFailure {
                        self.send(self.parser.isPairingRequest ? Self.pairFailure(failure) : failure.response)
                    } catch {
                        self.send(RemoteHTTPFailure.badRequest.response)
                    }
                }
            }
        }

        private func dispatch(_ request: RemoteHTTPRequest) {
            phase = "handler"
            report("http.request.parsed", ["route": request.path == "/v1/rpc" ? "rpc" : "pairing"])
            receivedRequest = true
            operationInFlight = true
            armDeadline(RemoteHTTPTransport.operationTimeoutNanoseconds)
            operation = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.operationInFlight = false
                    self.operation = nil
                    self.notifyCloseIfDrained()
                }
                guard !self.closed else { return }
                do {
                    try Task.checkCancellation()
                    let response: RemoteHTTPResponse
                    if request.path == "/v1/rpc" {
                        response = try await RemoteHTTPTrace.$connectionID.withValue(self.traceID) {
                            try await self.handler(request.body, request.headers, self.source)
                        }
                    }
                    else if self.source.isRFC1918, let pairingHandler = self.pairingHandler {
                        response = pairingHandler(request.path, request.body, request.headers, self.source)
                    } else { response = Self.pairFailure(.unauthorized) }
                    try Task.checkCancellation()
                    self.send(response)
                } catch is CancellationError {
                    self.close()
                } catch is RemoteRequestAuthenticator.Failure {
                    self.send(RemoteHTTPFailure.unauthorized.response)
                } catch let failure as RemoteHTTPFailure {
                    self.send(failure.response)
                } catch {
                    self.send(RemoteHTTPFailure.internalFailure.response)
                }
            }
        }

        private static func pairFailure(_ failure: RemoteHTTPFailure) -> RemoteHTTPResponse {
            let code = failure == .unauthorized ? "unauthorized" : "invalid_request"
            return RemoteHTTPResponse(status: failure == .unauthorized ? 401 : 400, body: Data("{\"v\":1,\"error\":\"\(code)\"}".utf8))
        }

        private func armDeadline(_ nanoseconds: UInt64) {
            deadline?.cancel()
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
                // A timed-out operation may already have executed. Closing the
                // connection reports no success and never retries the request.
                self?.report("http.deadline")
                self?.close()
            }
        }

        private func send(_ response: RemoteHTTPResponse) {
            guard !closed, !sending else { return }
            sending = true; phase = "write"
            report("http.response.queued", ["status": String(response.status), "body_bytes": String(response.body.count)])
            armDeadline(RemoteHTTPTransport.writeTimeoutNanoseconds)
            let wire: Data
            do { wire = try RemoteHTTPTransport.encode(response) }
            catch { wire = (try? RemoteHTTPTransport.encode(RemoteHTTPFailure.internalFailure.response)) ?? Data() }
            connection.send(content: wire, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    if let error { self?.report("http.response.failed", RemoteHTTPTrace.errorFields(error)) }
                    else { self?.report("http.response.processed") }
                    self?.close()
                }
            })
        }

        func close() {
            guard !closed else { return }
            closed = true
            report("http.connection.closed", ["handler_in_flight": String(operationInFlight)])
            deadline?.cancel(); deadline = nil
            operation?.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
            notifyCloseIfDrained()
        }

        private func notifyCloseIfDrained() {
            // A non-cooperative RPC keeps its slot after socket closure. Do not
            // let repeated timeout/reconnect cycles create unbounded RPC tasks.
            guard closed, !operationInFlight, !notifiedClose else { return }
            notifiedClose = true
            onClose()
        }
    }

    static func encode(_ response: RemoteHTTPResponse) throws -> Data {
        guard (200...599).contains(response.status), response.body.count <= maximumResponseBytes,
              response.headers.count <= 32 else { throw RemoteHTTPFailure.internalFailure }
        var headers: [String: String] = [:]
        for (name, value) in response.headers {
            let key = name.lowercased()
            guard RemoteHTTPRequestParser.isToken(name), name.utf8.count <= 128,
                  value.utf8.count <= 1_024, value.utf8.allSatisfy({ (32...126).contains($0) }),
                  headers[key] == nil,
                  !["connection", "content-length", "transfer-encoding", "trailer", "upgrade"].contains(key) else {
                throw RemoteHTTPFailure.internalFailure
            }
            headers[key] = value
        }
        if headers["content-type"] == nil { headers["content-type"] = "application/json" }
        headers["content-length"] = String(response.body.count)
        headers["connection"] = "close"
        headers["cache-control"] = "no-store"
        headers["x-content-type-options"] = "nosniff"
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 410: reason = "Gone"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 408: reason = "Request Timeout"
        case 409: reason = "Conflict"
        case 413: reason = "Content Too Large"
        case 429: reason = "Too Many Requests"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "Response"
        }
        var header = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for key in headers.keys.sorted() { header += "\(key): \(headers[key]!)\r\n" }
        header += "\r\n"
        guard header.utf8.count <= RemoteHTTPRequestParser.maximumHeaderBytes else {
            throw RemoteHTTPFailure.internalFailure
        }
        var data = Data(header.utf8)
        data.append(response.body)
        return data
    }
}
