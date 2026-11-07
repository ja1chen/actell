import Foundation
import ProviderCore
import OpenAI

public enum OpenAIWireProtocol: String, Sendable { case chatCompletions, responses }
/// The only layer importing MacPaw DTOs. Both SDK and raw extension fields stay here.
public struct OpenAIWireCodec: Sendable {
    public let configuration: ProviderConfiguration
    public let wire: OpenAIWireProtocol
    public let capabilities: ProviderCapabilities
    public let scope: ProviderScope
    public init(configuration: ProviderConfiguration, wire: OpenAIWireProtocol = .chatCompletions, scope: ProviderScope? = nil, capabilities: ProviderCapabilities = .init()) {
        self.configuration = configuration; self.wire = wire; self.capabilities = capabilities
        self.scope = scope ?? ProviderScope(provider: configuration.name, endpoint: configuration.baseURL.absoluteString, account: "", model: configuration.defaultModel ?? "", session: UUID())
    }
    public func prepareRequest(_ original: ModelRequest, stream: Bool) throws -> URLRequest {
        var request = original
        if wire == .chatCompletions, let input = original.input {
            request.messages = try chatMessages(input, instructions: original.instructions)
            request.input = nil
        }
        guard scope.model.isEmpty || request.model == scope.model else { throw ModelError.protocolViolation("Request model scope mismatch") }
        if wire == .responses && !capabilities.responseChain {
            guard request.storage == .none, request.context == .stateless else { throw ModelError.unsupportedCapability("Endpoint supports stateless Responses only") }
        }
        try preflight(request)
        guard request.execution == .foreground else { throw ModelError.unsupportedCapability("Background generation is not implemented") }
        guard case .conversation = request.context else { return try prepareForeground(request, stream: stream) }
        throw ModelError.unsupportedCapability("Conversations are not implemented")
    }
    private func preflight(_ request: ModelRequest) throws {
        var bytes = 4096
        func add(_ content: [ModelInputContent]) throws {
            for value in content {
                switch value {
                case .text(let text): bytes += text.utf8.count * 2
                case .image(let image): bytes += (try image.bytes()).count * 4 / 3 + 1024
                }
                guard bytes <= 24 * 1024 * 1024 else { throw ModelError.invalidRequest("模型请求超过 24 MiB 限制") }
            }
        }
        if let input = request.input {
            for item in input {
                switch item {
                case .message(_, let content): try add(content)
                case .functionResult(_, let text): bytes += text.utf8.count * 2
                case .replay(let output): bytes += try JSONEncoder().encode(output).count
                case .compacted(let item): bytes += try JSONEncoder().encode(item).count
                case .chatReplayState(let item): bytes += try JSONEncoder().encode(item).count
                }
                guard bytes <= 24 * 1024 * 1024 else { throw ModelError.invalidRequest("模型请求超过 24 MiB 限制") }
            }
        } else {
            let last = request.messages.lastIndex { $0.role != .user && !$0.images.isEmpty }
            for (index, message) in request.messages.enumerated() {
                try add([.text(message.content)] + ((message.role == .user || index == last) ? message.images.map(ModelInputContent.image) : []))
            }
        }
    }
    private func prepareForeground(_ request: ModelRequest, stream: Bool) throws -> URLRequest {
        var result = URLRequest(url: configuration.baseURL.appendingPathComponent(wire == .responses ? "responses" : "chat/completions"))
        guard configuration.baseURL.scheme == "https", configuration.baseURL.user == nil, configuration.baseURL.password == nil else { throw ModelError.invalidRequest("HTTPS endpoint required") }
        result.httpMethod = "POST"; result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = configuration.apiKey, !key.isEmpty { result.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        result.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if wire == .chatCompletions {
            guard request.storage == .none, request.context == .stateless else { throw ModelError.unsupportedCapability("Chat Completions has no Responses continuation") }
            let query = try chatQuery(request, stream: stream)
            var envelope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as! [String: Any]
            var encodedMessages = envelope["messages"] as! [[String: Any]]
            let assistants = request.messages.filter { $0.role == .assistant }
            var index = 0
            for i in encodedMessages.indices where encodedMessages[i]["role"] as? String == "assistant" {
                if let state = assistants[index].replayState {
                    let details = try state.reasoningDetailsForReplay(scope: scope)
                    if !details.isEmpty { encodedMessages[i]["reasoning_details"] = details.map(\.foundation) }
                    if capabilities.chatReasoningContentReplay, !request.tools.isEmpty,
                       let original = try state.reasoningContentForReplay(scope: scope) {
                        encodedMessages[i]["reasoning_content"] = original
                    }
                }
                index += 1
            }
            envelope["messages"] = encodedMessages
            result.httpBody = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        } else {
            let items = try request.input ?? ModelInputProjection.input(messages: request.messages)
            let objects = try items.map(inputObject)
            let previous: String?
            switch request.context {
            case .stateless: previous = nil
            case .previousResponse(let handle):
                guard handle.scope == scope, request.storage == .responseChain else { throw ModelError.protocolViolation("Continuation scope/storage mismatch") }
                previous = handle.value
            case .conversation: throw ModelError.unsupportedCapability("Conversations are not implemented")
            }
            let tools: [Tool] = try request.tools.map { tool in
                try JSONDecoder().decode(Tool.self, from: JSONSerialization.data(withJSONObject: ["type": "function", "name": tool.name, "description": tool.description, "parameters": tool.parameters, "strict": false]))
            }
            let query = CreateModelResponseQuery(input: .inputItemList([]), model: request.model,
                include: [.init(rawValue: "reasoning.encrypted_content")!],
                instructions: request.instructions ?? request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n"),
                maxOutputTokens: request.maxTokens, parallelToolCalls: true, previousResponseId: previous,
                reasoning: try request.reasoningEffort.map { effort in
                    try JSONDecoder().decode(Components.Schemas.Reasoning.self, from: JSONSerialization.data(withJSONObject: ["effort": effort.rawValue]))
                },
                store: request.storage == .responseChain, stream: stream, temperature: request.temperature,
                tools: tools.isEmpty ? nil : tools, topP: request.topP)
            var envelope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as! [String: Any]
            envelope["input"] = objects
            result.httpBody = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        if let policy = request.cachePolicy, let data = result.httpBody, var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let key = policy.key { body["prompt_cache_key"] = key }
            if let retention = policy.retention { body["prompt_cache_retention"] = retention }
            result.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        guard (result.httpBody?.count ?? 0) <= 24 * 1024 * 1024 else { throw ModelError.invalidRequest("模型请求超过 24 MiB 限制") }
        return result
    }
    private func chatQuery(_ request: ModelRequest, stream: Bool) throws -> ChatQuery {
        var messages: [ChatQuery.ChatCompletionMessageParam] = []
        for m in request.messages {
            let images = m.images
            switch m.role {
            case .system: messages.append(.system(.init(content: .textContent(m.content))))
            case .user: messages.append(try userMessage(m.content, images: images))
            case .assistant:
                let calls = (m.toolCalls ?? []).map { ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam(id: $0.id, function: .init(arguments: $0.arguments, name: $0.name)) }
                messages.append(.assistant(.init(content: .textContent(m.content), toolCalls: calls.isEmpty ? nil : calls)))
            case .tool:
                guard let id = m.toolCallId else { throw ModelError.invalidRequest("Tool result missing ID") }
                messages.append(.tool(.init(content: .textContent(m.content), toolCallId: id)))
                if !images.isEmpty { messages.append(try userMessage("Tool observation", images: images)) }
            }
        }
        let tools = try request.tools.map { tool in
            ChatQuery.ChatCompletionToolParam(function: .init(name: tool.name, description: tool.description,
                parameters: try JSONDecoder().decode(JSONSchema.self, from: JSONEncoder().encode(tool.schema)), strict: false))
        }
        return ChatQuery(messages: messages, model: request.model, reasoningEffort: request.reasoningEffort.map { .customValue($0.rawValue) }, maxCompletionTokens: request.maxTokens,
            parallelToolCalls: true, store: false, temperature: request.temperature, tools: tools.isEmpty ? nil : tools,
            topP: request.topP, stream: stream, streamOptions: stream ? .init(includeUsage: true) : nil)
    }
    private func userMessage(_ text: String, images: [ModelImage]) throws -> ChatQuery.ChatCompletionMessageParam {
        if images.isEmpty { return .user(.init(content: .string(text))) }
        let parts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = [.text(.init(text: text))]
            + (try images.map { .image(.init(imageUrl: .init(url: try imageURL($0), detail: .auto))) })
        return .user(.init(content: .contentParts(parts)))
    }
    private func imageURL(_ image: ModelImage) throws -> String { "data:\(image.mimeType);base64," + (try image.bytes()).base64EncodedString() }
    private func chatContent(_ text: String, images: [ModelImage]) throws -> [[String: Any]] {
        [["type": "text", "text": text]] + (try images.map { ["type": "image_url", "image_url": ["url": try imageURL($0), "detail": "auto"]] })
    }
    public func inputObject(_ item: ModelInputItem) throws -> [String: Any] {
        switch item {
        case .message(let role, let content):
            guard role != .system else { throw ModelError.invalidRequest("System instructions belong in instructions") }
            if role == .assistant {
                return ["type": "message", "role": "assistant", "status": "completed", "content": content.compactMap { if case .text(let t) = $0 { return ["type": "output_text", "text": t, "annotations": [], "logprobs": []] as [String: Any] }; return nil }]
            }
            return ["type": "message", "role": "user", "content": try content.map { value -> [String: Any] in
                switch value { case .text(let t): return ["type": "input_text", "text": t]; case .image(let i): return ["type": "input_image", "image_url": try imageURL(i), "detail": "auto"] }
            }]
        case .functionResult(let id, let output): return ["type": "function_call_output", "call_id": id, "output": output]
        case .chatReplayState: throw ModelError.unsupportedCapability("Chat replay state cannot enter Responses input")
        case .compacted(let item):
            guard item.scope == scope, let payload = item.payload.foundation as? [String: Any], payload["type"] as? String == item.type else { throw ModelError.protocolViolation("Compacted input scope/type mismatch") }
            try Self.validateCompactedInput(payload)
            return payload
        case .replay(let output):
            _ = try output.asReplayInput(scope: scope)
            switch output {
            case .message(let m):
                var o: [String: Any] = ["type": "message", "id": m.id, "role": "assistant", "status": "completed", "content": m.content.map { content -> [String: Any] in
                    switch content { case .text(let t, let a): return ["type": "output_text", "text": t, "annotations": a.map(\.foundation), "logprobs": []]; case .refusal(let t): return ["type": "refusal", "refusal": t] }
                }]; if let phase = m.phase { o["phase"] = phase }; for (key, value) in m.extra { o[key] = value.foundation }; return o
            case .functionCall(let c):
                var o: [String: Any] = ["type": "function_call", "call_id": c.id, "name": c.name, "arguments": c.arguments, "status": "completed"]; if let id = c.itemID { o["id"] = id }; for (key, value) in c.extra ?? [:] { o[key] = value.foundation }; return o
            case .reasoning(let r):
                guard r.scope == nil || r.scope == scope else { throw ModelError.protocolViolation("Reasoning scope mismatch") }
                var o: [String: Any] = ["type": "reasoning", "id": r.id, "summary": r.summary.map { ["type": "summary_text", "text": $0] }]
                if let encrypted = r.encryptedContentForReplay { o["encrypted_content"] = encrypted }; for (key, value) in r.extra { o[key] = value.foundation }; return o
            case .compaction(let c):
                var object = c.extra.mapValues(\.foundation)
                object["type"] = "compaction"; object["encrypted_content"] = c.encryptedContentForReplay
                if let id = c.id { object["id"] = id }; return object
            case .unknown, .providerOwned: throw ModelError.unsupportedCapability("Unknown/hosted output cannot be replayed")
            }
        }
    }
    public func parseResponse(_ data: Data, request: ModelRequest) throws -> ModelResponse {
        guard data.count <= 4 * 1024 * 1024 else { throw ModelError.protocolViolation("Response size limit") }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ModelError.invalidResponse("Invalid model response") }
        if wire == .responses { return try nativeResponse(object, request: request) }
        guard var choices = object["choices"] as? [[String: Any]], !choices.isEmpty, let message = choices[0]["message"] as? [String: Any] else { throw ModelError.invalidResponse("Chat Completions response required") }
        let wireCalls = message["tool_calls"] as? [[String: Any]] ?? []
        guard wireCalls.allSatisfy({ ($0["id"] as? String)?.isEmpty == false }) else { throw ModelError.protocolViolation("Tool call missing original ID") }
        // Compatible gateways may omit envelope metadata; only fill fields that
        // cannot affect execution. IDs/arguments are never synthesized.
        object["id"] = object["id"] ?? request.id.uuidString; object["created"] = object["created"] ?? 0; object["model"] = object["model"] ?? request.model; object["object"] = object["object"] ?? "chat.completion"
        choices[0]["index"] = choices[0]["index"] ?? 0
        choices[0]["message"] = ReadableReasoningDecoder.removingFields(from: message); object["choices"] = choices
        let sdk = try JSONDecoder().decode(ChatResult.self, from: JSONSerialization.data(withJSONObject: object))
        let calls = wireCalls.map { c -> ModelToolCall in
            let f = c["function"] as? [String: Any] ?? [:]
            return ModelToolCall(id: c["id"] as? String ?? "", name: f["name"] as? String ?? "", arguments: f["arguments"] as? String ?? "")
        }
        try ToolBatchValidator.validate(calls, previousCallIDs: Set(request.messages.flatMap { $0.toolCalls ?? [] }.map(\.id)))
        let reason = ModelFinishReason(rawValue: choices[0]["finish_reason"] as? String ?? "") ?? .unknown
        guard reason == .stop || reason == .toolCalls else { throw ModelError.protocolViolation("Chat response did not complete successfully") }
        let details = try (message["reasoning_details"] as? [[String: Any]])?.map { try JSONValue(any: $0) }
        let originalReasoningContent = message["reasoning_content"] as? String
        let replay: ScopedChatReplayState? = details?.isEmpty == false || originalReasoningContent != nil
            ? .init(scope: scope, reasoningDetails: details ?? [], reasoningContent: originalReasoningContent) : nil
        return ModelResponse(text: sdk.choices.first?.message.content ?? "", reasoning: ReadableReasoningDecoder.text(in: message), finishReason: reason, usage: Self.usage(object["usage"] as? [String: Any]), toolCalls: calls, request: request, providerName: configuration.name, replayState: replay)
    }
    public func nativeResponse(_ object: [String: Any], request: ModelRequest) throws -> ModelResponse {
        guard let id = object["id"] as? String, !id.isEmpty, let rawStatus = object["status"] as? String, let output = object["output"] as? [[String: Any]] else { throw ModelError.protocolViolation("Response envelope missing ID/status/output") }
        let status = ResponseStatus(rawValue: rawStatus) ?? .unknown
        let items = try output.map { try outputItem($0) }
        let ids = output.compactMap { $0["id"] as? String }
        guard ids.count == output.count, Set(ids).count == ids.count else { throw ModelError.protocolViolation("Output item IDs missing/duplicated") }
        let calls = items.compactMap { if case .functionCall(let c) = $0 { return c }; return nil }
        if status == .completed { try ToolBatchValidator.validate(calls, previousCallIDs: Set(request.messages.flatMap { $0.toolCalls ?? [] }.map(\.id))) }
        let e = object["error"] as? [String: Any]
        let error = e.map { APIErrorInfo(code: $0["code"] as? String ?? "unknown", message: "模型返回失败；没有自动重试") }
        let known: Set<String> = ["id", "model", "status", "output", "usage", "error", "incomplete_details"]
        let extra = try object.filter { !known.contains($0.key) }.mapValues { try JSONValue(any: $0) }
        return ModelResponse(id: id, model: object["model"] as? String ?? request.model, status: status, scope: scope, output: items, usage: Self.usage(object["usage"] as? [String: Any]), error: error, incomplete: try object["incomplete_details"].map { try JSONValue(any: $0) }, extra: extra, request: request, providerName: configuration.name)
    }
    public func outputItem(_ object: [String: Any]) throws -> ModelOutputItem {
        guard let type = object["type"] as? String else { throw ModelError.protocolViolation("Output missing type") }
        if type == "compaction" {
            guard let encrypted = object["encrypted_content"] as? String, !encrypted.isEmpty else { throw ModelError.protocolViolation("Compaction missing encrypted content") }
            return .compaction(.init(id: object["id"] as? String, encryptedContent: encrypted, scope: scope, extra: try object.filter { !["type", "id", "encrypted_content"].contains($0.key) }.mapValues { try JSONValue(any: $0) }))
        }
        guard ["message", "reasoning", "function_call"].contains(type) else { return .unknown(.init(type: type, payload: try JSONValue(any: object), scope: scope)) }
        // Decode with the fixed MacPaw schema to reject malformed known items.
        var sdkObject = object
        if type == "reasoning", let content = object["content"] {
            guard let parts = content as? [[String: Any]], parts.allSatisfy({ $0["type"] as? String == "reasoning_text" && $0["text"] is String }) else {
                throw ModelError.protocolViolation("Invalid reasoning text content")
            }
            // DeepSeek returns plain reasoning content without an OpenAI summary.
            // Normalize only the SDK validation copy; preserve native content for replay.
            if object["summary"] == nil { sdkObject["summary"] = [] }
        }
        if type == "message", var content = object["content"] as? [[String: Any]] {
            for i in content.indices where content[i]["type"] as? String == "output_text" {
                // SDK 0.5.2 models absent logprobs as a required array.
                if content[i]["logprobs"] == nil || content[i]["logprobs"] is NSNull { content[i]["logprobs"] = [] }
            }
            sdkObject["content"] = content
        }
        _ = try JSONDecoder().decode(OutputItem.self, from: JSONSerialization.data(withJSONObject: sdkObject))
        guard let id = object["id"] as? String, !id.isEmpty else { throw ModelError.protocolViolation("Output missing item ID") }
        let itemStatus = (object["status"] as? String).map { ResponseStatus(rawValue: $0) ?? .unknown }
        switch type {
        case "function_call":
            guard let callID = object["call_id"] as? String, let name = object["name"] as? String, let args = object["arguments"] as? String else { throw ModelError.protocolViolation("Incomplete function call") }
            return .functionCall(.init(id: callID, itemID: id, name: name, arguments: args, status: itemStatus, extra: try object.filter { !["id", "type", "status", "call_id", "name", "arguments"].contains($0.key) }.mapValues { try JSONValue(any: $0) }, scope: scope))
        case "reasoning":
            let summary = (object["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            return .reasoning(.init(id: id, summary: summary, encryptedContent: object["encrypted_content"] as? String, scope: scope,
                extra: try object.filter { !["id", "type", "summary", "encrypted_content"].contains($0.key) }.mapValues { try JSONValue(any: $0) }))
        default:
            let content = try (object["content"] as? [[String: Any]] ?? []).map { c -> ModelOutputContent in
                switch c["type"] as? String {
                case "output_text": guard let text = c["text"] as? String else { throw ModelError.protocolViolation("Output text missing") }; return .text(text, annotations: try (c["annotations"] as? [Any] ?? []).map { try JSONValue(any: $0) })
                case "refusal": guard let text = c["refusal"] as? String else { throw ModelError.protocolViolation("Refusal missing") }; return .refusal(text)
                default: throw ModelError.unsupportedCapability("Unsupported output content")
                }
            }
            return .message(.init(id: id, content: content, phase: object["phase"] as? String, status: itemStatus ?? .completed, extra: try object.filter { !["id", "type", "role", "content", "status", "phase"].contains($0.key) }.mapValues { try JSONValue(any: $0) }, scope: scope))
        }
    }
    public static func usage(_ object: [String: Any]?) -> ModelUsage? {
        guard let o = object else { return nil }
        return ModelUsage(promptTokens: o["input_tokens"] as? Int ?? o["prompt_tokens"] as? Int,
            completionTokens: o["output_tokens"] as? Int ?? o["completion_tokens"] as? Int, totalTokens: o["total_tokens"] as? Int,
            cachedTokens: (o["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? (o["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? o["prompt_cache_hit_tokens"] as? Int,
            reasoningTokens: (o["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? (o["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int,
            cacheWriteTokens: (o["input_tokens_details"] as? [String: Any])?["cache_write_tokens"] as? Int ?? (o["prompt_tokens_details"] as? [String: Any])?["cache_write_tokens"] as? Int)
    }
}
