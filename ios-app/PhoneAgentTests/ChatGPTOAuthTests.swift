import XCTest
import UIKit
import CryptoKit
import Security
import ProviderCore
import OpenAIAdapter
import SwiftAgentKit
@testable import PhoneAgent

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
private actor OAuthFixture: ChatGPTHTTPClient {
    let key = P256.Signing.PrivateKey()
    var nonce = "", subject = "subject-A", scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    var errorCode: String?, invalidSignature = false, refreshCount = 0, exchangeCount = 0, revokeCount = 0
    var delayRefresh = false, delayExchange = false
    func setup(nonce: String, subject: String = "subject-A", scope: String? = nil) { self.nonce = nonce; self.subject = subject; if let scope { self.scope = scope } }
    func fail(_ code: String?) { errorCode = code }
    func setInvalid() { invalidSignature = true }
    func delay() { delayRefresh = true }
    func delayAuthorization() { delayExchange = true }
    func jwks() throws -> Data {
        let p = key.publicKey.x963Representation
        return try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "EC", "crv": "P-256", "alg": "ES256", "x": b64(p.subdata(in: 1..<33)), "y": b64(p.subdata(in: 33..<65))]]])
    }
    func jwt(client: String, changes: [String: Any] = [:]) throws -> String {
        let now = Date().timeIntervalSince1970
        var claims: [String: Any] = ["iss": ChatGPTIDTokenVerifier.issuer, "aud": client, "sub": subject, "email": "same@example.invalid", "nonce": nonce, "iat": now - 1, "exp": now + 3600]
        claims.merge(changes) { _, b in b }
        let signed = b64(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "test"])) + "." + b64(try JSONSerialization.data(withJSONObject: claims))
        return signed + "." + b64(invalidSignature ? Data(repeating: 0, count: 64) : try key.signature(for: Data(signed.utf8)).rawRepresentation)
    }
    func data(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url == ChatGPTIDTokenVerifier.jwksURL { return (try jwks(), 200) }
        if request.url == ChatGPTAccountManager.discoveryURL { return (try JSONSerialization.data(withJSONObject: ["issuer": ChatGPTIDTokenVerifier.issuer, "revocation_endpoint": "https://auth.openai.com/api/accounts/fixture-revoke"]), 200) }
        if request.url?.path == "/api/accounts/fixture-revoke" { revokeCount += 1; return (Data(), 200) }
        guard request.url == ChatGPTSubscriptionPolicy.token else { throw ChatGPTAuthError.network }
        var parts = URLComponents(); parts.percentEncodedQuery = String(decoding: request.httpBody!, as: UTF8.self)
        let form = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value ?? "") })
        let refresh = form["grant_type"] == "refresh_token"
        if refresh { refreshCount += 1; if delayRefresh { try await Task.sleep(for: .milliseconds(80)) } }
        else { exchangeCount += 1; if delayExchange { try await Task.sleep(for: .milliseconds(100)) }; XCTAssertEqual(form["resource"], ChatGPTSubscriptionPolicy.resource.absoluteString); XCTAssertTrue(form["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true); XCTAssertFalse(form["code_verifier"]?.isEmpty ?? true) }
        if let errorCode { return (try JSONSerialization.data(withJSONObject: ["error": errorCode]), 400) }
        let body: [String: Any] = ["access_token": "access-\(subject)-\(refreshCount)", "refresh_token": "refresh-\(subject)-\(refreshCount)", "token_type": "Bearer", "id_token": try jwt(client: form["client_id"]!), "scope": scope, "expires_in": 3600]
        return (try JSONSerialization.data(withJSONObject: body), 200)
    }
}

private final class FaultingOAuthStorage: ChatGPTCredentialStorage, @unchecked Sendable {
    private let base = ChatGPTMemoryStorage(), lock = NSLock()
    private var failWrites = false
    func fail() { lock.withLock { failWrites = true } }
    func load() -> Data? { base.load() }
    func replace(_ data: Data) throws { if lock.withLock({ failWrites }) { throw ChatGPTAuthError.persistence }; base.replace(data) }
}

final class ChatGPTOAuthTests: XCTestCase {
    private func callback(_ p: ChatGPTPendingAuthorization, client: String = "oaiapp_A") -> URL { URL(string: p.attempt.redirect.absoluteString + "?state=\(p.attempt.state)&code=fixture&client_id=\(client)")! }
    private func login(_ manager: ChatGPTAccountManager, _ http: OAuthFixture, profile: UUID, client: String = "oaiapp_A", subject: String = "subject-A", add: Bool = false, scope: String? = nil) async throws -> String {
        let p = try await manager.begin(profileID: profile, redirect: URL(string: "http://127.0.0.1:3456/auth/callback")!, addAccount: add)
        await http.setup(nonce: p.attempt.nonce, subject: subject, scope: scope)
        try await manager.finish(p.id, callback: callback(p, client: client))
        let selected = try await manager.selectedAccount(profileID: profile)
        return try XCTUnwrap(selected)
    }
    func testES256IdentityClaimsSignatureAndAudienceFences() async throws {
        let http = OAuthFixture(); await http.setup(nonce: "expected")
        let jwks = try await http.jwks(), valid = try await http.jwt(client: "oaiapp_A")
        XCTAssertEqual(try ChatGPTIDTokenVerifier.verify(valid, jwks: jwks, clientID: "oaiapp_A", nonce: "expected").subject, "subject-A")
        let cases: [[String: Any]] = [["iss": "https://other.invalid"], ["aud": "oaiapp_B"], ["nonce": "wrong"], ["exp": 1.0], ["iat": Date().timeIntervalSince1970 + 600], ["nbf": Date().timeIntervalSince1970 + 600], ["aud": ["oaiapp_A", "another"]], ["azp": "wrong"], ["sub": ""]]
        for changes in cases {
            let jwt = try await http.jwt(client: "oaiapp_A", changes: changes)
            XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(jwt, jwks: jwks, clientID: "oaiapp_A", nonce: "expected"))
        }
        await http.setInvalid(); let invalid = try await http.jwt(client: "oaiapp_A")
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(invalid, jwks: jwks, clientID: "oaiapp_A", nonce: "expected"))
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(valid, jwks: Data("{\"keys\":[]}".utf8), clientID: "oaiapp_A", nonce: "expected"))
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify("e30.e30.e30", jwks: jwks, clientID: "oaiapp_A", nonce: nil))
    }
    func testRS256PublishedJWKVerification() throws {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(key)), der = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil)) as Data
        var pos = 0
        func length() -> Int { let b = Int(der[pos]); pos += 1; if b < 128 { return b }; var n = 0; for _ in 0..<(b & 127) { n = n * 256 + Int(der[pos]); pos += 1 }; return n }
        XCTAssertEqual(der[pos], 0x30); pos += 1; _ = length()
        func integer() -> Data { XCTAssertEqual(der[pos], 2); pos += 1; let n = length(); var d = der.subdata(in: pos..<pos+n); pos += n; while d.count > 1 && d.first == 0 { d.removeFirst() }; return d }
        let n = integer(), e = integer(), now = Date().timeIntervalSince1970
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "rsa", "kty": "RSA", "alg": "RS256", "n": b64(n), "e": b64(e)]]])
        let content = b64(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "rsa"])) + "." + b64(try JSONSerialization.data(withJSONObject: ["iss": ChatGPTIDTokenVerifier.issuer, "aud": "oaiapp_A", "sub": "rsa-sub", "nonce": "nonce", "iat": now, "exp": now + 100]))
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(content.utf8) as CFData, nil)) as Data
        XCTAssertEqual(try ChatGPTIDTokenVerifier.verify(content + "." + b64(signature), jwks: jwks, clientID: "oaiapp_A", nonce: "nonce").subject, "rsa-sub")
    }
    func testCodeIsSingleUseCancelledExpiredAndBadStateDoNotExchange() async throws {
        let http = OAuthFixture(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http), id = UUID()
        let key = try await login(manager, http, profile: id)
        let grant = try await manager.access(profileID: id); XCTAssertEqual(grant.account, key); XCTAssertFalse(grant.description.contains(grant.token))
        let p = try await manager.begin(profileID: id, redirect: URL(string: "http://127.0.0.1:3456/auth/callback")!)
        await manager.cancel(p.id)
        do { try await manager.finish(p.id, callback: callback(p)); XCTFail() } catch {}
        let expired = try await manager.begin(profileID: id, redirect: p.attempt.redirect, now: Date().addingTimeInterval(-601))
        do { try await manager.finish(expired.id, callback: callback(expired)); XCTFail() } catch {}
        let wrong = try await manager.begin(profileID: id, redirect: p.attempt.redirect)
        do { try await manager.finish(wrong.id, callback: URL(string: p.attempt.redirect.absoluteString + "?state=wrong&code=x&client_id=oaiapp_A")!); XCTFail() } catch {}
        let exchanges = await http.exchangeCount; XCTAssertEqual(exchanges, 1)
        do { try await manager.finish(wrong.id, callback: callback(wrong)); XCTFail() } catch {}
    }
    func testMissingPlanScopesRetainsIdentityButNeverProvidesAccess() async throws {
        let http = OAuthFixture(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http), id = UUID()
        _ = try await login(manager, http, profile: id, scope: "openid profile email")
        let summaries = try await manager.summaries(); XCTAssertEqual(summaries.first?.status, .identityOnly)
        do { _ = try await manager.access(profileID: id); XCTFail() } catch { XCTAssertEqual(error as? ChatGPTAuthError, .missingPermission) }
    }
    func testAccountAndWorkspaceIsolationAndReturningIdentityCannotChange() async throws {
        let http = OAuthFixture(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http), a = UUID(), b = UUID()
        let keyA = try await login(manager, http, profile: a), grantA = try await manager.access(profileID: a)
        let keyB = try await login(manager, http, profile: b, client: "oaiapp_B", subject: "subject-B")
        let all = try await manager.summaries(); XCTAssertNotEqual(keyA, keyB); XCTAssertEqual(all.count, 2)
        do { _ = try await manager.access(profileID: b, expectedAccount: keyA); XCTFail() } catch {}
        let p = try await manager.begin(profileID: a, redirect: URL(string: "http://127.0.0.1:3456/auth/callback")!)
        await http.setup(nonce: p.attempt.nonce, subject: "different")
        do { try await manager.finish(p.id, callback: callback(p)); XCTFail() } catch {}
        let unchanged = try await manager.access(profileID: a); XCTAssertEqual(unchanged.token, grantA.token)
        try await manager.select(keyB, profileID: a)
        do { try await manager.requireCurrent(grantA, profileID: a); XCTFail() } catch {}
    }
    func testConcurrentRefreshRotatesOnceAndLogoutClearsButRetainsRegistration() async throws {
        let http = OAuthFixture(), memory = ChatGPTMemoryStorage(), id = UUID()
        let manager = ChatGPTAccountManager(storage: memory, http: http)
        _ = try await login(manager, http, profile: id); let old = try await manager.access(profileID: id)
        await http.delay()
        async let a = manager.access(profileID: id, now: Date().addingTimeInterval(3550))
        async let b = manager.access(profileID: id, now: Date().addingTimeInterval(3550))
        let (one, two) = try await (a, b); XCTAssertEqual(one.token, two.token); XCTAssertNotEqual(one.token, old.token)
        let refreshes = await http.refreshCount; XCTAssertEqual(refreshes, 1)
        do { try await manager.requireCurrent(old, profileID: id); XCTFail() } catch {}
        let confirmed = try await manager.disconnect(profileID: id), revokes = await http.revokeCount; XCTAssertTrue(confirmed); XCTAssertEqual(revokes, 1)
        let archived = String(decoding: memory.load()!, as: UTF8.self)
        XCTAssertFalse(archived.contains(one.token)); XCTAssertFalse(archived.contains("refresh-subject")); XCTAssertTrue(archived.contains("oaiapp_A"))
        do { _ = try await manager.access(profileID: id); XCTFail() } catch {}
        let returning = try await manager.begin(profileID: id, redirect: URL(string: "http://127.0.0.1:3456/auth/callback")!)
        XCTAssertEqual(returning.attempt.clientID, "oaiapp_A")
    }
    func testAtomicRotationStorageFailureStopsWithoutReusingRefreshToken() async throws {
        let http = OAuthFixture(), storage = FaultingOAuthStorage(), id = UUID()
        let manager = ChatGPTAccountManager(storage: storage, http: http)
        _ = try await login(manager, http, profile: id)
        let before = storage.load(); storage.fail()
        do { _ = try await manager.access(profileID: id, now: Date().addingTimeInterval(3550)); XCTFail() } catch { XCTAssertEqual(error as? ChatGPTAuthError, .refreshFailed) }
        XCTAssertEqual(storage.load(), before)
        do { _ = try await manager.access(profileID: id, now: Date().addingTimeInterval(3550)); XCTFail() } catch {}
        let count = await http.refreshCount; XCTAssertEqual(count, 1)
    }
    func testLogoutFencesInFlightAuthorizationAndAccountBounce() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let key = try await login(manager, http, profile: id), old = try await manager.access(profileID: id)
        try await manager.select(key, profileID: id)
        do { try await manager.requireCurrent(old, profileID: id); XCTFail() } catch {}
        let p = try await manager.begin(profileID: id, redirect: URL(string: "http://127.0.0.1:3456/auth/callback")!)
        await http.setup(nonce: p.attempt.nonce); await http.delayAuthorization()
        let finishing = Task { try await manager.finish(p.id, callback: self.callback(p)) }
        try await Task.sleep(for: .milliseconds(20)); _ = try await manager.disconnect(profileID: id)
        do { try await finishing.value; XCTFail() } catch {}
        do { _ = try await manager.access(profileID: id); XCTFail() } catch {}
    }
    func testTemporaryRefreshFailurePreservesCredentialsAndInvalidJWTNeverActivates() async throws {
        let http = OAuthFixture(), memory = ChatGPTMemoryStorage(), id = UUID()
        let m = ChatGPTAccountManager(storage: memory, http: http)
        _ = try await login(m, http, profile: id); let old = try await m.access(profileID: id)
        await http.fail("temporarily_unavailable")
        do { _ = try await m.access(profileID: id, now: Date().addingTimeInterval(3550)); XCTFail() } catch { XCTAssertEqual(error as? ChatGPTAuthError, .refreshFailed) }
        XCTAssertTrue(String(decoding: memory.load()!, as: UTF8.self).contains(old.token))
        await http.fail(nil); await http.setInvalid()
        let newProfile = UUID(), p = try await m.begin(profileID: newProfile, redirect: URL(string: "http://127.0.0.1:3456/auth/callback")!)
        await http.setup(nonce: p.attempt.nonce)
        do { try await m.finish(p.id, callback: callback(p)); XCTFail() } catch {}
        let selected = try await m.selectedAccount(profileID: newProfile); XCTAssertNil(selected)
    }
    func testRevokedRefreshClearsSecretsWithoutChangingBilling() async throws {
        let http = OAuthFixture(), memory = ChatGPTMemoryStorage(), id = UUID()
        let m = ChatGPTAccountManager(storage: memory, http: http)
        _ = try await login(m, http, profile: id); let old = try await m.access(profileID: id)
        await http.fail("refresh_token_reused")
        do { _ = try await m.access(profileID: id, now: Date().addingTimeInterval(3550)); XCTFail() } catch { XCTAssertEqual(error as? ChatGPTAuthError, .revoked) }
        XCTAssertFalse(String(decoding: memory.load()!, as: UTF8.self).contains(old.token))
    }
}

