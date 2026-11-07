import XCTest
import AgentKit
import ProviderCore
import OpenAIAdapter
@testable import PhoneAgent

final class ReasoningParsingTests: XCTestCase {
    private let request = ModelRequest(model: "fixture", messages: [.user("synthetic")])
    private func line(_ delta: [String: Any], finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["id": "fixture", "choices": [choice]]), as: UTF8.self)
    }
    private func reasoning(_ chunks: [ModelEvent]) -> String {
        chunks.compactMap { if case .reasoning(let text) = $0 { return text }; return nil }.joined()
    }
    func testExplicitPlainFieldsStreamWithoutAnswerMixingOrAliasDuplication() throws {
        for field in ["reasoning", "reasoning_content"] {
            var decoder = ModelStreamDecoder()
            let first = try decoder.consume(line: line([field: "第一", "content": "答复"]), request: request)
            let second = try decoder.consume(line: line([field: "段", "reasoning_details": [["type": "reasoning.text", "text": "DUPLICATE"]]], finish: "stop"), request: request)
            XCTAssertEqual(reasoning(first + second), "第一段")
            XCTAssertEqual(first.compactMap { if case .text(let text) = $0 { return text }; return nil }, ["答复"])
            XCTAssertEqual(try decoder.finish().count, 1)
        }
    }
    func testStructuredSummaryTextFragmentsIgnoreEncryptedAndUnknownDetails() throws {
        var decoder = ModelStreamDecoder()
        let first = try decoder.consume(line: line(["reasoning": "DUPLICATE", "reasoning_details": [
            ["type": "reasoning.summary", "summary": "摘要", "index": 0],
            ["type": "reasoning.encrypted", "data": "DO_NOT_DISPLAY", "text": "ALSO_HIDDEN", "index": 1]
        ]]), request: request)
        let next = try decoder.consume(line: line(["reasoning_details": [
            ["type": "reasoning.summary", "summary": "续段", "index": 0],
            ["type": "reasoning.text", "text": "正文", "signature": "SIGNATURE_HIDDEN", "index": 2],
            ["type": "unknown", "text": "UNKNOWN_HIDDEN", "index": 3]
        ]], finish: "stop"), request: request)
        XCTAssertEqual(reasoning(first + next), "摘要续段\n\n正文")
        _ = try decoder.finish()
    }
    func testOpaqueObjectsAndOrdinaryAnswerTagsNeverBecomeReasoning() throws {
        var decoder = ModelStreamDecoder()
        let chunks = try decoder.consume(line: line(["reasoning": ["encrypted": "SECRET"], "reasoning_details": [["type": "reasoning.encrypted", "data": "SECRET"]], "content": "<think>ordinary answer</think>"], finish: "stop"), request: request)
        XCTAssertEqual(reasoning(chunks), "")
        XCTAssertEqual(chunks.compactMap { if case .text(let text) = $0 { return text }; return nil }, ["<think>ordinary answer</think>"])
        _ = try decoder.finish()
    }
    func testCompleteResponsesUseSameAllowlistWithoutOpaqueRawData() throws {
        let provider = try PrivateVisionProvider(settings: .init(baseURL: "https://invalid.invalid/v1", model: "fixture"), apiKey: "synthetic", limits: AgentLimits(), sessionID: UUID())
        defer { provider.cancel() }
        for payload: [String: Any] in [
            ["reasoning": "readable"], ["reasoning_content": "readable"],
            ["reasoning_details": [["type": "reasoning.summary", "summary": "readable"]], "reasoning": "duplicate"],
            ["reasoning": ["opaque": "SECRET"], "reasoning_details": [["type": "reasoning.encrypted", "data": "SECRET"]]]
        ] {
            var message = payload; message["content"] = "answer"; message["role"] = "assistant"
            let data = try JSONSerialization.data(withJSONObject: ["id": "fixture", "choices": [["message": message, "finish_reason": "stop"]]])
            let response = try provider.parseResponse(data, request: request)
            XCTAssertEqual(response.text, "answer")
            XCTAssertEqual(response.reasoning, payload["reasoning"] is [String: String] ? nil : "readable")
            XCTAssertNil(response.rawData)
        }
    }
}

