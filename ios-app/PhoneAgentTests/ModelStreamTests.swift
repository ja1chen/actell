import XCTest
import ProviderCore
import OpenAIAdapter
@testable import PhoneAgent

final class ModelStreamTests: XCTestCase {
    let request = ModelRequest(model: "fixture", messages: [.user("synthetic")])
    private func line(_ delta: [String: Any], finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        let json = try JSONSerialization.data(withJSONObject: ["id": "test", "choices": [choice]])
        return "data: " + String(decoding: json, as: UTF8.self)
    }
    func testSSEHeartbeatsDoNotBecomeProgressOrACompletedResponse() throws {
        var decoder = ModelStreamDecoder()
        for value in [": keep-alive", ": ping", "", "event: heartbeat"] {
            XCTAssertTrue(try decoder.consume(line: value, request: request).isEmpty)
        }
        XCTAssertFalse(decoder.sawDone)
        XCTAssertThrowsError(try decoder.finish())
    }
    func testRealTextDeltasAndFragmentedToolAssembly() throws {
        var decoder = ModelStreamDecoder()
        let chunks = try decoder.consume(line: line(["content": "你好", "reasoning_content": "provider supplied reasoning"]), request: request)
        XCTAssertEqual(chunks.count, 2)
        if case .reasoning(let text) = chunks.first { XCTAssertEqual(text, "provider supplied reasoning") } else { XCTFail("Expected separate provider reasoning") }
        if case .text(let text) = chunks.last { XCTAssertEqual(text, "你好") } else { XCTFail("Expected public text") }
        let first: [String: Any] = ["tool_calls": [["index": 0, "id": "call-1", "type": "function", "function": ["name": "tap", "arguments": "{\"x\":"]]]]
        let next: [String: Any] = ["tool_calls": [["index": 0, "function": ["arguments": "12}"]]]]
        XCTAssertTrue(try decoder.consume(line: line(first), request: request).isEmpty)
        XCTAssertTrue(try decoder.consume(line: line(next, finish: "tool_calls"), request: request).isEmpty)
        _ = try decoder.consume(line: "data: [DONE]", request: request)
        let final = try decoder.finish()
        XCTAssertEqual(final.count, 2)
        if case .toolCall(let call) = final[0] { XCTAssertEqual(call.name, "tap"); XCTAssertEqual(call.arguments, "{\"x\":12}"); XCTAssertEqual(call.id, "call-1") }
        else { XCTFail("Expected exactly one assembled tool call") }
    }
    func testTruncatedOrMissingToolArgumentsNeverReleaseCalls() throws {
        var decoder = ModelStreamDecoder()
        _ = try decoder.consume(line: line(["tool_calls": [["index": 0, "function": ["name": "tap", "arguments": "{"]]]]), request: request)
        XCTAssertThrowsError(try decoder.finish())
        _ = try decoder.consume(line: line([:], finish: "tool_calls"), request: request)
        XCTAssertThrowsError(try decoder.finish())
        var missing = ModelStreamDecoder()
        _ = try missing.consume(line: line([:], finish: "tool_calls"), request: request)
        XCTAssertThrowsError(try missing.finish())
    }
    func testMultipleToolCallsStayBufferedUntilValidatedAndRetainOrder() throws {
        var decoder = ModelStreamDecoder()
        let calls = (0...1).map { index in ["index": index, "id": "call-\(index)", "function": ["name": "tap", "arguments": "{}"]] as [String: Any] }
        _ = try decoder.consume(line: line(["tool_calls": calls]), request: request)
        XCTAssertTrue(try decoder.consume(line: line([:], finish: "tool_calls"), request: request).isEmpty)
        let released = try decoder.finish().compactMap { chunk -> String? in
            if case .toolCall(let call) = chunk { return call.id }; return nil
        }
        XCTAssertEqual(released, ["call-0", "call-1"])
    }
    func testDuplicateOrReusedIDsAndMalformedBatchNeverReleaseAnyCalls() throws {
        for arguments in ["{}", "{"] {
            var decoder = ModelStreamDecoder()
            let calls = (0...1).map { index in ["index": index, "id": "same", "function": ["name": "tap", "arguments": arguments]] as [String: Any] }
            XCTAssertTrue(try decoder.consume(line: line(["tool_calls": calls], finish: "tool_calls"), request: request).isEmpty)
            XCTAssertThrowsError(try decoder.finish())
        }
        XCTAssertThrowsError(try ModelStreamDecoder.validate([.init(id: "old", name: "screenshot", arguments: "{}")], previousCallIDs: ["old"]))
    }
    func testAccountingRoleMetadataDoesNotAllowFreshOutputOrConflictingTerminal() throws {
        for delta in [["role": "assistant", "content": "late text"], ["role": "user", "content": ""]] {
            var decoder = ModelStreamDecoder()
            _ = try decoder.consume(line: line(["content": "answer"], finish: "stop"), request: request)
            XCTAssertThrowsError(try decoder.consume(line: line(delta, finish: "stop"), request: request))
        }
        var decoder = ModelStreamDecoder()
        _ = try decoder.consume(line: line(["content": "answer"], finish: "stop"), request: request)
        XCTAssertThrowsError(try decoder.consume(line: line(["role": "assistant", "content": ""], finish: "length"), request: request))
        var truncated = ModelStreamDecoder()
        _ = try truncated.consume(line: line(["role": "assistant", "content": "partial"]), request: request)
        XCTAssertThrowsError(try truncated.consume(line: "data: [DONE]", request: request))
        XCTAssertThrowsError(try truncated.finish())
    }
    func testStreamingRequestUsesActualStreamFlag() throws {
        let provider = try PrivateVisionProvider(settings: ProviderSettings(baseURL: "https://invalid.invalid/v1", model: "fixture"), apiKey: "synthetic-test-only", limits: AgentLimits(), sessionID: UUID())
        defer { provider.cancel() }
        let body = try XCTUnwrap(provider.prepareRequest(request, stream: true).httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["parallel_tool_calls"] as? Bool, true)
    }
    func testNonStreamingBatchPreservesIDsAndRejectsMissingOrRepeatedIdentity() throws {
        let provider = try PrivateVisionProvider(settings: ProviderSettings(baseURL: "https://invalid.invalid/v1", model: "fixture"), apiKey: "synthetic", limits: AgentLimits(), sessionID: UUID())
        defer { provider.cancel() }
        func data(_ ids: [String?]) throws -> Data {
            let calls = ids.map { id -> [String: Any] in
                var value: [String: Any] = ["type": "function", "function": ["name": "screenshot", "arguments": "{}"]]
                if let id { value["id"] = id }; return value
            }
            return try JSONSerialization.data(withJSONObject: ["id": "fixture", "choices": [["message": ["role": "assistant", "content": "", "tool_calls": calls], "finish_reason": "tool_calls"]]])
        }
        XCTAssertEqual(try provider.parseResponse(data(["first", "second"]), request: request).toolCalls.map(\.id), ["first", "second"])
        for ids in [["same", "same"], ["first", nil], ["", "second"]] as [[String?]] {
            XCTAssertThrowsError(try provider.parseResponse(data(ids), request: request))
        }
        var decoder = ModelStreamDecoder()
        _ = try decoder.consume(line: line(["tool_calls": [["index": 0, "function": ["name": "screenshot", "arguments": "{}"]]]], finish: "tool_calls"), request: request)
        XCTAssertThrowsError(try decoder.finish())
    }
}
