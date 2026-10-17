import CryptoKit
import Foundation
import Network
import Security
import XCTest
@testable import PhoneAgent

/// Only trusts this test's generated certificate, with its stable DNS SAN,
/// while the test network connection stays on 127.0.0.1.
private final class TraceTestTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let der: Data
    let host: String
    init(der: Data, host: String) { self.der = der; self.host = host }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, der as CFData) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor final class RemoteTransportTraceTests: XCTestCase {
    func testLoopbackTLSStagesShareConnectionTagWithoutLoggingPayload() async throws {
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.tests.transport-trace." + UUID().uuidString)
        defer { try? provider.remove() }
        let host = "actell-trace-test.local"
        let identity = try provider.provision(host: host)
        let port = UInt16.random(in: 20000...40000)
        var events: [(String, [String: String])] = []
        var handlerConnection: String?
        let transport = RemoteHTTPTransport(configuration: .init(enabled: true, port: port,
            allowedSources: [RemoteSourceAddress(literal: "127.0.0.1")!]),
            diagnostic: { events.append(($0, $1)) }) { _, _, _ in
                handlerConnection = RemoteHTTPTrace.connectionID
                return RemoteHTTPResponse(body: Data("{\"ok\":true}".utf8))
            }
        defer { transport.stop() }
        try transport.start(identity: identity.identity)
        for _ in 0..<150 where !transport.isListening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(transport.isListening)
        let trust = TraceTestTrust(der: identity.certificateDER, host: host)
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = Data("{\"private-test-payload\":true}".utf8)
        let (body, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body, Data("{\"ok\":true}".utf8))
        for _ in 0..<100 where !events.contains(where: { $0.0 == "http.connection.closed" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let tag = try XCTUnwrap(handlerConnection)
        for stage in ["http.connection.accepted", "http.connection.ready", "http.request.parsed", "http.response.queued", "http.response.processed", "http.connection.closed"] {
            XCTAssertTrue(events.contains { $0.0 == stage && $0.1["connection"] == tag }, stage)
        }
        XCTAssertTrue(events.contains { $0.0 == "listener.ready" })
        XCTAssertTrue(events.contains { $0.0 == "http.response.queued" && $0.1["status"] == "200" })
        XCTAssertFalse(String(describing: events).contains("private-test-payload"))
        XCTAssertFalse(String(describing: events).contains("127.0.0.1"))
    }
}

/// An explicit socket boundary makes callback races reproducible. In particular,
/// processing a send does not imply that the peer has consumed its bytes.
@MainActor private final class TraceTestConnection: RemoteHTTPConnection {
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var reader: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
    var sendCompletion: (@Sendable (NWError?) -> Void)?
    var sent: [Data] = []
    var finals: [Bool] = []
    var cancelCount = 0
    var receiveCount = 0
    func start(queue: DispatchQueue) { stateUpdateHandler?(.ready) }
    func cancel() { cancelCount += 1 }
    func receive(minimumIncompleteLength: Int, maximumLength: Int,
                 completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) {
        XCTAssertNil(reader, "Only one outstanding receive may own the stream")
        receiveCount += 1
        reader = completion
    }
    func send(content: Data?, contentContext: NWConnection.ContentContext, isComplete: Bool,
              completion: NWConnection.SendCompletion) {
        finals.append(contentContext.isFinal)
        XCTAssertTrue(isComplete)
        sent.append(content ?? Data())
        guard case .contentProcessed(let callback) = completion else { return XCTFail("Missing send completion") }
        sendCompletion = callback
    }
    func feed(_ data: Data? = nil, complete: Bool = false, error: NWError? = nil) throws {
        let callback = try XCTUnwrap(reader)
        reader = nil
        callback(data, nil, complete, error)
    }
}

@MainActor private final class TraceSessionHarness {
    let connection = TraceTestConnection()
    var session: RemoteHTTPTransport.Session!
    var events: [(String, [String: String])] = []
    var calls = 0
    var releases = 0
    init(requestTimeout: UInt64 = 10_000_000_000, writeTimeout: UInt64 = 10_000_000_000, operationTimeout: UInt64 = 30_000_000_000,
         handler: RemoteHTTPTransport.Handler? = nil) {
        session = RemoteHTTPTransport.Session(connection: connection,
            source: RemoteSourceAddress(literal: "127.0.0.1")!, handler: { [weak self] body, headers, source in
                self?.calls += 1
                if let handler { return try await handler(body, headers, source) }
                return RemoteHTTPResponse(body: Data(repeating: 0x5a, count: 256 * 1_024))
            }, pairingHandler: nil, diagnostic: { [weak self] stage, fields in self?.events.append((stage, fields)) },
            timeouts: .init(request: requestTimeout, operation: operationTimeout, write: writeTimeout),
            onClose: { [weak self] in self?.releases += 1 })
    }
    func has(_ stage: String) -> Bool { events.contains { $0.0 == stage } }
    static var request: Data {
        Data("POST /v1/rpc HTTP/1.1\r\nHost: test.local\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
    }
}

@MainActor private final class TraceHandlerGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

private enum TraceTestFailure: Error { case eventTimeout, connectionFailed }

extension RemoteTransportTraceTests {
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the transport event", file: file, line: line)
        throw TraceTestFailure.eventTimeout
    }
    private func begin(_ harness: TraceSessionHarness, complete: Bool = false) async throws {
        harness.session.start()
        try await waitUntil { harness.connection.reader != nil }
        try harness.connection.feed(TraceSessionHarness.request, complete: complete)
        try await waitUntil { harness.calls == 1 }
    }

    func testProcessedResponseRetainsSessionUntilPeerEndsAndClosesExactlyOnce() async throws {
        let h = TraceSessionHarness()
        defer { h.session.close() }
        try await begin(h)
        try await waitUntil { h.connection.sendCompletion != nil }
        let wire = try XCTUnwrap(h.connection.sent.first)
        let separator = try XCTUnwrap(wire.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertEqual(wire.suffix(from: separator.upperBound), Data(repeating: 0x5a, count: 256 * 1_024))
        let callback = try XCTUnwrap(h.connection.sendCompletion)
        callback(nil)
        try await waitUntil { h.has("http.response.processed") }
        XCTAssertEqual(h.connection.cancelCount, 0)
        XCTAssertEqual(h.releases, 0)
        XCTAssertNotNil(h.connection.reader, "Read armed before sending must still observe peer EOF")
        try h.connection.feed(complete: true)
        try await waitUntil { h.releases == 1 }
        XCTAssertTrue(h.events.contains { $0.0 == "http.connection.closed" && $0.1["phase"] == "drain" })
        callback(.posix(.ECONNRESET))
        h.session.close()
        await Task.yield()
        XCTAssertEqual(h.connection.cancelCount, 1)
        XCTAssertEqual(h.releases, 1)
        XCTAssertEqual(h.calls, 1)
        XCTAssertFalse(h.has("http.response.failed"), "Late callbacks cannot overwrite a closed response")
    }

    func testBackpressuredWriteExpiresAndLateSuccessCannotReviveIt() async throws {
        let h = TraceSessionHarness(writeTimeout: 100_000_000)
        defer { h.session.close() }
        try await begin(h)
        try await waitUntil { h.connection.sendCompletion != nil }
        XCTAssertEqual(h.releases, 0)
        try await waitUntil { h.releases == 1 }
        XCTAssertTrue(h.events.contains { $0.0 == "http.deadline" && $0.1["phase"] == "write" })
        h.connection.sendCompletion?(nil)
        await Task.yield()
        XCTAssertFalse(h.has("http.response.processed"))
        XCTAssertEqual(h.connection.cancelCount, 1)
    }

    func testProcessedResponseWithoutPeerEOFRemainsBounded() async throws {
        let h = TraceSessionHarness(writeTimeout: 100_000_000)
        defer { h.session.close() }
        try await begin(h)
        try await waitUntil { h.connection.sendCompletion != nil }
        h.connection.sendCompletion?(nil)
        try await waitUntil { h.has("http.response.processed") }
        XCTAssertEqual(h.releases, 0)
        try await waitUntil { h.releases == 1 }
        XCTAssertTrue(h.events.contains { $0.0 == "http.deadline" && $0.1["phase"] == "drain" })
        XCTAssertEqual(h.connection.cancelCount, 1)
    }

    func testEarlyRequestEOFDoesNotAcknowledgeTheResponse() async throws {
        for eofWithRequest in [true, false] {
            let h = TraceSessionHarness(writeTimeout: 100_000_000)
            defer { h.session.close() }
            try await begin(h, complete: eofWithRequest)
            try await waitUntil { h.connection.sendCompletion != nil }
            if !eofWithRequest {
                try h.connection.feed(complete: true)
                try await waitUntil { h.has("http.peer.ended") }
            }
            h.connection.sendCompletion?(nil)
            try await waitUntil { h.has("http.response.processed") }
            XCTAssertEqual(h.connection.cancelCount, 0)
            XCTAssertEqual(h.releases, 0)
            XCTAssertNil(h.connection.reader, "Never receive again after stream EOF")
            try await waitUntil { h.releases == 1 }
            XCTAssertTrue(h.has("http.deadline"))
            XCTAssertEqual(h.calls, 1)
        }
    }

    func testSendFailureAndPeerResetClosePromptlyWithoutAnotherResponse() async throws {
        for resetDuringDrain in [false, true] {
            let h = TraceSessionHarness()
            defer { h.session.close() }
            try await begin(h)
            try await waitUntil { h.connection.sendCompletion != nil }
            if resetDuringDrain {
                h.connection.sendCompletion?(nil)
                try await waitUntil { h.has("http.response.processed") }
                try h.connection.feed(error: .posix(.ECONNRESET))
            } else {
                h.connection.sendCompletion?(.posix(.EPIPE))
            }
            try await waitUntil { h.releases == 1 }
            XCTAssertEqual(h.connection.cancelCount, 1)
            XCTAssertEqual(h.connection.sent.count, 1)
            XCTAssertEqual(h.calls, 1)
            XCTAssertTrue(h.has(resetDuringDrain ? "http.read.failed" : "http.response.failed"))
        }
    }

    func testPipelineDuringWriteOrDrainNeverDispatchesAnotherRPC() async throws {
        for processed in [false, true] {
            let h = TraceSessionHarness()
            defer { h.session.close() }
            try await begin(h)
            try await waitUntil { h.connection.sendCompletion != nil }
            if processed {
                h.connection.sendCompletion?(nil)
                try await waitUntil { h.has("http.response.processed") }
            }
            try h.connection.feed(TraceSessionHarness.request)
            try await waitUntil { h.releases == 1 }
            XCTAssertTrue(h.has("http.pipeline.rejected"))
            XCTAssertEqual(h.calls, 1)
            XCTAssertEqual(h.connection.sent.count, 1)
        }
    }

    func testPipelineCancellationDoesNotTruncateItsErrorResponse() async throws {
        let entered = TraceHandlerGate()
        let h = TraceSessionHarness(handler: { _, _, _ in
            await entered.wait()
            try Task.checkCancellation()
            return RemoteHTTPResponse(body: Data())
        })
        defer { entered.resume(); h.session.close() }
        try await begin(h)
        try await waitUntil { entered.continuation != nil && h.connection.reader != nil }
        try h.connection.feed(TraceSessionHarness.request)
        try await waitUntil { h.connection.sendCompletion != nil }
        entered.resume()
        h.connection.sendCompletion?(nil)
        try await waitUntil { h.has("http.response.processed") }
        // Let the cancelled handler unwind before completing the peer's read.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(h.connection.cancelCount, 0)
        XCTAssertTrue(String(decoding: h.connection.sent[0], as: UTF8.self).hasPrefix("HTTP/1.1 400"))
        try h.connection.feed(complete: true)
        try await waitUntil { h.releases == 1 }
        XCTAssertEqual(h.calls, 1)
        XCTAssertEqual(h.connection.sent.count, 1)
    }

    func testNonCooperativeHandlerKeepsSlotAfterCancellationOrDeadline() async throws {
        XCTAssertEqual(RemoteHTTPTransport.maximumConnections, 4)
        for expire in [false, true] {
            let gate = TraceHandlerGate()
            let h = TraceSessionHarness(operationTimeout: expire ? 100_000_000 : 30_000_000_000, handler: { _, _, _ in
                await gate.wait() // Deliberately ignores cancellation until resumed.
                return RemoteHTTPResponse(body: Data("late-result".utf8))
            })
            defer { gate.resume(); h.session.close() }
            try await begin(h)
            try await waitUntil { gate.continuation != nil }
            if expire { try await waitUntil { h.has("http.deadline") } }
            else { h.session.close() }
            XCTAssertEqual(h.connection.cancelCount, 1)
            XCTAssertEqual(h.releases, 0, "Closed socket cannot free an in-flight handler's connection slot")
            gate.resume()
            try await waitUntil { h.releases == 1 }
            XCTAssertTrue(h.connection.sent.isEmpty, "No late result or replay after cancellation")
            XCTAssertEqual(h.calls, 1)
            h.session.close()
            XCTAssertEqual(h.releases, 1)
        }
    }

    func testExplicitStopWhileDrainingReleasesConnection() async throws {
        let h = TraceSessionHarness()
        defer { h.session.close() }
        try await begin(h)
        try await waitUntil { h.connection.sendCompletion != nil }
        h.connection.sendCompletion?(nil)
        try await waitUntil { h.has("http.response.processed") }
        h.session.close()
        XCTAssertEqual(h.releases, 1)
        XCTAssertEqual(h.connection.cancelCount, 1)
    }
}

/// Real Network.framework TLS with a synthetic anchored identity. Delays between
/// small reads exercise receiver backpressure; they are test input, not a fix.
@MainActor private final class TraceTLSClient {
    let connection: NWConnection
    var ready = false
    var failed = false
    init(port: UInt16, der: Data, host: String) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let anchor = SecCertificateCreateWithData(nil, der as CFData) else { complete(false); return }
            SecTrustSetPolicies(value, SecPolicyCreateSSL(true, host as CFString))
            SecTrustSetAnchorCertificates(value, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(value, true)
            complete(SecTrustEvaluateWithError(value, nil))
        }, .global())
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.ready = true }
                if case .failed = state { self?.failed = true }
                if case .waiting = state { self?.failed = true; self?.connection.cancel() }
            }
        }
        connection.start(queue: .main)
    }
    func send(_ data: Data?, final: Bool = false) async throws {
        guard ready, !failed else { throw TraceTestFailure.connectionFailed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage,
                            isComplete: true, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    func readResponseSlowly() async throws -> Data {
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            connection.cancel()
        }
        defer { deadline.cancel() }
        var result = Data()
        var expectedBytes: Int?
        while true {
            let (data, ended): (Data?, Bool) = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 2_048) { data, _, ended, error in
                    if let error { c.resume(throwing: error) } else { c.resume(returning: (data, ended)) }
                }
            }
            if let data { result.append(data) }
            if expectedBytes == nil, let separator = result.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: result.prefix(separator.lowerBound), as: UTF8.self)
                let field = try XCTUnwrap(header.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length: ") })
                let length = try XCTUnwrap(Int(field.dropFirst("content-length: ".count)))
                expectedBytes = separator.upperBound + length
            }
            // HTTP framing, as used by Muse, determines completion. Waiting for
            // server EOF before ending the request side can itself deadlock TLS.
            if let expectedBytes, result.count >= expectedBytes { return result }
            if ended { return result }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

