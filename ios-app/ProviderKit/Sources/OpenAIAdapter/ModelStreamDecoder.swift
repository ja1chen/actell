import Foundation
import ProviderCore

/// Chat gateway compatibility parser, independent of SDK/public runtime types.
/// Calls stay buffered until a complete, successful batch is validated.
public struct ModelStreamDecoder {
    public init() {}
    private struct Partial { var id = ""; var name = ""; var arguments = "" }
    private var partial: [Int: Partial] = [:]
    private var reasoning = ReadableReasoningDecoder()
    private var reasoningDetails: [ProviderCore.JSONValue] = []
    private var text = ""
    private var visibleReasoning = ""
    private var originalReasoningContent: String?
    private var reason: ModelFinishReason?
    private var sawTerminal = false
    public private(set) var sawDone = false
    public private(set) var usage: ModelUsage?
    public mutating func consume(line: String, request: ModelRequest) throws -> [ModelEvent] {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("data:") else { return [] }
        let payload = clean.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { guard sawTerminal, !sawDone else { throw ModelError.protocolViolation("Unexpected Chat done marker") }; sawDone = true; return [] }
        guard !sawDone else { throw ModelError.protocolViolation("Output after Chat done marker") }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], object["error"] == nil,
              let choices = object["choices"] as? [[String: Any]] else { throw ModelError.protocolViolation("Incompatible model stream format") }
        if let tokens = object["usage"] as? [String: Any] { usage = OpenAIWireCodec.usage(tokens) }
        guard let choice = choices.first else { return [] }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        if sawTerminal {
            // OpenRouter's final accounting frame repeats role=assistant.
            // Role metadata is not a new content/tool delta after completion.
            let hasOutput = delta.contains { key, value in
                if key == "role", value as? String == "assistant" { return false }
                if value is NSNull { return false }; if let s = value as? String { return !s.isEmpty }
                if let a = value as? [Any] { return !a.isEmpty }; return true
            }
            guard !hasOutput else { throw ModelError.protocolViolation("New model output arrived after completion") }
            if let repeated = choice["finish_reason"] as? String {
                guard ModelFinishReason(rawValue: repeated) == reason else { throw ModelError.protocolViolation("Conflicting stream terminal states") }
            }
            return [] // Final usage-only chunks can carry a nonempty choice and repeated finish.
        }
        if let details = delta["reasoning_details"] {
            guard let blocks = details as? [[String: Any]] else { throw ModelError.protocolViolation("Incompatible reasoning_details format") }
            reasoningDetails += try blocks.map { try ProviderCore.JSONValue(any: $0) }
        }
        if let fragment = delta["reasoning_content"] as? String {
            originalReasoningContent = (originalReasoningContent ?? "") + fragment
        }
        var output: [ModelEvent] = []
        let readable = reasoning.consume(delta); visibleReasoning += readable; if !readable.isEmpty { output.append(.reasoning(readable)) }
        if let value = delta["content"] as? String, !value.isEmpty { text += value; output.append(.text(value)) }
        for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = fragment["index"] as? Int, index >= 0 else { throw ModelError.protocolViolation("A tool fragment is missing its index") }
            var p = partial[index] ?? Partial()
            if let id = fragment["id"] as? String { guard p.id.isEmpty || p.id == id else { throw ModelError.protocolViolation("Conflicting tool IDs") }; p.id = id }
            if let f = fragment["function"] as? [String: Any] { p.name += f["name"] as? String ?? ""; p.arguments += f["arguments"] as? String ?? "" }
            partial[index] = p
        }
        if let finish = choice["finish_reason"] as? String { reason = ModelFinishReason(rawValue: finish) ?? .unknown; sawTerminal = true }
        return output
    }
    public mutating func finish(previousCallIDs: Set<String> = []) throws -> [ModelEvent] {
        guard sawTerminal, reason == .stop || reason == .toolCalls else { throw ModelError.protocolViolation("The model stream did not finish successfully. No retry was made.") }
        let calls = partial.keys.sorted().map { key in let p = partial[key]!; return ModelToolCall(id: p.id, name: p.name, arguments: p.arguments) }
        if reason == .toolCalls, calls.isEmpty { throw ModelError.protocolViolation("A tool call is missing arguments. The request was not repeated.") }
        try Self.validate(calls, previousCallIDs: previousCallIDs)
        return calls.map(ModelEvent.toolCall) + [.finish(reason: calls.isEmpty ? reason : .toolCalls, usage: usage)]
    }
    public mutating func finalResponse(request: ModelRequest, providerName: String, scope: ProviderScope) throws -> ModelResponse {
        let calls = try finish(previousCallIDs: Set(request.messages.flatMap { $0.toolCalls ?? [] }.map(\.id))).compactMap { if case .toolCall(let call) = $0 { return call }; return nil }
        return ModelResponse(text: text, reasoning: visibleReasoning.isEmpty ? nil : visibleReasoning, finishReason: calls.isEmpty ? reason : .toolCalls,
                             usage: usage, toolCalls: calls, request: request, providerName: providerName,
                             replayState: reasoningDetails.isEmpty && originalReasoningContent == nil ? nil : .init(scope: scope, reasoningDetails: reasoningDetails, reasoningContent: originalReasoningContent))
    }
    public static func validate(_ calls: [ModelToolCall], previousCallIDs: Set<String> = []) throws {
        try ToolBatchValidator.validate(calls, previousCallIDs: previousCallIDs)
    }
}
