import XCTest
import os
import AgentKit
import ProviderCore
import OpenAIAdapter
@testable import PhoneAgent

private actor ProviderSideEffects {
    var count = 0
    func execute() { count += 1 }
}
private struct CountedDeviceTool: AgentTool {
    let descriptor = ToolDescriptor(name: "tap", description: "Synthetic device side effect only", parameters: .object(["type": .string("object")]), effect: .deviceMutation)
    let effects: ProviderSideEffects
    func execute(_ invocation: ToolInvocation, context: ToolExecutionContext) async throws -> ToolOutcome {
        try await context.checkCancellation()
        await effects.execute()
        return .init(content: "receipt:already-executed")
    }
}
private final class RuntimeFixtureProvider: ModelProvider, @unchecked Sendable {
    enum Behavior { case roundTrip, repeatCall, partialTool, onlyToolSignal, resultSubmissionFailure, failure, incomplete }
    static let name = "native-runtime-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    let behavior: Behavior
    private let lock = NSLock()
    private var requests: [ModelRequest] = []
    private var completes = 0
    init(_ behavior: Behavior) { self.behavior = behavior }
    var counts: (Int, Int) { lock.withLock { (requests.count, completes) } }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { lock.withLock { completes += 1 }; throw ModelError.interrupted }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let index = lock.withLock { requests.append(request); return requests.count }
        return AsyncThrowingStream { c in
            if behavior == .failure || (behavior == .resultSubmissionFailure && index > 1) { c.finish(throwing: ModelError.interrupted); return }
            let call = ModelToolCall(id: "stable-call", itemID: "separate-item", name: "tap", arguments: "{}", status: .completed)
            if behavior == .partialTool { c.yield(.toolCall(call)); c.finish(); return }
            if behavior == .onlyToolSignal { c.yield(.finish(reason: .toolCalls, usage: nil)); c.finish(); return }
            if behavior == .incomplete {
                c.yield(.terminal(.init(id: "r", model: "fixture", status: .incomplete, output: [.functionCall(call)], request: request, providerName: Self.name))); c.finish(); return
            }
            if index == 1 || behavior == .repeatCall {
                c.yield(.terminal(.init(id: "r\(index)", model: "fixture", status: .completed, output: [.functionCall(call)], request: request, providerName: Self.name)))
            } else {
                let results = (request.input ?? []).compactMap { item -> String? in
                    if case .functionResult(let callID, let output) = item, callID == "stable-call" { return output }; return nil
                }
                XCTAssertEqual(results, ["receipt:already-executed"])
                c.yield(.terminal(.init(id: "r\(index)", model: "fixture", status: .completed, output: [.message(.init(id: "m", content: [.text("done", annotations: [])]))], request: request, providerName: Self.name)))
            }
            c.finish()
        }
    }
}
final class ProviderRuntimeTests: XCTestCase {
    private func run(_ behavior: RuntimeFixtureProvider.Behavior) async throws -> (RuntimeFixtureProvider, ProviderSideEffects) {
        let p = RuntimeFixtureProvider(behavior), e = ProviderSideEffects()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), session = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONLSessionStore(root: root, sessionID: session)
        let runtime = AgentRuntime(store: store, provider: p, configuration: .init(model: "fixture"), tools: [CountedDeviceTool(effects: e)])
        _ = try await runtime.createSession(id: session)
        let handle = try await runtime.startTurn(in: session, input: .init(text: "synthetic"))
        let result = await handle.result()
        XCTAssertEqual(result.status, behavior == .roundTrip ? .completed : .failed)
        return (p, e)
    }
    func testReasoningContentReplayIsEnabledOnlyForOfficialDeepSeekChat() async throws {
        for endpoint in ["https://api.deepseek.com/v1", "https://gateway.invalid/v1"] {
            let provider = try PrivateVisionProvider(settings: .init(baseURL: endpoint, model: "fixture"), apiKey: "synthetic", limits: .init(), sessionID: UUID())
            defer { provider.cancel() }
            let enabled = endpoint == "https://api.deepseek.com/v1"
            let capability = try await provider.capabilities(for: "fixture")
            XCTAssertEqual(capability.chatReasoningContentReplay, enabled)
            let state = ScopedChatReplayState(scope: provider.replayScope, reasoningDetails: [], reasoningContent: "raw continuation")
            let request = ModelRequest(model: "fixture", messages: [.assistant("answer", replayState: state), .user("continue")], tools: [.init(name: "lookup", description: "synthetic", parameters: ["type": "object"])])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(provider.prepareRequest(request, stream: true).httpBody)) as? [String: Any])
            let assistant = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "assistant" })
            XCTAssertEqual(assistant["reasoning_content"] as? String, enabled ? "raw continuation" : nil)
        }
    }
    func testRealChatAdapterPublishesOneTerminalAndRunsOneEffect() async throws {
        ChatRuntimeWire.reset()
        let session = UUID()
        let provider = try PrivateVisionProvider(settings: .init(baseURL: "https://chat-runtime-fixture.invalid/v1", model: "fixture"), apiKey: "synthetic", limits: .init(), sessionID: session, transport: ResponsesTransport(protocolClasses: [ChatRuntimeWire.self]))
        defer { provider.cancel() }
        var terminalCount = 0
        for try await event in provider.stream(.init(model: "fixture", messages: [.user("check boundary")])) {
            switch event {
            case .finish: XCTFail("Assembler finish escaped the provider boundary")
            case .toolCall: XCTFail("Tool call escaped before authoritative terminal")
            case .terminal(let response): terminalCount += 1; XCTAssertEqual(response.toolCalls.map(\.id), ["wire-call"])
            default: break
            }
        }
        XCTAssertEqual(terminalCount, 1)
        ChatRuntimeWire.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = ProviderSideEffects()
        let store = JSONLSessionStore(root: root, sessionID: session)
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture", scope: provider.replayScope), tools: [CountedDeviceTool(effects: effects)])
        _ = try await runtime.createSession(id: session)
        let turn = try await runtime.startTurn(in: session, input: .init(text: "synthetic"))
        let result = await turn.result()
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.text, "wire done")
        let count = await effects.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(ChatRuntimeWire.requestCount, 2)
        let reopened = JSONLSessionStore(root: root, sessionID: session)
        let facts = try await reopened.readTransactions(session)
        XCTAssertEqual(facts.flatMap(\.toolResults).count, 1)
    }
    func testNativeToolsRoundTripAndRepeatedCallsNeverRepeatDeviceSideEffect() async throws {
        for behavior in [RuntimeFixtureProvider.Behavior.roundTrip, .repeatCall, .resultSubmissionFailure] {
            let (p, e) = try await run(behavior)
            let count = await e.count; XCTAssertEqual(count, 1); XCTAssertEqual(p.counts.0, 2); XCTAssertEqual(p.counts.1, 0)
        }
    }
    func testIncompleteOrPartialToolStreamsAndUncertainErrorsDoNotRegenerateOrDispatch() async throws {
        for behavior in [RuntimeFixtureProvider.Behavior.partialTool, .onlyToolSignal, .failure, .incomplete] {
            let (p, e) = try await run(behavior)
            let count = await e.count; XCTAssertEqual(count, 0); XCTAssertEqual(p.counts.0, 1); XCTAssertEqual(p.counts.1, 0)
        }
    }
}

private final class ChatRuntimeWire: URLProtocol, @unchecked Sendable {
    private static let requests = OSAllocatedUnfairLock(initialState: 0)
    static var requestCount: Int { requests.withLock { $0 } }
    static func reset() { requests.withLock { $0 = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chat-runtime-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = Self.requests.withLock { $0 += 1; return $0 }
        let first = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"wire-call","type":"function","function":{"name":"tap","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        let final = #"{"choices":[{"index":0,"delta":{"content":"wire done"},"finish_reason":"stop"}]}"#
        let accounting = #"{"choices":[],"usage":{"prompt_tokens":40,"completion_tokens":3,"total_tokens":43,"prompt_tokens_details":{"cached_tokens":12}}}"#
        let payload = "data: " + (index == 1 ? first : final) + "\n\ndata: " + accounting + "\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