extension RemoteTransportTraceTests {
    func testTLSImageDrainPreservesBytesAndConnectionLimitUntilPeersFinish() async throws {
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.tests.transport-drain." + UUID().uuidString)
        defer { try? provider.remove() }
        let host = "actell-drain-test.local"
        let identity = try provider.provision(host: host)
        let port = UInt16.random(in: 20000...40000)
        let bytes = Data((0..<(256 * 1_024)).map { UInt8(truncatingIfNeeded: $0) })
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var events: [(String, [String: String])] = []
        var calls = 0
        let transport = RemoteHTTPTransport(configuration: .init(enabled: true, port: port,
            allowedSources: [RemoteSourceAddress(literal: "127.0.0.1")!]),
            diagnostic: { stage, fields in
                events.append((stage, fields))
                print("TLS-drain stage=\(stage) phase=\(fields["phase"] ?? "-") connection=\(fields["connection"] ?? "-")")
            }) { _, _, _ in
                calls += 1
                return RemoteHTTPResponse(headers: ["Content-Type": "image/jpeg", "X-Image-SHA256": digest], body: bytes)
            }
        var clients: [TraceTLSClient] = []
        defer { clients.forEach { $0.connection.cancel() }; transport.stop() }
        try transport.start(identity: identity.identity)
        try await waitUntil { transport.isListening }
        for _ in 0..<RemoteHTTPTransport.maximumConnections {
            let client = TraceTLSClient(port: port, der: identity.certificateDER, host: host)
            clients.append(client)
            client.start()
            try await waitUntil { client.ready || client.failed }
            XCTAssertTrue(client.ready)
            try await client.send(TraceSessionHarness.request)
        }
        try await waitUntil { events.filter { $0.0 == "http.response.queued" }.count == 4 }
        XCTAssertFalse(events.contains { $0.0 == "http.connection.closed" }, "Queued responses must retain all four slots")
        let overflow = TraceTLSClient(port: port, der: identity.certificateDER, host: host)
        clients.append(overflow)
        overflow.start()
        try await waitUntil { overflow.failed }
        XCTAssertFalse(overflow.ready, "A fifth connection must be rejected before RPC dispatch")
        XCTAssertEqual(calls, 4)
        // Read complete encrypted responses in small pieces using HTTP framing.
        // Body length and digest are checked independently of send callbacks.
        for client in clients.prefix(4) {
            let wire = try await client.readResponseSlowly()
            let separator = try XCTUnwrap(wire.range(of: Data("\r\n\r\n".utf8)))
            let head = String(decoding: wire.prefix(separator.lowerBound), as: UTF8.self)
            let body = Data(wire.suffix(from: separator.upperBound))
            XCTAssertTrue(head.contains("content-length: \(bytes.count)\r\n"))
            XCTAssertTrue(head.contains("x-image-sha256: \(digest)"))
            XCTAssertEqual(body.count, bytes.count)
            XCTAssertEqual(SHA256.hash(data: body), SHA256.hash(data: bytes))
            try await client.send(nil, final: true)
            client.connection.cancel()
        }
        try await waitUntil { events.filter { $0.0 == "http.connection.closed" }.count == 4 }
        XCTAssertFalse(events.contains { $0.0 == "http.deadline" || $0.0 == "http.response.failed" })
        // Released slots admit new work normally; no handler or response is replayed.
        let replacement = TraceTLSClient(port: port, der: identity.certificateDER, host: host)
        clients.append(replacement)
        replacement.start()
        try await waitUntil { replacement.ready || replacement.failed }
        XCTAssertTrue(replacement.ready)
        try await replacement.send(TraceSessionHarness.request)
        _ = try await replacement.readResponseSlowly()
        try await replacement.send(nil, final: true)
        replacement.connection.cancel()
        try await waitUntil { events.filter { $0.0 == "http.connection.closed" }.count == 5 }
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(events.filter { $0.0 == "http.request.parsed" }.count, 5)
    }
}

