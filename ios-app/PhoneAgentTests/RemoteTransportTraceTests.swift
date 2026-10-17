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
