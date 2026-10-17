import CryptoKit
import Foundation
import Network
import XCTest
@testable import PhoneAgent

@MainActor
final class RemoteTransportSecurityTests: XCTestCase {
    private let clientID = "client_1"
    private let requestID = "b3a99de4-fc24-4225-8789-c936e11e040d"
    private let nonce = "2f2823d7-53bd-46c1-b89c-78f3fa5e0911"
    private let seconds = "1791780000"
    private var key: Data { Data(0..<32) }
    private var body: Data {
        Data("{\"v\":1,\"client_id\":\"client_1\",\"request_id\":\"b3a99de4-fc24-4225-8789-c936e11e040d\",\"op\":\"ping\",\"params\":{}}".utf8)
    }
    private var date: Date { Date(timeIntervalSince1970: 1_791_780_000) }

    private func signedHeaders(
        client: String? = nil, request: String? = nil, nonce: String? = nil,
        time: String? = nil, rawBody: Data? = nil
    ) -> [String: String] {
        let time = time ?? seconds, nonce = nonce ?? self.nonce
        let message = RemoteRequestAuthenticator.signingMessage(
            clientID: client ?? clientID, requestID: request ?? requestID,
            time: time, nonce: nonce, body: rawBody ?? body
        )
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
        return ["x-actell-time": time, "x-actell-nonce": nonce, "x-actell-signature": signature]
    }