extension RemoteTransportTraceTests {
    private var reusableRequest: Data {
        Data(String(decoding: TraceSessionHarness.request, as: UTF8.self).replacingOccurrences(of: "Connection: close", with: "Connection: keep-alive").utf8)
    }
    func testSequentialRequestBeforeSendCallbackIsBufferedWithoutParallelDispatch() async throws {
        let h = TraceSessionHarness()
        defer { h.session.close() }
        h.session.start(); try await waitUntil { h.connection.reader != nil }
        try h.connection.feed(reusableRequest)
        try await waitUntil { h.connection.sent.count == 1 }
        XCTAssertEqual(h.connection.finals, [false])
        try h.connection.feed(TraceSessionHarness.request)
        await Task.yield()
        XCTAssertEqual(h.calls, 1)
        h.connection.sendCompletion?(nil)
        try await waitUntil { h.connection.sent.count == 2 }
        XCTAssertEqual(h.calls, 2)
        XCTAssertEqual(h.connection.finals, [false, true])
        h.connection.sendCompletion?(nil)
        try await waitUntil { h.events.filter { $0.0 == "http.response.processed" }.count == 2 }
        try h.connection.feed(complete: true)
        try await waitUntil { h.releases == 1 }
    }
    func testReuseIdleAndRequestCountAreBounded() async throws {
        let idle = TraceSessionHarness(requestTimeout: 150_000_000)
        defer { idle.session.close() }
        idle.session.start(); try await waitUntil { idle.connection.reader != nil }
        try idle.connection.feed(reusableRequest)
        try await waitUntil { idle.connection.sent.count == 1 }
        idle.connection.sendCompletion?(nil)
        try await waitUntil { idle.has("http.connection.reusable") }
        try await waitUntil { idle.releases == 1 }
        XCTAssertTrue(idle.events.contains { $0.0 == "http.deadline" && $0.1["phase"] == "idle" })
        let h = TraceSessionHarness(handler: { _, _, _ in RemoteHTTPResponse(body: Data("{}".utf8)) })
        defer { h.session.close() }
        h.session.start(); try await waitUntil { h.connection.reader != nil }
        for index in 1...RemoteHTTPTransport.maximumRequestsPerConnection {
            try h.connection.feed(reusableRequest)
            try await waitUntil { h.connection.sent.count == index }
            h.connection.sendCompletion?(nil)
            try await waitUntil { h.events.filter { $0.0 == "http.response.processed" }.count == index }
        }
        XCTAssertEqual(h.connection.finals.last, true)
        XCTAssertTrue(h.connection.finals.dropLast().allSatisfy { !$0 })
        try h.connection.feed(complete: true)
        try await waitUntil { h.releases == 1 }
    }
    func testKeepAliveTruncatedSecondBodyNeverDispatches() async throws {
        let h = TraceSessionHarness()
        defer { h.session.close() }
        h.session.start(); try await waitUntil { h.connection.reader != nil }
        try h.connection.feed(reusableRequest)
        try await waitUntil { h.connection.sent.count == 1 }
        h.connection.sendCompletion?(nil)
        try await waitUntil { h.has("http.connection.reusable") }
        try h.connection.feed(Data(reusableRequest.dropLast()), complete: true)
        try await waitUntil { h.connection.sent.count == 2 }
        XCTAssertEqual(h.calls, 1)
        XCTAssertTrue(String(decoding: h.connection.sent[1], as: UTF8.self).hasPrefix("HTTP/1.1 400"))
        XCTAssertEqual(h.connection.finals.last, true)
    }
    func testTLSSequentialLargeBodiesVerifyEveryRequestAndRejectReplayedNonce() async throws {
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.tests.reuse." + UUID().uuidString)
        defer { try? provider.remove() }
        let host = "actell-reuse-test.local", port = UInt16.random(in: 20000...40000)
        let identity = try provider.provision(host: host)
        let key = Data(repeating: 7, count: 32)
        let verifier = RemoteRequestAuthenticator(keyLookup: { _ in key })
        let bytes = Data(repeating: 0x67, count: 256 * 1024)
        var calls = 0, connections = Set<String>()
        let transport = RemoteHTTPTransport(configuration: .init(enabled: true, port: port,
            allowedSources: [RemoteSourceAddress(literal: "127.0.0.1")!])) { body, headers, _ in
            connections.insert(RemoteHTTPTrace.connectionID ?? "missing")
            try verifier.verify(clientID: "client", requestID: "request", headers: headers, body: body)
            calls += 1
            return RemoteHTTPResponse(body: bytes)
        }
        let client = TraceTLSClient(port: port, der: identity.certificateDER, host: host)
        defer { client.connection.cancel(); transport.stop() }
        try transport.start(identity: identity.identity); try await waitUntil { transport.isListening }
        client.start(); try await waitUntil { client.ready || client.failed }
        func request(nonce: String) -> Data {
            let time = String(Int64(Date().timeIntervalSince1970))
            let signature = HMAC<SHA256>.authenticationCode(for: RemoteRequestAuthenticator.signingMessage(clientID: "client", requestID: "request", time: time, nonce: nonce, body: Data("{}".utf8)), using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
            return Data("POST /v1/rpc HTTP/1.1\r\nHost: test.local\r\nContent-Type: application/json\r\nContent-Length: 2\r\nx-actell-time: \(time)\r\nx-actell-nonce: \(nonce)\r\nx-actell-signature: \(signature)\r\n\r\n{}".utf8)
        }
        let last = request(nonce: UUID().uuidString.lowercased())
        for wire in [request(nonce: UUID().uuidString.lowercased()), last] {
            try await client.send(wire)
            let response = try await client.readResponseSlowly()
            let separator = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
            XCTAssertEqual(Data(response.suffix(from: separator.upperBound)), bytes)
            XCTAssertTrue(String(decoding: response.prefix(separator.lowerBound), as: UTF8.self).contains("connection: keep-alive"))
        }
        try await client.send(last)
        let rejected = try await client.readResponseSlowly()
        XCTAssertTrue(String(decoding: rejected, as: UTF8.self).hasPrefix("HTTP/1.1 401"))
        XCTAssertEqual(calls, 2); XCTAssertEqual(connections.count, 1)
    }
}