@MainActor final class ReasoningHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reasoning-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw AppError.timeout
    }
    func testReasoningOnlyTurnAndFinalAnswerPersistSeparatelyWithoutFutureContextReplay() throws {
        let root = try directory(), store = ConversationStore(directory: root), id = store.create(mode: .live)
        let run = try XCTUnwrap(store.begin(in: id, query: "test"))
        store.beginAssistantTurn(run); store.appendReasoning("first", identity: run)
        store.completeAssistantTurn("", reasoning: "first", identity: run)
        store.beginAssistantTurn(run); store.appendReasoning("second", identity: run); store.appendText("answer", identity: run)
        store.completeAssistantTurn("answer", reasoning: "second", identity: run); store.finish(run, phase: .completed, summary: "")
        let restored = ConversationStore(directory: root), messages = try XCTUnwrap(restored.conversation(id)?.messages.filter { $0.role == .assistant })
        XCTAssertEqual(messages.map(\.text), ["", "answer"])
        XCTAssertEqual(messages.compactMap(\.reasoning).map(\.text), ["first", "second"])
        XCTAssertTrue(messages.allSatisfy { $0.reasoning?.state == .complete })
        XCTAssertEqual(restored.history(in: id).map(\.text), ["test", "answer"])
        XCTAssertTrue(restored.history(in: id).allSatisfy { $0.reasoning == nil })
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "role": "assistant", "text": "legacy", "date": 0, "state": "complete"]))
        XCTAssertNil(legacy.reasoning)
    }
    func testInterruptedPartialReasoningSurvivesRestartAndRejectsLateCrossSessionEvents() throws {
        let root = try directory(), store = ConversationStore(directory: root), id = store.create(mode: .live)
        let run = try XCTUnwrap(store.begin(in: id, query: "test"))
        store.beginAssistantTurn(run); store.appendReasoning("partial", identity: run); store.saveNow()
        let restored = ConversationStore(directory: root)
        XCTAssertEqual(restored.conversation(id)?.messages.last?.reasoning, .init(text: "partial", state: .interrupted))
        store.finish(run, phase: .stopped, summary: "")
        let other = store.create(mode: .live), next = try XCTUnwrap(store.begin(in: other, query: "other"))
        store.beginAssistantTurn(next)
        AgentEventProjection.record(.reasoningDelta(itemID: UUID(), text: "LATE"), run: run, frame: nil, in: store)
        XCTAssertNil(store.conversation(other)?.messages.last?.reasoning)
        XCTAssertEqual(store.conversation(id)?.messages.last?.reasoning?.text, "partial")
    }
    func testActualStreamingAgentKeepsCompletionAndFailureReasoningStates() async throws {
        for outcome in ["completed", "failed"] {
            let store = ConversationStore(inMemory: true), model = AgentViewModel(sessions: store, loadPersistentState: false,
                runServices: .init(provider: ReasoningFixtureProvider(outcome: outcome), bridge: UnavailableBridge()))
            let id = model.createConversation(mode: .live)
            XCTAssertTrue(model.send("synthetic", in: id, cloudConsent: true)); try await waitUntil { !model.running }
            let message = try XCTUnwrap(store.conversation(id)?.messages.first { $0.role == .assistant })
            XCTAssertEqual(message.reasoning?.text, ReasoningFixtureProvider.first + ReasoningFixtureProvider.second)
            XCTAssertEqual(message.reasoning?.state, outcome == "completed" ? .complete : .failed)
            XCTAssertEqual(message.text, outcome == "completed" ? "合成答复。" : "")
        }
    }
    func testActualCancellationRetainsPartialReasoningWithoutFinalAnswer() async throws {
        let store = ConversationStore(inMemory: true), model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: .init(provider: ReasoningFixtureProvider(outcome: "paused"), bridge: UnavailableBridge()))
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("synthetic", in: id, cloudConsent: true))
        try await waitUntil { store.conversation(id)?.messages.last?.reasoning != nil }
        model.stop(); try await waitUntil { !model.stopping }
        let message = try XCTUnwrap(store.conversation(id)?.messages.first { $0.role == .assistant })
        XCTAssertEqual(message.reasoning?.state, .interrupted)
        XCTAssertTrue(message.reasoning?.text.hasPrefix(ReasoningFixtureProvider.first) == true)
        XCTAssertEqual(message.text, "")
    }
    func testWireDecodedReasoningToolBatchAndFinalTurnStaySeparateInActualAgent() async throws {
        let store = ConversationStore(inMemory: true), model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: .init(provider: ReasoningBatchProvider(), bridge: UnavailableBridge()))
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("synthetic", in: id, cloudConsent: true)); try await waitUntil { !model.running }
        let messages = try XCTUnwrap(store.conversation(id)?.messages)
        let assistant = messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistant.map(\.text), ["", "FINAL_ANSWER"])
        XCTAssertEqual(assistant.compactMap(\.reasoning).map(\.text), ["READABLE_FIRST", "READABLE_SUMMARY"])
        XCTAssertTrue(assistant.allSatisfy { $0.reasoning?.state == .complete })
        XCTAssertEqual(messages.compactMap(\.tool).map(\.callID), ["wait-1", "wait-2"])
        XCTAssertTrue(messages.compactMap(\.tool).allSatisfy { $0.state == .succeeded })
    }
}