    func testFrozenHMACVectorAndExactBodyBytes() throws {
        let headers = signedHeaders()
        // Independently calculated with Python hashlib/hmac, not this helper.
        XCTAssertEqual(headers["x-actell-signature"], "40d096adbaccc88f986b02f7d4616c39961f643d975a9e40c43535c51ca9f3ee")
        let verifier = RemoteRequestAuthenticator(keyLookup: { [key] _ in key })
        var changedBody = body; changedBody.append(10)
        XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: headers, body: changedBody, now: date)) {
            XCTAssertEqual($0 as? RemoteRequestAuthenticator.Failure, .unauthorized)
        }
        // A failed MAC cannot consume the nonce.
        try verifier.verify(clientID: clientID, requestID: requestID, headers: headers, body: body, now: date)
        XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: headers, body: body, now: date)) {
            XCTAssertEqual($0 as? RemoteRequestAuthenticator.Failure, .replayed)
        }
    }

    func testBridgeProtocolSharedAuthenticationVector() throws {
        // Kept identical to muse-actell-bridge/protocol/auth-vector.json.
        let secret = Data("test-only-never-use-in-production-0000".utf8)
        let rawBody = Data("{\"v\":1,\"client_id\":\"test-client\",\"request_id\":\"00000000-0000-4000-8000-000000000001\",\"op\":\"capabilities\",\"params\":{}}".utf8)
        let headers = [
            "x-actell-time": "1791789900",
            "x-actell-nonce": "00000000-0000-4000-8000-000000000002",
            "x-actell-signature": "918badaa9bb84dfe44661830d7c746a12c2ce57ee256b3f65af00d91dae06f38"
        ]
        let verifier = RemoteRequestAuthenticator(keyLookup: { _ in secret })
        try verifier.verify(clientID: "test-client", requestID: "00000000-0000-4000-8000-000000000001", headers: headers, body: rawBody, now: Date(timeIntervalSince1970: 1_791_789_900))
        verifier.replaceKeyLookup { _ in secret }
        XCTAssertThrowsError(try verifier.verify(clientID: "test-client", requestID: "00000000-0000-4000-8000-000000000001", headers: headers, body: rawBody, now: Date(timeIntervalSince1970: 1_791_789_900))) {
            XCTAssertEqual($0 as? RemoteRequestAuthenticator.Failure, .replayed)
        }
    }

    func testClockWindowAndRevocationAreCheckedEveryTime() throws {
        var liveKey: Data? = key
        let verifier = RemoteRequestAuthenticator(keyLookup: { _ in liveKey })
        for delta in [-61.0, 61.0] {
            XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(), body: body, now: date.addingTimeInterval(delta))) {
                XCTAssertEqual($0 as? RemoteRequestAuthenticator.Failure, .expired)
            }
            XCTAssertEqual(verifier.rejectionReason, .clock_skew)
        }
        try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(), body: body, now: date.addingTimeInterval(-60))
        liveKey = nil
        XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(nonce: UUID().uuidString), body: body, now: date)) {
            XCTAssertEqual($0 as? RemoteRequestAuthenticator.Failure, .unauthorized)
        }
        XCTAssertEqual(verifier.rejectionReason, .key_unavailable)
    }

    func testReplayClockIsMonotonicAndUUIDCaseCannotBypassReplay() throws {
        var uptime: TimeInterval = 100
        let verifier = RemoteRequestAuthenticator(keyLookup: { [key] _ in key }, monotonicTime: { uptime })
        try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(), body: body, now: date)
        uptime = 219
        XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(nonce: nonce.uppercased()), body: body, now: date.addingTimeInterval(-20))) {
            XCTAssertEqual($0 as? RemoteRequestAuthenticator.Failure, .replayed)
        }
        XCTAssertEqual(verifier.rejectionReason, .replayed)
        uptime = 220
        try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(), body: body, now: date)
        XCTAssertNil(verifier.rejectionReason)
    }

    func testIdentifierAndSignatureCanonicalizationAreStrict() throws {
        let verifier = RemoteRequestAuthenticator(keyLookup: { [key] _ in key })
        for invalid in ["", "client.bad", "client\n1", "客户端", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try verifier.verify(clientID: invalid, requestID: requestID, headers: signedHeaders(client: invalid), body: body, now: date))
        }
        var headers = signedHeaders()
        headers["x-actell-signature"] = headers["x-actell-signature"]!.uppercased()
        XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: headers, body: body, now: date))
        try verifier.verify(clientID: clientID, requestID: "opaque_request-1", headers: signedHeaders(request: "opaque_request-1"), body: body, now: date)
    }

    func testNonceCacheFailsClosedWithoutEvictingLiveEntries() throws {
        let verifier = RemoteRequestAuthenticator(keyLookup: { [key] _ in key }, monotonicTime: { 100 })
        for _ in 0..<RemoteRequestAuthenticator.maximumTrackedNonces {
            try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(nonce: UUID().uuidString), body: body, now: date)
        }
        XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(), body: body, now: date)) {
            XCTAssertEqual($0 as? RemoteRequestAuthenticator.Failure, .replayCacheFull)
        }
        XCTAssertEqual(verifier.rejectionReason, .cache_full)
    }

    func testLocalDiagnosticReasonsDoNotChangePublicFailureTypes() throws {
        let verifier = RemoteRequestAuthenticator(keyLookup: { [key] _ in key })
        XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: [:], body: body, now: date))
        XCTAssertEqual(verifier.rejectionReason, .malformed)
        var wrong = body; wrong.append(10)
        XCTAssertThrowsError(try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(), body: wrong, now: date)) {
            XCTAssertEqual($0 as? RemoteRequestAuthenticator.Failure, .unauthorized)
        }
        XCTAssertEqual(verifier.rejectionReason, .signature_mismatch)
        try verifier.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(), body: body, now: date)
        XCTAssertNil(verifier.rejectionReason)
        let noClock = RemoteRequestAuthenticator(keyLookup: { [key] _ in key }, monotonicTime: { .nan })
        XCTAssertThrowsError(try noClock.verify(clientID: clientID, requestID: requestID, headers: signedHeaders(), body: body, now: date))
        XCTAssertEqual(noClock.rejectionReason, .monotonic_clock_unavailable)
    }

    private func requestBytes(
        firstLine: String = "POST /v1/rpc HTTP/1.1", extra: String = "", rawBody: Data? = nil
    ) -> Data {
        let body = rawBody ?? self.body
        var data = Data("\(firstLine)\r\nHost: phone.local:8765\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\(extra)\r\n".utf8)
        data.append(body)
        return data
    }

    func testParserHandlesEveryTwoPartBoundaryAndPreservesRawBody() throws {
        let data = requestBytes(extra: "X-Actell-Time: 1791780000\r\nConnection: close\r\n")
        for boundary in 1..<data.count {
            var parser = RemoteHTTPRequestParser()
            XCTAssertNil(try parser.append(Data(data.prefix(boundary))))
            let request = try XCTUnwrap(parser.append(Data(data.dropFirst(boundary))))
            XCTAssertEqual(request.body, body)
            XCTAssertEqual(request.headers["x-actell-time"], seconds)
        }
    }

    func testRejectsAmbiguousFramingAndUnsupportedHTTPFeatures() throws {
        for extra in [
            "Content-Length: \(body.count)\r\n", "content-length: \(body.count)\r\n",
            "Transfer-Encoding: chunked\r\n", "Transfer-Encoding: identity\r\n",
            "Expect: 100-continue\r\n", "Upgrade: websocket\r\n", "Trailer: Digest\r\n",
            "Content-Encoding: gzip\r\n", "Connection: keep-alive\r\n", " Bad: folded\r\n",
            "Bad : value\r\n", "X-Test: one\r\nx-test: two\r\n", "X-Test: a\nb\r\n"
        ] {
            var parser = RemoteHTTPRequestParser()
            XCTAssertThrowsError(try parser.append(requestBytes(extra: extra)), extra)
        }
        for line in ["GET /v1/rpc HTTP/1.1", "POST /v1/rpc?x=1 HTTP/1.1", "POST /v1/rpc/ HTTP/1.1", "POST /v1/rpc HTTP/1.0", "POST https://phone.local/v1/rpc HTTP/1.1"] {
            var parser = RemoteHTTPRequestParser()
            XCTAssertThrowsError(try parser.append(requestBytes(firstLine: line)), line)
        }
    }

    func testRejectsPipelinesBodyOverflowHeaderOverflowAndNoncanonicalLength() throws {
        var pipelined = requestBytes(); pipelined.append(requestBytes())
        var parser = RemoteHTTPRequestParser()
        XCTAssertThrowsError(try parser.append(pipelined))
        parser = RemoteHTTPRequestParser()
        XCTAssertNotNil(try parser.append(requestBytes()))
        XCTAssertThrowsError(try parser.append(requestBytes()))
        parser = RemoteHTTPRequestParser()
        XCTAssertThrowsError(try parser.append(requestBytes(rawBody: Data(repeating: 65, count: RemoteHTTPRequestParser.maximumBodyBytes + 1))))
        parser = RemoteHTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: 16_388)))
        for length in ["+1", "01", "1,1", "-1", "0", "999999999999999999999999"] {
            parser = RemoteHTTPRequestParser()
            let data = Data("POST /v1/rpc HTTP/1.1\r\nHost: phone\r\nContent-Type: application/json\r\nContent-Length: \(length)\r\n\r\nx".utf8)
            XCTAssertThrowsError(try parser.append(data))
        }
    }

    func testAllowlistUsesOnlyActualNumericEndpoints() throws {
        let ipv4 = try XCTUnwrap(RemoteSourceAddress(literal: "192.0.2.1"))
        XCTAssertEqual(ipv4, RemoteSourceAddress(endpoint: .hostPort(host: .ipv4(IPv4Address("192.0.2.1")!), port: 1)))
        XCTAssertNotEqual(ipv4, RemoteSourceAddress(literal: "192.0.2.2"))
        XCTAssertNil(RemoteSourceAddress(literal: "phone.local"))
        XCTAssertNil(RemoteSourceAddress(literal: "192.0.2.0/24"))
        XCTAssertNil(RemoteSourceAddress(endpoint: .hostPort(host: .name("192.0.2.1", nil), port: 1)))
        XCTAssertEqual(RemoteSourceAddress(literal: "2001:db8::1"), RemoteSourceAddress(literal: "2001:db8:0:0:0:0:0:1"))
    }

    func testDisabledDefaultsAndBinaryResponseFraming() throws {
        XCTAssertFalse(RemoteHTTPTransport.Configuration().enabled)
        XCTAssertTrue(RemoteHTTPTransport.Configuration().allowedSources.isEmpty)
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let wire = try RemoteHTTPTransport.encode(RemoteHTTPResponse(headers: ["Content-Type": "image/jpeg", "X-Actell-Image-Id": "image_1"], body: bytes))
        let separator = try XCTUnwrap(wire.range(of: Data([13, 10, 13, 10])))
        let head = try XCTUnwrap(String(data: wire.prefix(separator.lowerBound), encoding: .ascii))
        XCTAssertTrue(head.contains("content-length: 4\r\n"))
        XCTAssertTrue(head.contains("connection: close\r\n"))
        XCTAssertTrue(head.contains("content-type: image/jpeg\r\n"))
        XCTAssertEqual(Data(wire.suffix(from: separator.upperBound)), bytes)
        XCTAssertThrowsError(try RemoteHTTPTransport.encode(RemoteHTTPResponse(headers: ["X-Test": "ok\r\nInjected: yes"], body: bytes)))
        XCTAssertThrowsError(try RemoteHTTPTransport.encode(RemoteHTTPResponse(headers: ["Content-Length": "999"], body: bytes)))
    }
}