private final class SubscriptionWireFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var contentType: String? = "text/event-stream"
    static var body = Data(), status = 200, blocked = false, requests: [URLRequest] = [], stopped = 0
    static func reset(_ value: Data, status: Int = 200, blocked: Bool = false, contentType: String? = "text/event-stream") { lock.withLock { body = value; self.status = status; self.blocked = blocked; self.contentType = contentType; requests = []; stopped = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
            captured.httpBody = data
        }
        let v = Self.lock.withLock { Self.requests.append(captured); return (Self.body, Self.status, Self.blocked, Self.contentType) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: v.1, httpVersion: "HTTP/1.1", headerFields: v.3.map { ["Content-Type": $0] } ?? [:])!, cacheStoragePolicy: .notAllowed)
        if !v.0.isEmpty { client?.urlProtocol(self, didLoad: v.0) }
        if !v.2 { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.lock.withLock { Self.stopped += 1 } }
}
extension ChatGPTOAuthTests {
    private func responseFrames(_ output: [[String: Any]], status: String = "completed", namespace: String = "actell", unknownEvents: Bool = false) throws -> Data {
        var events: [[String: Any]] = [["type": "response.created", "response": ["id": "resp-fixture", "status": "in_progress"]]]
        for (index, item) in output.enumerated() {
            events.append(["type": "response.output_item.added", "output_index": index, "item": item])
            if unknownEvents {
                events.append(["type": "response.metadata", "metadata": ["private": "SECRET"]])
                events.append(["type": "response.future.extension", "private": "SECRET", "item": ["type": "function_call", "namespace": "SECRET", "name": "SECRET"]])
            }
            events.append(["type": "response.output_item.done", "output_index": index, "item": item])
        }
        events.append(["type": "response." + status, "response": ["id": "resp-fixture", "model": "fixture", "status": status, "output": output]])
        var data = Data()
        for (seq, var event) in events.enumerated() { event["sequence_number"] = seq; data.append(Data("data: ".utf8)); data.append(try JSONSerialization.data(withJSONObject: event)); data.append(Data("\n\n".utf8)) }
        return data
    }
    private func emptyTerminalFrames(_ output: [[String: Any]], variant: String = "valid", unknownEvents: Bool = false) throws -> Data {
        let raw = String(decoding: try responseFrames(output, status: variant == "failed" ? "failed" : "completed", unknownEvents: unknownEvents), as: UTF8.self)
        var frames: [String] = []
        for frame in raw.components(separatedBy: "\n\n") where !frame.isEmpty {
            var event = try JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).utf8)) as! [String: Any]
            let type = event["type"] as? String ?? ""
            if variant == "missingDone", type == "response.output_item.done" { continue }
            if variant == "gap", let index = event["output_index"] as? Int { event["output_index"] = index + 1 }
            if type == "response.completed" || type == "response.failed" {
                var response = event["response"] as! [String: Any]
                response["output"] = []
                if variant == "wrongID" { response["id"] = "other-response" }
                if variant == "error" { response["error"] = ["code": "invalid_request_error"] }
                if variant == "conflict" {
                    var altered = output[0]; altered["arguments"] = "{\"changed\":true}"; response["output"] = [altered]
                }
                event["response"] = response
            }
            frames.append("data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))
        }
        return Data((frames.joined(separator: "\n\n") + "\n\n").utf8)
    }
    func testSubscriptionEmptyCompletedSnapshotUsesOnlyValidatedDoneItems() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
        let message: [String: Any] = ["type": "message", "id": "msg", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": "已完成", "annotations": []]]]
        let reasoning: [String: Any] = ["type": "reasoning", "id": "reason", "summary": [], "encrypted_content": "opaque-fixture"]
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}"]
        SubscriptionWireFixture.reset(try emptyTerminalFrames([reasoning, message, tool]), contentType: nil)
        let result = try await p.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool]))
        XCTAssertEqual(result.text, "已完成")
        XCTAssertEqual(result.output.count, 3)
        XCTAssertEqual(result.toolCalls.map(\.name), ["screenshot"])
        XCTAssertEqual(result.toolCalls.first?.status, .completed)
        XCTAssertNil(p.lastDiagnostic)
        XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
    }
    func testSubscriptionEmptySnapshotDoesNotRepairUnsafeOrConflictingStreams() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}", "status": "completed"]
        for variant in ["missingDone", "gap", "wrongID", "error", "failed", "conflict", "incomplete", "duplicateCall", "wrongNamespace"] {
            var items = [tool]
            if variant == "incomplete" { items[0]["status"] = "incomplete" }
            if variant == "wrongNamespace" { items[0]["namespace"] = "wrong" }
            if variant == "duplicateCall" { var other = tool; other["id"] = "other-item"; items.append(other) }
            let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
            SubscriptionWireFixture.reset(try emptyTerminalFrames(items, variant: variant))
            do { _ = try await p.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool])); XCTFail("Unsafe stream accepted: " + variant) } catch {}
            XCTAssertNotNil(p.lastDiagnostic, variant)
            XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
        }
    }
    private var localTool: ModelToolDefinition { .init(name: "screenshot", description: "local", parameters: ["type": "object", "properties": [:]]) }
    func testSubscriptionUnknownEventsPreserveReplyAndToolsUntilValidatedCompletion() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let message: [String: Any] = ["type": "message", "id": "msg", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": "verified reply", "annotations": []]]]
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}", "status": "completed"]
        for emptySnapshot in [false, true] {
            let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
            SubscriptionWireFixture.reset(try emptySnapshot
                ? emptyTerminalFrames([message, tool], unknownEvents: true)
                : responseFrames([message, tool], unknownEvents: true), contentType: nil)
            var terminalCount = 0
            for try await event in p.stream(.init(model: "fixture", messages: [.user("task")], tools: [localTool])) {
                switch event {
                case .toolCall: XCTFail("Tool released before validated completion")
                case .terminal(let response):
                    terminalCount += 1
                    XCTAssertEqual(response.text, "verified reply")
                    XCTAssertEqual(response.toolCalls.map(\.name), ["screenshot"])
                    XCTAssertEqual(response.streamEvents.count, 4)
                    XCTAssertTrue(response.streamEvents.allSatisfy { $0.responseID == response.id })
                    let retained = try XCTUnwrap(response.streamEvents.first { $0.type == "response.future.extension" })
                    let business = try XCTUnwrap(JSONSerialization.jsonObject(with: retained.payloadJSON) as? [String: Any])
                    XCTAssertEqual(business["private"] as? String, "SECRET") // Synthetic business value, not a credential key.
                    try ResponsesReducer.requireExecutable(response)
                default: break
                }
            }
            XCTAssertEqual(terminalCount, 1)
            XCTAssertNil(p.safeFailureMessage)
            XCTAssertNil(p.lastDiagnostic)
            XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
        }
    }
    func testSubscriptionUnknownEventsNeverReleaseUnverifiedToolsOrRetry() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}", "status": "completed"]
        var streams = try ["missingDone", "failed", "wrongID", "conflict", "error", "gap"].map {
            try emptyTerminalFrames([tool], variant: $0, unknownEvents: true)
        }
        streams.append(try responseFrames([tool], status: "incomplete", unknownEvents: true))
        let frames = String(decoding: try responseFrames([tool], unknownEvents: true), as: UTF8.self)
        streams.append(Data(frames.components(separatedBy: "\n\n").filter { !$0.contains("response.completed") }.joined(separator: "\n\n").utf8))
        for (index, data) in streams.enumerated() {
            let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
            SubscriptionWireFixture.reset(data)
            do {
                for try await event in p.stream(.init(model: "fixture", messages: [.user("task")], tools: [localTool])) {
                    switch event {
                    case .terminal, .toolCall: XCTFail("Unverified tools released: \(index)")
                    default: break
                    }
                }
                XCTFail("Unverified stream accepted: \(index)")
            } catch {}
            XCTAssertNotNil(p.safeFailureMessage)
            XCTAssertNotNil(p.lastDiagnostic)
            if index == streams.count - 1 {
                XCTAssertEqual(p.safeFailureMessage, String(localized: "The ChatGPT reply could not be fully verified. This turn stopped. Review the reply before trying again."))
            }
            XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
        }
    }
    func testSubscriptionUnsupportedOutputReportsVerificationFailureWithoutServerContent() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
        SubscriptionWireFixture.reset(try responseFrames([["type": "computer_call", "id": "SECRET", "arguments": "SECRET"]], unknownEvents: true))
        do { _ = try await p.complete(.init(model: "fixture", messages: [.user("task")])); XCTFail("Unsupported output accepted") } catch {}
        let message = await MainActor.run { AgentViewModel.runFailure(AgentError.providerError("SECRET"), provider: p) }
        XCTAssertEqual(message, String(localized: "The ChatGPT reply could not be fully verified. This turn stopped. Review the reply before trying again."))
        XCTAssertFalse(message.contains("SECRET"))
        XCTAssertTrue(p.lastDiagnostic?.contains("unsupportedCapability") == true)
        XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
    }
    private func subscription(manager: ChatGPTAccountManager, profileID: UUID, account: String) throws -> ChatGPTSubscriptionProvider {
        var profile = ProviderProfile(id: profileID); profile.protocolKind = .chatGPTSubscription; profile.chatGPTAccountReference = account
        var metadata = DiscoveredModel(id: "fixture", name: "fixture"); metadata.reasoningEfforts = ["low", "high"]
        profile.catalog = .init(endpoint: try profile.catalogEndpoint(), fetchedAt: Date(), models: [metadata])
        var params = ModelParameters(); params.reasoningEffort = "high"; profile.modelParameters = ["fixture": params]
        return try ChatGPTSubscriptionProvider(profile: profile, model: "fixture", account: account, runID: UUID(), manager: manager, transport: ResponsesTransport(protocolClasses: [SubscriptionWireFixture.self]))
    }
    func testSubscriptionCompletedToolWithOptionalStatus() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let provider = try subscription(manager: manager, profileID: id, account: account); defer { provider.cancel() }
        // Official ResponseFunctionToolCall.status is optional. Both item.done
        // and response.completed still establish completion before tool execution.
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}"]
        SubscriptionWireFixture.reset(try responseFrames([tool]))
        let response = try await provider.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool]))
        XCTAssertEqual(response.toolCalls.map(\.name), ["screenshot"])
        XCTAssertEqual(response.toolCalls.first?.status, .completed)
    }
    func testSubscriptionOptionalStatusNeverOverridesIncompleteOrMissingDone() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let base: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}"]
        for status in ["in_progress", "incomplete", "unknown"] {
            var tool = base; tool["status"] = status
            let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
            SubscriptionWireFixture.reset(try responseFrames([tool]))
            do { _ = try await p.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool])); XCTFail("Unfinished tool accepted") } catch {}
            let expected = status == "unknown" ? "DecodingError" : "Function item is not completed"
            XCTAssertTrue(p.lastDiagnostic?.contains(expected) == true, p.lastDiagnostic ?? "no diagnostic")
            XCTAssertTrue(p.lastDiagnostic?.contains("stage=event.reduce") == true)
        }
        let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
        let frames = String(decoding: try responseFrames([base]), as: UTF8.self).components(separatedBy: "\n\n").filter { !$0.contains("response.output_item.done") }.joined(separator: "\n\n")
        SubscriptionWireFixture.reset(Data((frames + "\n\n").utf8))
        do { _ = try await p.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool])); XCTFail("Missing item.done accepted") } catch {}
        XCTAssertTrue(p.lastDiagnostic?.contains("Completed snapshot has missing/conflicting items") == true)
    }
    func testSubscriptionNonSSEReportsHTTPTypeAndBodyShapeWithoutExecuting() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        for (type, body, shape) in [
            ("application/json", #"{"error":{"code":"unsupported_parameter","message":"SECRET_BODY"}}"#, "json-error"),
            ("text/html", "<html>SECRET_PROXY</html>", "non-json"),
            (nil, "", "empty"),
            (nil, "<html>SECRET_PROXY</html>", "non-json"),
            (nil, #"{"error":{"code":"unsupported_parameter","message":"SECRET_BODY"}}"#, "json-error"),
            ("application/json", #"{"type":"response","output":[],"id":"SECRET_ID"}"#, "json-response")
        ] as [(String?, String, String)] {
            let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
            SubscriptionWireFixture.reset(Data(body.utf8), contentType: type)
            do { _ = try await p.complete(.init(model: "fixture", messages: [.user("task")])); XCTFail("Non-SSE response accepted") } catch {}
            let line = p.lastDiagnostic ?? ""
            XCTAssertTrue(line.contains("httpStatus=200"), line)
            XCTAssertTrue(line.contains("contentType=" + (type ?? "missing")), line)
            XCTAssertTrue(line.contains("bodyShape=" + shape), line)
            XCTAssertTrue(p.safeFailureMessage?.contains("未返回 SSE 流") == true)
            XCTAssertFalse(line.contains("SECRET"))
            XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
        }
    }
    func testSubscriptionMissingContentTypeAcceptsValidatedSSEWithoutLosingProbe() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}"]
        SubscriptionWireFixture.reset(try responseFrames([tool]), contentType: nil)
        let result = try await p.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool]))
        XCTAssertEqual(result.toolCalls.map(\.name), ["screenshot"])
        XCTAssertEqual(result.toolCalls.first?.status, .completed)
        XCTAssertNil(p.lastDiagnostic)
        XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
    }
    func testSubscriptionMissingContentTypeStillRejectsFailedOrTruncatedSSE() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}", "status": "completed"]
        for data in [try responseFrames([tool], status: "failed"), try responseFrames([tool], status: "incomplete"), Data("data: {\"type\":\"response.created\"}".utf8)] {
            let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
            SubscriptionWireFixture.reset(data, contentType: nil)
            do { _ = try await p.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool])); XCTFail("Unfinished SSE accepted") } catch {}
            XCTAssertNotNil(p.lastDiagnostic)
            XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
        }
    }
    func testSubscriptionSSEMediaTypeAcceptsCaseAndParameters() async throws {
        let lowerCase = HTTPURLResponse(url: ChatGPTSubscriptionPolicy.resource, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["content-type": "text/event-stream; charset=utf-8"])!
        XCTAssertEqual(LLMUnexpectedResponse.mediaType(lowerCase), "text/event-stream")
        XCTAssertEqual(lowerCase.mimeType, "text/event-stream")
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
        let message: [String: Any] = ["type": "message", "id": "msg", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": "ok", "annotations": []]]]
        SubscriptionWireFixture.reset(try responseFrames([message]), contentType: "Text/Event-Stream; charset=utf-8")
        let result = try await p.complete(.init(model: "fixture", messages: [.user("task")]))
        XCTAssertEqual(result.text, "ok")
    }
    func testGeneralLLMDiagnosticsKeepCoreErrorKindsWithoutPayloads() {
        let attempt = UUID()
        for (error, expected) in [
            (ModelError.httpError(400, Data("SECRET_BODY".utf8)) as Error, "httpError(400)"),
            (AppError.invalid("工具参数不完整，已阻止执行") as Error, "工具参数不完整，已阻止执行"),
            (URLError(.timedOut) as Error, "URLError code=-1001"),
            (AgentError.toolExecutionFailed(name: "SECRET_TOOL", message: "SECRET_ARGUMENTS") as Error, "AgentError.toolExecutionFailed"),
            (AgentError.providerError("SECRET_KEY") as Error, "AgentError.providerError"),
            (AgentError.providerRefused(summary: "SECRET", details: "SECRET") as Error, "providerFailure wrapper=providerRefused"),
            (ModelStreamStalled(seconds: 15) as Error, "ModelStreamStalled seconds=15")
        ] {
            let line = LLMDiagnostics.failure(error, attempt: attempt, stage: "agent.run", shape: "event=none")
            XCTAssertTrue(line.hasPrefix("[LLM]"))
            XCTAssertTrue(line.contains(expected), line)
            XCTAssertFalse(line.contains("SECRET"))
        }
        let shape = LLMDiagnostics.eventShape(#"{"choices":[{"delta":{"content":"SECRET","tool_calls":[{"arguments":"SECRET"}]},"finish_reason":"tool_calls"}]}"#)
        XCTAssertTrue(shape.contains("wire=chatCompletions choices=1"))
        XCTAssertTrue(shape.contains("toolFragments=1"))
        XCTAssertTrue(shape.contains("finishReason=tool_calls"))
        XCTAssertFalse(shape.contains("SECRET"))
    }
    func testRetainedEventDiagnosticsExposeOnlyStructureAndFingerprint() throws {
        for type in ["response.metadata", "response.SECRET.extension"] {
            let object: [String: Any] = ["type": type, "sequence_number": 68, "metadata": ["content": "SECRET", "token": "SECRET"], "item_id": "SECRET", "arguments": "SECRET"]
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let line = LLMDiagnostics.retainedEvent(attempt: UUID(), shape: LLMDiagnostics.eventShape(payload))
            XCTAssertTrue(line.contains("notice=UnknownEvent action=retain"))
            XCTAssertTrue(line.contains(type == "response.metadata" ? "event=response.metadata" : "event=unknown#"))
            XCTAssertTrue(line.contains("sequence_number=68"))
            XCTAssertFalse(line.contains("SECRET"))
            XCTAssertFalse(line.contains("arguments"))
        }
    }
    func testVerboseDiagnosticsRequireExplicitOptIn() {
        #if ACTELL_LLM_VERBOSE_LOGS
        XCTAssertTrue(LLMDiagnostics.verboseEnabled)
        XCTAssertTrue(LLMDiagnostics.verboseConfiguration(environmentValue: nil))
        #else
        for value: String? in [nil, "", "0", "true", "yes", " 1", "1 "] {
            XCTAssertFalse(LLMDiagnostics.verboseConfiguration(environmentValue: value))
        }
        #endif
        XCTAssertTrue(LLMDiagnostics.verboseConfiguration(environmentValue: "1"))
        XCTAssertNil(LLMDiagnostics.eventDetail("invalid SECRET JSON", attempt: UUID(), enabled: false))
        XCTAssertNil(LLMDiagnostics.eventDetail(String(repeating: "SECRET", count: 50_000), attempt: UUID(), enabled: false))
    }
    func testRawEventArchivePreservesJSONValuesAndRedactsOnlyCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = LLMRawEventArchive(directory: root)
        XCTAssertNil(try archive.append("invalid JSON", attempt: UUID(), enabled: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let attempt = UUID()
        let payload = #"{"type":"response.metadata","response_id":"response-original","sequence_number":19,"metadata":{"unregistered_business_key":{"is_blocked":false,"results":[{"decision":"allow"}],"large_id":9007199254740993,"token_usage":17,"Authorization":"Bearer SECRET_ONE","nested":[{"refresh_token":"SECRET_TWO"}],"description":"Bearer SECRET_THREE","url":"https://example.invalid/?api_key=SECRET_FOUR&mode=keep"}}}"#
        XCTAssertEqual(try archive.append(payload, attempt: attempt, enabled: true), 1)
        let data = try Data(contentsOf: archive.file)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let event = try XCTUnwrap((stored["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["attempt"] as? String, attempt.uuidString)
        XCTAssertEqual(event["source"] as? String, "sse.before_normalization")
        let original = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(original["response_id"] as? String, "response-original")
        let business = try XCTUnwrap((original["metadata"] as? [String: Any])?["unregistered_business_key"] as? [String: Any])
        XCTAssertEqual(business["is_blocked"] as? Bool, false)
        XCTAssertEqual((business["large_id"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)
        XCTAssertEqual(business["token_usage"] as? Int, 17)
        XCTAssertEqual(business["Authorization"] as? String, "[REDACTED]")
        XCTAssertEqual((business["results"] as? [[String: Any]])?.first?["decision"] as? String, "allow")
        XCTAssertTrue((business["url"] as? String)?.contains("mode=keep") == true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET_"))
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testRawEventArchiveRotationConcurrencyAndSizeLimits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = LLMRawEventArchive(directory: root, capacity: 2, maximumBytes: 2048)
        for i in 0..<3 { try archive.append("{\"sequence_number\":\(i),\"text\":\"\(String(repeating: "x", count: 600))\"}", attempt: UUID(), enabled: true) }
        let data = try Data(contentsOf: archive.file)
        XCTAssertLessThanOrEqual(data.count, 2048)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(events.count, 2)
        XCTAssertEqual((events.last?["payload"] as? [String: Any])?["sequence_number"] as? Int, 2)
        XCTAssertThrowsError(try archive.append(String(repeating: "x", count: 256 * 1024 + 1), attempt: UUID(), enabled: true))
        XCTAssertThrowsError(try archive.append("invalid JSON", attempt: UUID(), enabled: true))
        let byteBounded = LLMRawEventArchive(directory: root.appendingPathComponent("bytes"), capacity: 16, maximumBytes: 1024)
        for _ in 0..<3 { try byteBounded.append("{\"text\":\"\(String(repeating: "x", count: 600))\"}", attempt: UUID(), enabled: true) }
        let bounded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: byteBounded.file)) as? [String: Any])
        XCTAssertEqual((bounded["events"] as? [Any])?.count, 1)
        let concurrent = LLMRawEventArchive(directory: root.appendingPathComponent("concurrent"), capacity: 16)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 { group.addTask { _ = try concurrent.append("{\"sequence_number\":\(i)}", attempt: UUID(), enabled: true) } }
            try await group.waitForAll()
        }
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: concurrent.file)) as? [String: Any])
        XCTAssertEqual((all["events"] as? [Any])?.count, 8)
    }
    func testCredentialRedactionHandlesEncodedObjectsAndPreservesBusinessFields() throws {
        let unchanged = " {\"z\":2, \"a\":false} "
        XCTAssertEqual(try EventCredentialRedactor.redact(unchanged) as? String, unchanged)
        let source: [String: Any] = ["payload": #"{"Client-Secret":"SECRET_A","is_blocked":true,"token_usage":21}"#, "url": "https://user:SECRET_B@example.invalid/path", "auth": "Basic SECRET_C", "api": "sk-abcdefghijklmnopqrstuvwx"]
        let result = try XCTUnwrap(EventCredentialRedactor.redact(source) as? [String: Any])
        let encoded = try XCTUnwrap(result["payload"] as? String)
        let nested = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(nested["is_blocked"] as? Bool, true)
        XCTAssertEqual(nested["token_usage"] as? Int, 21)
        XCTAssertEqual(nested["Client-Secret"] as? String, "[REDACTED]")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET_"))
        XCTAssertFalse(text.contains("abcdefghijklmnopqrstuvwx"))
    }
    func testVerboseEventsPreserveActualFieldsAndValuesWithoutHashSummaries() throws {
        let attempt = UUID()
        let payload = #"{"type":"response.custom_business","sequence_number":68,"metadata":{"unregistered_business_key":{"is_blocked":false,"results":[{"decision":"allow"}],"large_id":9007199254740993,"token_usage":17,"Authorization":"Bearer SECRET_ONE","nested":[{"refresh_token":"SECRET_TWO"}]}},"item":{"name":"real_tool","arguments":"{\"value\":42}"},"content":[null,true,"模型正文"]}"#
        let line = try XCTUnwrap(LLMDiagnostics.eventDetail(payload, attempt: attempt, enabled: true))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["attempt"] as? String, attempt.uuidString)
        XCTAssertEqual(record["stage"] as? String, "event.raw")
        XCTAssertEqual(record["source"] as? String, "sse.before_normalization")
        let event = try XCTUnwrap(record["payload"] as? [String: Any])
        XCTAssertEqual(event["type"] as? String, "response.custom_business")
        XCTAssertEqual(event["sequence_number"] as? Int, 68)
        let business = try XCTUnwrap((event["metadata"] as? [String: Any])?["unregistered_business_key"] as? [String: Any])
        XCTAssertEqual(business["is_blocked"] as? Bool, false)
        XCTAssertEqual((business["large_id"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)
        XCTAssertEqual((business["results"] as? [[String: Any]])?.first?["decision"] as? String, "allow")
        XCTAssertEqual(business["Authorization"] as? String, "[REDACTED]")
        XCTAssertTrue(line.contains("real_tool"))
        XCTAssertTrue(line.contains("模型正文"))
        XCTAssertFalse(line.contains("SECRET_"))
        XCTAssertFalse(line.contains("unknown#"))
        XCTAssertNil(record["structure"])
        XCTAssertFalse(line.contains("\n"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = LLMRawEventArchive(directory: root)
        try archive.append(payload, attempt: attempt, enabled: true)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archive.file)) as? [String: Any])
        let archived = try XCTUnwrap((saved["events"] as? [[String: Any]])?.first?["payload"])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: event, options: .sortedKeys), try JSONSerialization.data(withJSONObject: archived, options: .sortedKeys))
    }
    func testDiagnosticRecordsAreTypedJSONAndPreserveMultiwordReasons() throws {
        let legacy = LLMDiagnostics.failure(ModelError.protocolViolation("Completed response contains failure details"), attempt: UUID(), stage: "terminal.validate", shape: "event=response.completed sequence_number=11 hasServerError=false")
        let line = LLMDiagnostics.jsonRecord(legacy, level: "error")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["level"] as? String, "error")
        XCTAssertEqual(record["stage"] as? String, "terminal.validate")
        XCTAssertEqual(record["error"] as? String, "ModelError.protocolViolation")
        XCTAssertEqual(record["reason"] as? String, "Completed response contains failure details")
        XCTAssertEqual(record["sequence_number"] as? Int, 11)
        XCTAssertEqual(record["hasServerError"] as? Bool, false)
        let warning = LLMDiagnostics.jsonRecord(LLMDiagnostics.retainedEvent(attempt: UUID(), shape: "event=response.metadata sequence_number=7"), level: "warning")
        let ignored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(warning.utf8)) as? [String: Any])
        XCTAssertEqual(ignored["event"] as? String, "response.metadata")
        XCTAssertEqual(ignored["action"] as? String, "retain")
        XCTAssertEqual(ignored["level"] as? String, "warning")
    }
    func testVerboseRawEventsKeepWideAndNestedValuesAndFailClosedForUnsafeInput() throws {
        var nested: [String: Any] = ["text": "business value"]
        for _ in 0..<12 { nested = ["metadata": nested] }
        let wide = Dictionary(uniqueKeysWithValues: (0..<200).map { ("business_key_\($0)", "value_\($0)") })
        for object: [String: Any] in [nested, ["metadata": wide], ["output": Array(repeating: wide, count: 4)]] {
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let line = try XCTUnwrap(LLMDiagnostics.eventDetail(payload, attempt: UUID(), enabled: true))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(record["payload"]), options: .sortedKeys), try JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
            XCTAssertNil(record["truncated"])
            XCTAssertFalse(line.contains("unknown#"))
        }
        var tooDeep: [String: Any] = ["password": "SECRET"]
        for _ in 0..<50 { tooDeep = ["child": tooDeep] }
        let deepPayload = String(decoding: try JSONSerialization.data(withJSONObject: tooDeep), as: UTF8.self)
        for (payload, expected) in [(String(repeating: "SECRET", count: 50_000), "EventSizeLimit"), ("SECRET malformed", "EventJSONUnavailable"), (deepPayload, "EventJSONUnavailable")] {
            let line = try XCTUnwrap(LLMDiagnostics.eventDetail(payload, attempt: UUID(), enabled: true))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(record["error"] as? String, expected)
            XCTAssertNil(record["payload"])
            XCTAssertFalse(line.contains("SECRET"))
        }
        let done = try XCTUnwrap(LLMDiagnostics.eventDetail("[DONE]", attempt: UUID(), enabled: true))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(done.utf8)) as? [String: Any])?["payload"] as? String, "[DONE]")
    }
    func testLLMNetworkDiagnosticsExposeBoundedTLSCodesWithoutSecrets() {
        let ssl = NSError(domain: NSOSStatusErrorDomain, code: -9846,
                          userInfo: [NSLocalizedDescriptionKey: "SECRET_TOKEN https://SECRET_HOST"])
        let network = URLError(.networkConnectionLost, userInfo: [NSUnderlyingErrorKey: ssl,
                                    NSURLErrorFailingURLStringErrorKey: "https://SECRET_HOST"])
        let line = LLMDiagnostics.failure(network, attempt: UUID(), stage: "stream.receive", shape: "event=none")
        XCTAssertTrue(line.contains("URLError code=-1005"))
        XCTAssertTrue(line.contains("tls=badRecordMac"))
        XCTAssertTrue(line.contains("cause1=NSOSStatusErrorDomain:-9846"))
        XCTAssertFalse(line.contains("SECRET"))

        var nested = NSError(domain: "SECRET_DOMAIN", code: -9846)
        for _ in 0..<8 { nested = NSError(domain: NSPOSIXErrorDomain, code: 54, userInfo: [NSUnderlyingErrorKey: nested]) }
        let bounded = LLMDiagnostics.failure(nested, attempt: UUID(), stage: "stream.receive", shape: "event=none")
        XCTAssertTrue(bounded.contains("cause3="))
        XCTAssertFalse(bounded.contains("cause4="))
        XCTAssertFalse(bounded.contains("tls="))
        let unknown = LLMDiagnostics.failure(NSError(domain: NSURLErrorDomain, code: -1200,
                         userInfo: [NSUnderlyingErrorKey: NSError(domain: "SECRET_DOMAIN", code: -9846)]),
                         attempt: UUID(), stage: "stream.receive", shape: "event=none")
        XCTAssertFalse(unknown.contains("SECRET"))
        XCTAssertFalse(unknown.contains("tls="))
        let decrypted = LLMDiagnostics.failure(NSError(domain: "kCFErrorDomainSSL", code: -9845),
                            attempt: UUID(), stage: "stream.receive", shape: "event=none")
        XCTAssertTrue(decrypted.contains("tls=decryptionFailed"))
    }
    func testSubscriptionConsoleDiagnosticReportsCoreFailureWithoutRawContent() {
        let payload = #"{"type":"response.output_item.done","sequence_number":3,"output_index":0,"item":{"type":"function_call","id":"SECRET_ID","call_id":"SECRET_CALL","namespace":"SECRET_NAMESPACE","name":"SECRET_NAME","arguments":"SECRET_ARGUMENTS","status":"incomplete"}}"#
        let shape = LLMDiagnostics.eventShape(payload)
        let diagnostic = LLMDiagnostics.failure(ModelError.protocolViolation("Function item is not completed"), attempt: UUID(), stage: "event.reduce", shape: shape)
        XCTAssertTrue(diagnostic.contains("reason=Function item is not completed"))
        XCTAssertTrue(diagnostic.contains("event=response.output_item.done"))
        XCTAssertTrue(diagnostic.contains("status=incomplete"))
        XCTAssertFalse(diagnostic.contains("SECRET"))
        let context = DecodingError.Context(codingPath: [], debugDescription: "SECRET_BODY")
        let decoding = LLMDiagnostics.failure(DecodingError.keyNotFound(AnyCodingKey("status"), context), attempt: UUID(), stage: "event.reduce", shape: shape)
        XCTAssertTrue(decoding.contains("keyNotFound path=status")); XCTAssertFalse(decoding.contains("SECRET"))
        let unknown = LLMDiagnostics.failure(ModelError.protocolViolation("SECRET_SERVER_TEXT"), attempt: UUID(), stage: "event.reduce", shape: shape)
        XCTAssertFalse(unknown.contains("SECRET")); XCTAssertTrue(unknown.contains("redacted#"))
    }
    func testSubscriptionWireToolTerminalAndLocalReplay() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let provider = try subscription(manager: manager, profileID: id, account: account); defer { provider.cancel() }
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}", "status": "completed"]
        SubscriptionWireFixture.reset(try responseFrames([tool]))
        let first = ModelRequest(model: "fixture", messages: [.system("instructions"), .user("task")], temperature: 1, maxTokens: 100, topP: 0.9, tools: [localTool])
        let response = try await provider.complete(first)
        XCTAssertEqual(response.toolCalls.map(\.name), ["screenshot"]); XCTAssertEqual(response.toolCalls.first?.extra?["namespace"], .string("actell"))
        let outgoing = SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests[0] }
        XCTAssertEqual(outgoing.url, ChatGPTSubscriptionPolicy.resource.appendingPathComponent("responses"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(outgoing.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true); XCTAssertEqual(body["instructions"] as? String, "instructions")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "high")
        for key in ["temperature", "top_p", "max_output_tokens", "previous_response_id", "conversation", "background", "metadata", "user"] { XCTAssertNil(body[key]) }
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "namespace")
        let message: [String: Any] = ["type": "message", "id": "msg", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "done", "annotations": []]]]
        SubscriptionWireFixture.reset(try responseFrames([message]))
        let second = ModelRequest(model: "fixture", messages: first.messages + [.assistant(toolCalls: response.toolCalls), .tool("image captured", toolCallId: "call-1")], tools: [localTool])
        let completed = try await provider.complete(second); XCTAssertEqual(completed.text, "done")
        let replayRequest = SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests[0] }
        let replay = try XCTUnwrap((JSONSerialization.jsonObject(with: XCTUnwrap(replayRequest.httpBody)) as? [String: Any])?["input"] as? [[String: Any]])
        XCTAssertTrue(replay.contains { $0["type"] as? String == "function_call" && $0["namespace"] as? String == "actell" })
        XCTAssertTrue(replay.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "call-1" })
    }
    @MainActor
    func testSubscriptionScreenshotJPEGAndUserPNGUseSeparateResponsesImageInput() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let provider = try subscription(manager: manager, profileID: id, account: account); defer { provider.cancel() }
        let frame = try await DemoBridge().screenshot()
        let jpeg = try XCTUnwrap(UIImage(data: frame.png)?.jpegData(compressionQuality: 0.7))
        let first = ModelRequest(model: "fixture", messages: [.user("inspect attached image then screenshot", images: [ModelImage(data: frame.png, mimeType: "image/png")])], tools: [localTool])
        let tool: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}", "status": "completed"]
        SubscriptionWireFixture.reset(try responseFrames([tool]))
        let response = try await provider.complete(first)
        let final: [String: Any] = ["type": "message", "id": "msg", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "image processed", "annotations": []]]]
        SubscriptionWireFixture.reset(try responseFrames([final]))
        let second = ModelRequest(model: "fixture", messages: first.messages + [.assistant(toolCalls: response.toolCalls), .init(role: .tool, content: "screenshot captured", images: [ModelImage(data: jpeg, mimeType: "image/jpeg")], toolCallId: "call-1")], tools: [localTool])
        let result = try await provider.complete(second)
        XCTAssertEqual(result.text, "image processed")
        let sent = SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests }
        XCTAssertEqual(sent.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first?.httpBody)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let imageMessages = input.filter { ($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "input_image" } == true }
        XCTAssertEqual(imageMessages.count, 2)
        XCTAssertTrue(imageMessages.allSatisfy { $0["role"] as? String == "user" })
        let urls = imageMessages.flatMap { ($0["content"] as? [[String: Any]] ?? []).compactMap { $0["image_url"] as? String } }
        XCTAssertTrue(urls.contains("data:image/png;base64," + frame.png.base64EncodedString()))
        XCTAssertTrue(urls.contains("data:image/jpeg;base64," + jpeg.base64EncodedString()))
        let receiptIndex = try XCTUnwrap(input.firstIndex { $0["type"] as? String == "function_call_output" })
        XCTAssertEqual(input[receiptIndex]["call_id"] as? String, "call-1")
        XCTAssertNil(input[receiptIndex]["content"])
        XCTAssertEqual(input[receiptIndex + 1]["role"] as? String, "user")
        XCTAssertNil(provider.lastDiagnostic)
    }
    func testFailedIncompleteInterruptedAndWrongNamespaceNeverExecuteTools() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let call: [String: Any] = ["type": "function_call", "id": "fc", "call_id": "call-1", "name": "screenshot", "namespace": "actell", "arguments": "{}", "status": "completed"]
        for status in ["failed", "incomplete"] {
            let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
            SubscriptionWireFixture.reset(try responseFrames([call], status: status))
            var terminal = false
            do { for try await event in p.stream(.init(model: "fixture", messages: [.user("task")], tools: [localTool])) { if case .toolCall = event { XCTFail("premature tool") }; if case .terminal = event { terminal = true } }; XCTFail() } catch {}
            XCTAssertFalse(terminal)
        }
        let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
        SubscriptionWireFixture.reset(Data("data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"resp-fixture\"}}\n\n".utf8))
        do { _ = try await p.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool])); XCTFail() } catch {}
        let q = try subscription(manager: manager, profileID: id, account: account); defer { q.cancel() }
        var wrong = call; wrong["namespace"] = "other"
        SubscriptionWireFixture.reset(try responseFrames([wrong]))
        do { _ = try await q.complete(.init(model: "fixture", messages: [.user("task")], tools: [localTool])); XCTFail() } catch {}
    }
    @MainActor func testSubscriptionAdmissionSurvivesRunnerWrappingWithoutLeakingServerText() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
        for status in [400, 401, 403, 404, 429, 503] {
            try await manager.report(.planAuthorized, account: account)
            SubscriptionWireFixture.reset(Data(#"{"error":{"message":"Bearer SECRET user content","code":"unsupported_parameter","param":"tools[0].SECRET"}}"#.utf8), status: status)
            // Reset only this in-memory mock account between admission cases.
            do { _ = try await p.complete(.init(model: "fixture", messages: [.user("task")])) ; XCTFail("Admission accepted") } catch {}
            let message = AgentViewModel.runFailure(AgentError.providerError("raw SECRET wrapper"), provider: p)
            XCTAssertTrue(message.contains("HTTP \(status)"), message)
            XCTAssertTrue(message.contains("unsupported_parameter"), message)
            XCTAssertTrue(message.contains("字段 tools"), message)
            XCTAssertFalse(message.contains("SECRET"), message)
            XCTAssertEqual(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.requests.count }, 1)
        }
        let unknown = ChatGPTAdmissionFailure(response: HTTPURLResponse(url: ChatGPTSubscriptionPolicy.resource, statusCode: 400, httpVersion: nil, headerFields: nil)!, body: Data(#"{"error":{"message":"SECRET","code":"SECRET","param":"SECRET"}}"#.utf8))
        XCTAssertFalse(unknown.localizedDescription.contains("SECRET"))
    }
    func testSubscriptionCancellationAndAdmissionDiagnosticsAreBoundedAndRedacted() async throws {
        let http = OAuthFixture(), id = UUID(), manager = ChatGPTAccountManager(storage: ChatGPTMemoryStorage(), http: http)
        let account = try await login(manager, http, profile: id)
        let p = try subscription(manager: manager, profileID: id, account: account); defer { p.cancel() }
        SubscriptionWireFixture.reset(Data(), blocked: true, contentType: nil)
        let task = Task { try await p.complete(.init(model: "fixture", messages: [.user("task")])) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        for _ in 0..<40 { if SubscriptionWireFixture.lock.withLock({ SubscriptionWireFixture.stopped > 0 }) { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(SubscriptionWireFixture.lock.withLock { SubscriptionWireFixture.stopped }, 0)
        let failure = ChatGPTAdmissionFailure(response: HTTPURLResponse(url: ChatGPTSubscriptionPolicy.resource, statusCode: 403, httpVersion: nil, headerFields: ["x-request-id": "req-fixture"])!, body: Data("{\"detail\":\"secret diagnostic\"}".utf8))
        XCTAssertEqual(failure.status, 403); XCTAssertEqual(failure.bodyShape, "detail"); XCTAssertEqual(failure.requestID, "req-fixture"); XCTAssertFalse(failure.localizedDescription.contains("secret diagnostic"))
    }
}
