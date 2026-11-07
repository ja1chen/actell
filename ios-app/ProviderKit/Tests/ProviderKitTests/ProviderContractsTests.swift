import XCTest
import ProviderCore
@testable import OpenAIAdapter

final class ProviderContractsTests: XCTestCase {
    private let session = UUID()
    private func codec(compaction: Bool = true, session: UUID? = nil) -> OpenAIWireCodec {
        .init(configuration: .init(name: "test", baseURL: URL(string: "https://example.invalid/v1")!, defaultModel: "test"), wire: .responses,
              scope: .init(provider: "test", endpoint: "https://example.invalid/v1", account: "account", model: "test", session: session ?? self.session), capabilities: .init(compaction: compaction))
    }
    func testNativeCompactionPreservesCanonicalWindowAndScope() throws {
        let adapter = codec()
        let data = Data(#"{"id":"cmp-response","object":"response.compaction","output":[{"type":"message","role":"user","content":[{"type":"input_text","text":"retained"}]},{"type":"compaction","id":"cmp-item","encrypted_content":"opaque"}],"usage":{"input_tokens":42,"input_tokens_details":{"cached_tokens":12,"cache_write_tokens":8}}}"#.utf8)
        let response = try adapter.parseCompaction(data)
        XCTAssertEqual(response.input.count, 2)
        XCTAssertEqual(response.usage?.cachedTokens, 12)
        XCTAssertEqual(response.usage?.cacheWriteTokens, 8)
        let request = ModelRequest(model: "test", messages: [])
        var next = request; next.input = response.input
        let wire = try XCTUnwrap(adapter.prepareRequest(next, stream: true).httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        XCTAssertEqual((body["input"] as? [[String: Any]])?.count, 2)
        XCTAssertThrowsError(try codec(session: UUID()).prepareRequest(next, stream: true))
        XCTAssertThrowsError(try codec(compaction: false).prepareCompaction(.init(model: "test", input: response.input)))
    }
    func testPreparedRequestsAreIndependentAndStable() throws {
        let adapter = codec()
        var request = ModelRequest(model: "test", messages: [])
        request.input = [.message(role: .user, content: [.text("first")])]
        request.cachePolicy = .init(key: "session-cache")
        let first = try adapter.prepareRequest(request, stream: true).httpBody
        XCTAssertThrowsError(try adapter.parseCompaction(Data(#"{"id":"bad","object":"response.compaction","output":[]}"#.utf8)))
        XCTAssertEqual(first, try adapter.prepareRequest(request, stream: true).httpBody)
    }
    func testInputProjectionNeverSilentlyPrunesToolImages() throws {
        let image = ModelImage(data: Data([1]))
        var first = ModelMessage.tool("one", toolCallId: "a"); first.images = [image]
        var second = ModelMessage.tool("two", toolCallId: "b"); second.images = [image]
        XCTAssertEqual(try ModelInputProjection.input(messages: [first, second]).count, 4)
    }
    func testChatInterleavedToolArgumentsAndCachedUsage() throws {
        var decoder = ModelStreamDecoder()
        let request = ModelRequest(model: "test", messages: [])
        let frames = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"second","arguments":"{"}},{"index":0,"id":"a","function":{"name":"first","arguments":"{}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":100,"prompt_tokens_details":{"cached_tokens":64},"completion_tokens_details":{"reasoning_tokens":7}}}"#
        ]
        for frame in frames { _ = try decoder.consume(line: "data: " + frame, request: request) }
        _ = try decoder.consume(line: "data: [DONE]", request: request)
        let response = try decoder.finalResponse(request: request, providerName: "test", scope: codec().scope)
        XCTAssertEqual(response.toolCalls.map(\.id), ["a", "b"])
        XCTAssertEqual(response.usage?.cachedTokens, 64)
        XCTAssertEqual(response.usage?.reasoningTokens, 7)
    }
    func testIncompleteChatFailsThenIndependentRequestSucceeds() throws {
        let request = ModelRequest(model: "test", messages: [])
        var failed = ModelStreamDecoder()
        _ = try failed.consume(line: #"data: {"choices":[{"delta":{"content":"partial"}}]}"#, request: request)
        XCTAssertThrowsError(try failed.finalResponse(request: request, providerName: "test", scope: codec().scope))
        var valid = ModelStreamDecoder()
        _ = try valid.consume(line: #"data: {"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}"#, request: request)
        XCTAssertEqual(try valid.finalResponse(request: request, providerName: "test", scope: codec().scope).text, "done")
    }
    func testDiagnosticQuotaDoesNotBlockCompletedResponse() throws {
        var reducer = ResponsesReducer(codec: codec(), request: .init(model: "test", messages: []))
        _ = try reducer.consume(payload: #"{"type":"response.created","sequence_number":0,"response":{"id":"r"}}"#)
        for sequence in 1...140 {
            _ = try reducer.consume(payload: "{\"type\":\"vendor.extension\",\"sequence_number\":\(sequence),\"response_id\":\"r\"}")
        }
        _ = try reducer.consume(payload: #"{"type":"response.completed","sequence_number":141,"response":{"id":"r","status":"completed","model":"test","output":[]}}"#)
        XCTAssertEqual(try reducer.finish().status, .completed)
        XCTAssertEqual(try reducer.finish().streamEvents.count, 128)
    }
    func testSSEHandlesFragmentedUTF8AndRejectsTruncation() throws {
        var decoder = SSEFrameDecoder()
        var frames: [String] = []
        for byte in Data("data: 执言\r\n\r\n".utf8) { if let frame = try decoder.consume(byte) { frames.append(frame) } }
        try decoder.finish()
        XCTAssertEqual(frames, ["执言"])
        _ = try decoder.consume(UInt8(ascii: "d"))
        XCTAssertThrowsError(try decoder.finish())
    }
    func testCompactionRetainsCanonicalMediaMetadata() throws {
        let adapter = codec()
        let data = Data(#"{"id":"c","object":"response.compaction","output":[{"id":"u","type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,AQ==","detail":"low"}],"custom":"keep"},{"type":"compaction","encrypted_content":"opaque"}]}"#.utf8)
        let result = try adapter.parseCompaction(data)
        let replay = try adapter.inputObject(result.input[0])
        XCTAssertEqual(replay["id"] as? String, "u")
        XCTAssertEqual(replay["custom"] as? String, "keep")
        XCTAssertEqual((replay["content"] as? [[String: Any]])?.first?["detail"] as? String, "low")
    }

    func testOnlyExplicitAdmissionRejectionsAllowRecovery() {
        XCTAssertEqual(ResponsesTransport.admissionError(status: 400, body: Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8)), .rejectedBeforeAcceptance(reason: .contextCapacity))
        XCTAssertEqual(ResponsesTransport.admissionError(status: 400, body: Data(#"{"error":{"code":"previous_response_not_found","param":"previous_response_id"}}"#.utf8)), .rejectedBeforeAcceptance(reason: .invalidResponseHead))
        XCTAssertEqual(ResponsesTransport.admissionError(status: 500, body: Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8)), .httpError(500, nil))
        XCTAssertEqual(ResponsesTransport.admissionError(status: 400, body: Data(#"{"error":{"message":"context_length_exceeded"}}"#.utf8)), .httpError(400, nil))
    }

    func testChatCanonicalInputPreservesToolsImagesAndScopedReasoning() throws {
        let scope = codec().scope
        let adapter = OpenAIWireCodec(configuration: .init(name: "test", baseURL: URL(string: "https://example.invalid/v1")!, defaultModel: "test"), wire: .chatCompletions, scope: scope)
        let blocks: [JSONValue] = [.object(["type": .string("reasoning.encrypted"), "data": .string("opaque")])]
        var request = ModelRequest(model: "test", messages: [])
        request.instructions = "stable instructions"
        request.input = [.message(role: .user, content: [.text("look")]),
                         .replay(.message(.init(id: "m", content: [.text("checking", annotations: [])]))),
                         .replay(.functionCall(.init(id: "c", name: "tap", arguments: "{}"))),
                         .chatReplayState(.init(scope: scope, reasoningDetails: blocks)),
                         .functionResult(callID: "c", output: "receipt"),
                         .message(role: .tool, content: [.image(.init(data: Data([1])))])]
        let data = try XCTUnwrap(adapter.prepareRequest(request, stream: true).httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "user"])
        XCTAssertEqual(try JSONValue(any: XCTUnwrap(messages[2]["reasoning_details"])), .array(blocks))
        XCTAssertEqual((messages[2]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String, "c")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "c")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("AQ=="))
        XCTAssertThrowsError(try codec().prepareRequest(request, stream: true))
    }

    func testRawReasoningContentIsPreservedIndependentlyOfReadableProjection() throws {
        var decoder = ModelStreamDecoder()
        let request = ModelRequest(model: "test", messages: [])
        _ = try decoder.consume(line: #"data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"readable summary"}],"reasoning_content":"  original\n"}}]}"#, request: request)
        _ = try decoder.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"原文  ","content":"answer"},"finish_reason":"stop"}]}"#, request: request)
        let response = try decoder.finalResponse(request: request, providerName: "test", scope: codec().scope)
        XCTAssertEqual(response.reasoning, "readable summary")
        let state = try XCTUnwrap(response.replayState)
        XCTAssertEqual(try state.reasoningContentForReplay(scope: codec().scope), "  original\n原文  ")
        let restored = try JSONDecoder().decode(ScopedChatReplayState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try restored.reasoningContentForReplay(scope: codec().scope), "  original\n原文  ")
        XCTAssertThrowsError(try restored.reasoningContentForReplay(scope: codec(session: UUID()).scope))
    }
    func testReasoningContentReplayRequiresExplicitCapabilityAndTools() throws {
        let scope = codec().scope
        let configuration = ProviderConfiguration(name: "test", baseURL: URL(string: "https://api.deepseek.com/v1")!, defaultModel: "test")
        let state = ScopedChatReplayState(scope: scope, reasoningDetails: [], reasoningContent: "exact raw continuation")
        var request = ModelRequest(model: "test", messages: [], tools: [.init(name: "lookup", description: "synthetic", schema: .object(["type": .string("object")]))])
        request.input = [.replay(.message(.init(id: "m", content: [.text("answer", annotations: [])]))), .chatReplayState(state), .message(role: .user, content: [.text("continue")])]
        func firstAssistant(_ capable: Bool, request: ModelRequest) throws -> [String: Any] {
            let adapter = OpenAIWireCodec(configuration: configuration, wire: .chatCompletions, scope: scope, capabilities: .init(chatReasoningContentReplay: capable))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(adapter.prepareRequest(request, stream: true).httpBody)) as? [String: Any])
            return try XCTUnwrap((body["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "assistant" })
        }
        XCTAssertEqual(try firstAssistant(true, request: request)["reasoning_content"] as? String, "exact raw continuation")
        XCTAssertNil(try firstAssistant(false, request: request)["reasoning_content"])
        request.tools = []
        XCTAssertNil(try firstAssistant(true, request: request)["reasoning_content"])
        XCTAssertEqual(OpenAIWireCodec.usage(["prompt_cache_hit_tokens": 8])?.cachedTokens, 8)
        XCTAssertNil(OpenAIWireCodec.usage(["prompt_cache_miss_tokens": 8])?.cacheWriteTokens)
    }

}