private struct ReasoningBatchProvider: ModelProvider {
    static let name = "synthetic-reasoning-batch"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func complete(_ request: ModelRequest) async throws -> ModelResponse { throw AppError.invalid("Fixture must stream without retry") }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let messages = fixtureMessages(request)
                XCTAssertFalse(messages.contains { $0.content.contains("READABLE_") || $0.content.contains("OPAQUE_") })
                let results = messages.filter { $0.role == .tool }
                let delta: [String: Any], finish: String
                if results.isEmpty {
                    delta = ["reasoning_content": "READABLE_FIRST", "tool_calls": (0...1).map { index in
                        ["index": index, "id": "wait-\(index + 1)", "type": "function", "function": ["name": "wait", "arguments": "{\"duration_ms\":1}"]] as [String: Any]
                    }]; finish = "tool_calls"
                } else {
                    XCTAssertEqual(results.map(\.toolCallId), ["wait-1", "wait-2"])
                    delta = ["content": "FINAL_ANSWER", "reasoning_details": [
                        ["type": "reasoning.summary", "summary": "READABLE_SUMMARY", "index": 0],
                        ["type": "reasoning.encrypted", "data": "OPAQUE_HIDDEN", "index": 1]
                    ]]; finish = "stop"
                }
                let line = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["id": "fixture", "choices": [["delta": delta, "finish_reason": finish]]]), as: UTF8.self)
                var decoder = ModelStreamDecoder()
                for chunk in try decoder.consume(line: line, request: request) { continuation.yield(chunk) }
                let fixtureScope = ProviderReplayScope(provider: Self.name, endpoint: configuration.baseURL.absoluteString, account: "fixture", model: request.model, session: UUID())
                let parsed = try decoder.finalResponse(request: request, providerName: Self.name, scope: fixtureScope)
                // This fixture has public synthetic reasoning blocks, without a live service replay identity.
                continuation.yield(.terminal(ModelResponse(text: parsed.text, reasoning: parsed.reasoning, finishReason: parsed.finishReason,
                    usage: parsed.usage, toolCalls: parsed.toolCalls, request: request, providerName: Self.name)))
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}
