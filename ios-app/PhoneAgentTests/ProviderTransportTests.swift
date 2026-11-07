import XCTest
import ProviderCore
import OpenAIAdapter
@testable import PhoneAgent

private final class WireFixtureState: @unchecked Sendable {
    let lock = NSLock()
    var body = Data(), status = 200, block = false, stopped = 0
    var requests: [URLRequest] = []
    func reset(body: Data = Data(), status: Int = 200, block: Bool = false) { lock.withLock { self.body = body; self.status = status; self.block = block; self.requests = []; self.stopped = 0 } }
}
private final class ProviderURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = WireFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let values = Self.fixture.lock.withLock { Self.fixture.requests.append(request); return (Self.fixture.body, Self.fixture.status, Self.fixture.block) }
        let response = HTTPURLResponse(url: request.url!, statusCode: values.1, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream", "Set-Cookie": "sensitive=fixture"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !values.0.isEmpty { client?.urlProtocol(self, didLoad: values.0) }
        if !values.2 { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.fixture.lock.withLock { Self.fixture.stopped += 1 } }
}
final class ProviderTransportTests: XCTestCase {
    func testFastSSEWithSlowConsumerPreservesEveryFrameWithoutRetry() async throws {
        let frames = (0..<160).map { "frame-\($0)" }
        ProviderURLProtocol.fixture.reset(body: Data(frames.map { "data: \($0)\n\n" }.joined().utf8))
        let transport = ResponsesTransport(protocolClasses: [ProviderURLProtocol.self])
        defer { transport.cancel() }
        var received: [String] = []
        for try await payload in transport.payloads(URLRequest(url: URL(string: "https://fixture.invalid")!)) {
            received.append(payload)
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(received, frames)
        XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
    }
    func testBurstToolArgumentsAreReleasedOnlyAfterSuccessfulTerminal() async throws {
        let arguments = "{\"text\":\"" + String(repeating: "x", count: 512) + "\"}"
        var frames: [String] = []
        for (index, character) in arguments.enumerated() {
            var tool: [String: Any] = ["index": 0, "function": ["arguments": String(character)]]
            if index == 0 { tool["id"] = "call-burst"; tool["function"] = ["name": "type_text", "arguments": String(character)] }
            let object: [String: Any] = ["choices": [["delta": ["tool_calls": [tool]], "finish_reason": NSNull()]]]
            frames.append("data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n")
        }
        frames.append("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n")
        ProviderURLProtocol.fixture.reset(body: Data(frames.joined().utf8))
        let p = try PrivateVisionProvider(settings: .init(baseURL: "https://fixture.invalid/v1", model: "fixture"), apiKey: "synthetic", limits: .init(), sessionID: UUID(), transport: ResponsesTransport(protocolClasses: [ProviderURLProtocol.self]))
        defer { p.cancel() }
        var terminals: [ModelResponse] = []
        for try await event in p.stream(request) {
            if case .terminal(let response) = event { terminals.append(response) }
            if case .toolCall = event { XCTFail("Calls must remain inside authoritative terminal") }
        }
        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals.first?.toolCalls, [.init(id: "call-burst", name: "type_text", arguments: arguments)])
        XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
    }
    func testDeepSeekPlainReasoningSSECompletesWithoutDoneMarker() async throws {
        let reasoning: [String: Any] = ["type": "reasoning", "id": "reason", "content": [["type": "reasoning_text", "text": "public reasoning"]]]
        let message: [String: Any] = ["id": "msg", "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "answer", "annotations": []]]]
        var frames: [[String: Any]] = [
            ["type": "response.created", "response": ["id": "r1", "status": "in_progress"]],
            ["type": "response.output_item.added", "output_index": 0, "item": ["id": "reason", "type": "reasoning"]],
            ["type": "response.reasoning_text.delta", "output_index": 0, "item_id": "reason", "content_index": 0, "delta": "public reasoning"],
            ["type": "response.reasoning_text.done", "output_index": 0, "item_id": "reason", "content_index": 0, "text": "public reasoning"],
            ["type": "response.output_item.done", "output_index": 0, "item": reasoning],
            ["type": "response.output_item.added", "output_index": 1, "item": message],
            ["type": "response.output_text.delta", "output_index": 1, "item_id": "msg", "content_index": 0, "delta": "answer"],
            ["type": "response.output_item.done", "output_index": 1, "item": message],
            ["type": "response.completed", "response": ["id": "r1", "model": "fixture", "status": "completed", "store": false, "previous_response_id": NSNull(), "output": [reasoning, message]]]
        ]
        var body = Data()
        for i in frames.indices {
            frames[i]["sequence_number"] = i
            body.append(Data("event: \(frames[i]["type"]!)\ndata: ".utf8))
            body.append(try JSONSerialization.data(withJSONObject: frames[i]))
            body.append(Data("\n\n".utf8))
        }
        ProviderURLProtocol.fixture.reset(body: body)
        let p = try provider(); defer { p.cancel() }
        var text = "", preview = "", terminal: ModelResponse?
        for try await event in p.stream(request) {
            switch event {
            case .text(let delta): text += delta
            case .reasoning(let delta): preview += delta
            case .terminal(let response): terminal = response
            default: break
            }
        }
        XCTAssertEqual(text, "answer"); XCTAssertEqual(preview, "public reasoning")
        XCTAssertEqual(terminal?.reasoning, preview); XCTAssertEqual(terminal?.status, .completed)
        XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
    }
    private var request: ModelRequest { .init(model: "fixture", messages: [.system("instructions"), .user("task")]) }
    private func provider() throws -> PrivateVisionProvider {
        try PrivateVisionProvider(settings: .init(baseURL: "https://invalid.invalid/v1", model: "fixture"), apiKey: "synthetic", limits: .init(), inferenceAPI: .responses, sessionID: UUID(), transport: ResponsesTransport(protocolClasses: [ProviderURLProtocol.self]))
    }
    private func completed() -> Data {
        Data("{\"id\":\"r1\",\"model\":\"fixture\",\"status\":\"completed\",\"output\":[{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\",\"annotations\":[]}]}]}".utf8)
    }
    func testBothTransportPathsUseEphemeralNoCookieCacheAndExplicitHeaders() throws {
        let t = ResponsesTransport(protocolClasses: [ProviderURLProtocol.self]); defer { t.cancel() }
        let config = t.session.configuration
        XCTAssertNil(config.urlCache); XCTAssertNil(config.httpCookieStorage); XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        let p = try provider(); defer { p.cancel() }
        for stream in [true, false] {
            let r = try p.prepareRequest(request, stream: stream)
            XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), stream ? "text/event-stream" : "application/json")
            XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
        }
    }
    func testCompleteMockAndHTTPErrorDoNotTriggerRegeneration() async throws {
        ProviderURLProtocol.fixture.reset(body: completed())
        let p = try provider(); defer { p.cancel() }
        let r = try await p.complete(request); XCTAssertEqual(r.text, "answer")
        XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
        for status in [401, 429, 500, 404] {
            ProviderURLProtocol.fixture.reset(body: Data("SECRET_PAYLOAD".utf8), status: status)
            let failure = try provider(); defer { failure.cancel() }
            do { _ = try await failure.complete(request); XCTFail("HTTP error expected") } catch {
                XCTAssertFalse(error.localizedDescription.contains("SECRET_PAYLOAD"))
            }
            XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
        }
    }
    func testOpenRouterAccountingFrameCompletesForBothOpenAIAndRouterProfiles() async throws {
        // Official Chat shape: the final usage frame repeats role, empty content
        // and finish_reason, unlike OpenAI's empty choices accounting frame.
        let body = Data("""
        : OPENROUTER PROCESSING

        data: {"id":"gen-fixture","choices":[{"index":0,"delta":{"role":"assistant","content":"answer"},"finish_reason":null}]}

        data: {"id":"gen-fixture","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop","native_finish_reason":"stop"}]}

        data: {"id":"gen-fixture","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop","native_finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}

        data: [DONE]


        """.utf8)
        for kind in [ProviderKind.openAI, .openRouter] {
            ProviderURLProtocol.fixture.reset(body: body)
            let p = try PrivateVisionProvider(settings: .init(baseURL: "https://fixture.invalid/api/v1", model: "fixture"), apiKey: "synthetic", limits: .init(), providerKind: kind, sessionID: UUID(), transport: ResponsesTransport(protocolClasses: [ProviderURLProtocol.self]))
            defer { p.cancel() }
            var text = "", terminals: [ModelResponse] = []
            for try await event in p.stream(request) {
                switch event {
                case .text(let value): text += value
                case .terminal(let response): terminals.append(response)
                case .toolCall, .finish: XCTFail("Expected one authoritative terminal")
                default: break
                }
            }
            XCTAssertEqual(text, "answer"); XCTAssertEqual(terminals.count, 1)
            XCTAssertEqual(terminals.first?.text, "answer"); XCTAssertEqual(terminals.first?.status, .completed)
            XCTAssertEqual(terminals.first?.usage?.totalTokens, 17)
            XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
        }
    }
    func testStreamingEOFFailureAndMalformedPayloadCancelUnderlyingTask() async throws {
        for body in [Data("data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"r1\"}}\n\n".utf8), Data("data: INVALID_SECRET_PAYLOAD\n\n".utf8)] {
            ProviderURLProtocol.fixture.reset(body: body, block: false)
            let p = try provider(); defer { p.cancel() }
            do { for try await _ in p.stream(request) {}; XCTFail("No valid terminal") } catch { XCTAssertFalse(error.localizedDescription.contains("SECRET_PAYLOAD")) }
            XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
        }
    }
    func testCancellationPropagatesForBothOperationsWithoutSecondRequest() async throws {
        for stream in [true, false] {
            ProviderURLProtocol.fixture.reset(block: true)
            let p = try provider()
            let task = Task {
                if stream { for try await _ in p.stream(request) {}; try Task.checkCancellation() } else { _ = try await p.complete(request) }
            }
            for _ in 0..<100 {
                if ProviderURLProtocol.fixture.lock.withLock({ !ProviderURLProtocol.fixture.requests.isEmpty }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            task.cancel(); p.cancel()
            do { try await task.value; XCTFail("Cancellation expected") } catch {}
            XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
            for _ in 0..<100 {
                if ProviderURLProtocol.fixture.lock.withLock({ ProviderURLProtocol.fixture.stopped > 0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.stopped }, 0)
        }
    }
}
