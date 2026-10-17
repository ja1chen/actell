import Foundation
import OSLog
import CryptoKit
import Security
import SwiftAgentKit
import ProviderCore
import OpenAIAdapter

/// Agent re-encodes parameter dictionaries each turn. Stabilize only their JSON
/// representation before checkpointing; retain call identity, metadata and values.
enum PortableContextRequest {
    static func normalized(_ original: ModelRequest) throws -> ModelRequest {
        var request = original
        request.messages = try original.messages.map { originalMessage in
            var message = originalMessage
            message.toolCalls = try originalMessage.toolCalls?.map { call in
                guard let object = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any] else {
                    throw ModelError.invalidRequest("Tool arguments must be a JSON object")
                }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                return ModelToolCall(id: call.id, itemID: call.itemID, name: call.name,
                                     arguments: String(decoding: data, as: UTF8.self), providerMetadata: call.providerMetadata,
                                     status: call.status, extra: call.extra, scope: call.scope)
            }
            return message
        }
        return request
    }
}

/// Runtime owns continuation state; the SDK adapter only encodes/decodes each call.
final class PrivateVisionProvider: ModelProvider, @unchecked Sendable {
    static let name = "private-openai-compatible"
    let configuration: ProviderConfiguration
    private let codec: OpenAIWireCodec
    private let transport: ResponsesTransport
    private let context: ContextCoordinator?
    private let providerKind: ProviderKind
    private let parameterFields: [String: Any]
    init(settings: ProviderSettings, apiKey: String, limits: AgentLimits,
         providerKind: ProviderKind = .openAI, parameters: ModelParameters = ModelParameters(), metadata: DiscoveredModel? = nil,
         inferenceAPI: InferenceAPI = .chatCompletions, contextPolicy: ProviderContextPolicy = .stateless, accountReference: String = "",
         runID: UUID = UUID(), branchID: UUID = UUID(), checkpointFile: URL? = nil, transport: ResponsesTransport? = nil) throws {
        // A plain bearer/API key must never impersonate a subscription grant.
        guard providerKind != .chatGPTSubscription else { throw AppError.unavailable(ChatGPTSubscriptionPolicy.mobileLoginNotice) }
        let endpoint = try providerKind.inferenceBase(settings.baseURL)
        guard !settings.model.isEmpty else { throw AppError.invalid(String(localized: "Select a model first")) }
        guard !apiKey.isEmpty || providerKind == .ollama else { throw AppError.invalid(String(localized: "Set the model API key first")) }
        guard inferenceAPI == .chatCompletions || providerKind.supportsResponses else { throw AppError.invalid(String(localized: "Responses inference has not been verified for this provider protocol")) }
        guard inferenceAPI == .responses || contextPolicy == .stateless else { throw AppError.invalid(String(localized: "History continuation only supports Responses")) }
        guard contextPolicy == .stateless || providerKind.supportsResponseChain else { throw AppError.invalid(String(localized: "This provider's Responses API only supports stateless requests")) }
        self.providerKind = providerKind
        var fields = try parameters.requestFields(providerKind: providerKind, model: metadata)
        if inferenceAPI == .responses {
            if let effort = fields.removeValue(forKey: "reasoning_effort") { fields["reasoning"] = ["effort": effort] }
            guard fields["seed"] == nil else { throw AppError.invalid(String(localized: "Responses does not support the seed parameter. Clear it before saving.")) }
            if let n = fields.removeValue(forKey: "max_tokens") ?? fields.removeValue(forKey: "max_completion_tokens") { fields["max_output_tokens"] = n }
        }
        parameterFields = fields
        configuration = ProviderConfiguration(name: Self.name, baseURL: endpoint, apiKey: apiKey, defaultModel: settings.model)
        let scope = ProviderScope(provider: providerKind.rawValue + ":" + Self.name, endpoint: endpoint.absoluteString, account: accountReference, model: settings.model, run: runID, branch: branchID)
        codec = OpenAIWireCodec(configuration: configuration, wire: inferenceAPI == .responses ? .responses : .chatCompletions, scope: scope, capabilities: .init(responseChain: providerKind.supportsResponseChain))
        self.transport = transport ?? ResponsesTransport()
        context = inferenceAPI == .responses ? try ContextCoordinator(scope: scope, storage: contextPolicy == .responseChain ? .responseChain : .none, checkpointFile: checkpointFile) : nil
    }
    func capabilities(for model: String) async throws -> ProviderCapabilities {
        guard model == configuration.defaultModel else { throw ModelError.unsupportedCapability(String(localized: "Model capabilities have not been verified")) }
        return .init(responseChain: codec.wire == .responses && providerKind.supportsResponseChain)
    }
    func cancel() {
        // A persistence failure still cancels transport; the App's durable action
        // journal independently fences dispatch and forbids restart replay.
        try? context?.cancel()
        transport.cancel()
    }
    func prepareRequest(_ request: ModelRequest, stream: Bool) throws -> URLRequest {
        let actual = try context?.prepare(PortableContextRequest.normalized(request)).request ?? request
        return try wireRequest(actual, stream: stream)
    }
    private func wireRequest(_ request: ModelRequest, stream: Bool) throws -> URLRequest {
        var explicit = request
        explicit.temperature = nil; explicit.topP = nil; explicit.maxTokens = nil; explicit.reasoningEffort = nil
        var value = try codec.prepareRequest(explicit, stream: stream)
        if let data = value.httpBody, var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if providerKind == .ollama { object.removeValue(forKey: "parallel_tool_calls") }
            for (key, field) in parameterFields { object[key] = field }
            value.httpBody = try JSONSerialization.data(withJSONObject: object)
            guard (value.httpBody?.count ?? 0) <= 24 * 1024 * 1024 else { throw AppError.invalid(String(localized: "The model request exceeds the 24 MiB limit")) }
        }
        return value
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task {
                let attempt = UUID()
                var stage = "context.prepare", shape = "event=none"
                do {
                    try Task.checkCancellation()
                    let prepared = try context?.prepare(PortableContextRequest.normalized(request))
                    let actual = prepared?.request ?? request
                    stage = "request.encode"
                    let outgoing = try wireRequest(actual, stream: true)
                    stage = "stream.receive"
                    if codec.wire == .responses {
                        var reducer = ResponsesReducer(codec: codec, request: actual)
                        for try await payload in transport.payloads(outgoing) {
                            shape = LLMDiagnostics.eventShape(payload)
                            stage = "event.reduce"
                            try Task.checkCancellation()
                            let events: [ModelEvent]
                            do { events = try reducer.consume(payload: payload); try context?.recordStream(reducer.checkpoint) }
                            catch { try? context?.recordStream(reducer.checkpoint, force: true); throw error }
                            for event in events {
                                if case .terminal(let response) = event {
                                    stage = "terminal.validate"
                                    try ResponsesReducer.requireExecutable(response)
                                    try Task.checkCancellation()
                                    if let prepared { try context?.commit(response, prepared: prepared) }
                                }
                                if case .dropped = continuation.yield(event) { throw ModelError.protocolViolation(String(localized: "The model output buffer exceeds the limit")) }
                            }
                            if reducer.response != nil { break }
                            stage = "stream.receive"
                        }
                        try context?.recordStream(reducer.checkpoint, force: true)
                        stage = "stream.finish"
                        _ = try reducer.finish()
                    } else {
                        var decoder = ModelStreamDecoder()
                        for try await payload in transport.payloads(outgoing) {
                            try Task.checkCancellation()
                            shape = LLMDiagnostics.eventShape(payload)
                            stage = "event.decode"
                            for event in try decoder.consume(line: "data: " + payload, request: request) { continuation.yield(event) }
                            if decoder.sawDone { break }
                            stage = "stream.receive"
                        }
                        stage = "terminal.validate"
                        let terminal = try decoder.finalResponse(request: request, providerName: Self.name, scope: codec.scope)
                        if case .dropped = continuation.yield(.terminal(terminal)) { throw ModelError.protocolViolation(String(localized: "The model output buffer exceeds the limit")) }
                    }
                    continuation.finish()
                } catch {
                    LLMDiagnostics.log(error, stage: stage, attempt: attempt, shape: shape)
                    continuation.finish(throwing: Self.safeFailure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let attempt = UUID()
        var stage = "context.prepare"
        do {
            try Task.checkCancellation()
            let prepared = try context?.prepare(PortableContextRequest.normalized(request))
            let actual = prepared?.request ?? request
            stage = "request.encode"
            let outgoing = try wireRequest(actual, stream: false)
            stage = "request.receive"
            let data = try await transport.complete(outgoing)
            stage = "response.decode"
            let result = try parseResponse(data, request: actual)
            if let prepared {
                try ResponsesReducer.requireExecutable(result); try Task.checkCancellation()
                try context?.commit(result, prepared: prepared)
            }
            return result
        } catch {
            LLMDiagnostics.log(error, stage: stage, attempt: attempt)
            throw Self.safeFailure(error)
        }
    }
    private static func safeFailure(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        // Permanent at the runtime boundary: never regenerate an accepted/unknown
        // request automatically. Raw SDK errors may include payloads, so redact them.
        if let e = error as? ModelError { return e }
        if let e = error as? AppError { return ModelError.invalidRequest(e.localizedDescription) }
        return ModelError.interrupted
    }
    func parseResponse(_ data: Data, request: ModelRequest) throws -> ModelResponse {
        guard codec.wire == .chatCompletions else { return try codec.parseResponse(data, request: request) }
        guard var o = try JSONSerialization.jsonObject(with: data) as? [String: Any], var choices = o["choices"] as? [[String: Any]], !choices.isEmpty, let m = choices[0]["message"] as? [String: Any] else { throw AppError.invalid(String(localized: "Incompatible Chat Completions response format")) }
        choices[0]["message"] = ReadableReasoningDecoder.removingFields(from: m); o["choices"] = choices
        let parsed = try codec.parseResponse(JSONSerialization.data(withJSONObject: o), request: request)
        let details = try (m["reasoning_details"] as? [[String: Any]])?.map { try ProviderCore.JSONValue(any: $0) }
        return ModelResponse(text: parsed.text, reasoning: ReadableReasoningDecoder.text(in: m), finishReason: parsed.finishReason, usage: parsed.usage, toolCalls: parsed.toolCalls, request: request, providerName: Self.name, replayState: details.map { .init(scope: codec.scope, reasoningDetails: $0) })
    }
}
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
// Deterministic in-process test provider. It does not make HTTP requests and
// only controls DemoBridge's synthetic image. Never presents itself as a model.
struct DemoProvider: ModelProvider {
    static let name = "offline-scripted-demo"
    let configuration = ProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "demo")
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    // One honest scripted message, not a simulated token stream.
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finish(reason: response.finishReason, usage: nil))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try Task.checkCancellation(); try await Task.sleep(nanoseconds: 350_000_000)
        let calls = request.messages.flatMap { $0.toolCalls ?? [] }
        let stage = calls.count
        if stage >= 3, !request.tools.contains(where: { $0.name == "finish" }) {
            return ModelResponse(text: String(localized: "The simulated test is complete."), finishReason: .stop, request: request, providerName: Self.name)
        }
        let call: ModelToolCall
        switch stage {
        case 0: call = ModelToolCall(name: "screenshot", arguments: "{}")
        case 1:
            let arguments: [String: Any] = ["x": 195, "y": 380, "purpose": String(localized: "Tap the demo counter on the simulated screen")]
            call = ModelToolCall(name: "tap", arguments: String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!)
        case 2: call = ModelToolCall(name: "screenshot", arguments: "{}")
        default:
            let summary = String(localized: "Offline demo complete: one simulated tap was confirmed and the simulated screenshot was refreshed. No real device was connected or controlled.")
            let arguments = try JSONSerialization.data(withJSONObject: ["summary": summary])
            call = ModelToolCall(name: "finish", arguments: String(decoding: arguments, as: UTF8.self))
        }
        let narration = [String(localized: "This is an offline scripted demo. I will view the simulated screen first."), String(localized: "Next, I will demonstrate a tap. Confirm the action in the tool card."), String(localized: "The tap returned. I will get a new simulated screenshot to check the result."), String(localized: "The demo is complete. No model or real device was connected or controlled.")]
        return ModelResponse(text: narration[min(stage, 3)], finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
    }
}

#if DEBUG
/// Public synthetic fixture only; never imitates a remote model's private state.
struct ReasoningFixtureProvider: ModelProvider {
    static let name = "synthetic-readable-reasoning"
    static let first = "合成思考第一段。"
    static let second = "合成思考第二段。"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    var outcome = "completed"
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(text: "合成答复。", reasoning: Self.first + Self.second, finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.reasoning(Self.first))
                    try await Task.sleep(for: .milliseconds(150))
                    continuation.yield(.reasoning(Self.second))
                    if outcome == "paused" { try await Task.sleep(for: .seconds(60)) }
                    if outcome == "failed" { throw ModelError.invalidRequest("合成服务中断") }
                    continuation.yield(.text("合成答复。"))
                    continuation.yield(.finish(reason: .stop, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
struct SkillFixtureProvider: ModelProvider {
    static let name = "offline-skill-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let response = try response(request)
                for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { try response(request) }
    private func response(_ request: ModelRequest) throws -> ModelResponse {
        let results = request.messages.filter { $0.role == .tool }
        let call: ModelToolCall
        if results.isEmpty {
            let system = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
            guard let metadata = system.components(separatedBy: "\n").first(where: { $0.hasPrefix("[{") }),
                  let skills = try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [[String: String]],
                  let skill = skills.first(where: { $0["name"] == "Synthetic Guide" }) ?? skills.first,
                  let id = skill["id"], let revision = skill["revision"] else { throw AppError.invalid("合成夹具未找到已启用技能") }
            call = .init(id: "fixture-skill-load", name: "load_skill", arguments: String(decoding: try JSONEncoder().encode(["id": id, "revision": revision]), as: UTF8.self))
        } else {
            guard results.last?.content.contains("SYNTHETIC_SKILL_BODY") == true else { throw AppError.invalid("合成夹具没有收到技能正文") }
            return ModelResponse(text: "合成技能已读取。", finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: "", finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
    }
}
// Deterministic fixture for the real Agent loop, with no network or credentials.
// Its second turn only answers if the failed tool result actually reaches it.
struct ToolErrorFixtureProvider: ModelProvider {
    static let name = "offline-tool-error-fixture"
    static let reply = "当前尚未授权全屏采集。请先授权 App 采集，再试一次；查看屏幕无需连接 ESP32。"
    var initialText = ""
    var finalReply = Self.reply
    let configuration = ProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finish(reason: response.finishReason, usage: nil))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try Task.checkCancellation()
        if request.messages.contains(where: { $0.role == .tool }) {
            guard request.messages.contains(where: {
                $0.role == .tool && $0.toolCallId == "fixture-screenshot" &&
                $0.content == "[Tool: screenshot] ERROR\n" + UnavailableBridge.screenshotMessage
            }) else { throw AppError.invalid("测试未收到对应工具的完整失败结果") }
            return ModelResponse(text: finalReply, finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: initialText, finishReason: .toolCalls,
            toolCalls: [ModelToolCall(id: "fixture-screenshot", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)
    }
}
#endif

#if DEBUG
/// Finite, offline real-run fixture. It never requests device input.
struct TaskPiPProbeProvider: ModelProvider {
    static let name = "task-pip-probe"
    let configuration = DemoProvider().configuration
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try await Task.sleep(for: .seconds(30))
        return ModelResponse(text: "后台状态验收已结束", finishReason: .stop, request: request, providerName: "task-pip-probe")
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if ProcessInfo.processInfo.arguments.contains("--background-stream-probe") {
                        for _ in 0..<4_500 {
                            try await Task.sleep(for: .milliseconds(20))
                            continuation.yield(.reasoning("离线流式验证。"))
                        }
                        continuation.yield(.text("离线后台流式验证已结束"))
                        continuation.yield(.finish(reason: .stop, usage: nil)); continuation.finish()
                        return
                    }
                    let response = try await complete(request)
                    continuation.yield(.text(response.text))
                    continuation.yield(.finish(reason: .stop, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

/// A successful HTTP status is not proof of a valid inference stream.
/// Retains safe structural fields only, never the response body or headers.
struct LLMUnexpectedResponse: Error, LocalizedError {
    let status: Int, contentType: String, bodyShape: String, truncated: Bool
    let errorCode: String?
    static func mediaType(_ response: HTTPURLResponse) -> String {
        // Foundation lookup is case-insensitive (including HTTP/2 lower-case
        // headers). MIME metadata is a fallback when the header is unavailable.
        if let value = response.value(forHTTPHeaderField: "Content-Type") {
            return value.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? "missing"
        }
        // Foundation can infer text/plain or text/html from the body even with
        // no actual header. Those guesses must not disable the bounded probe.
        return response.mimeType?.lowercased() == "text/event-stream" ? "text/event-stream" : "missing"
    }
    init(response: HTTPURLResponse, body: Data, truncated: Bool) {
        status = response.statusCode; self.truncated = truncated
        let type = Self.mediaType(response)
        let types: Set<String> = ["missing", "application/json", "application/problem+json", "text/html", "text/plain", "text/event-stream", "application/octet-stream"]
        contentType = types.contains(type) ? type : "other"
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String
        let codes: Set<String> = ["invalid_request_error", "unsupported_parameter", "unknown_parameter", "invalid_value", "model_not_found", "permission_denied", "insufficient_permissions", "invalid_api_key", "insufficient_quota", "rate_limit_exceeded", "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"]
        errorCode = code.flatMap { codes.contains($0) ? $0 : nil }
        if body.isEmpty { bodyShape = "empty" }
        else if error != nil { bodyShape = "json-error" }
        else if object?["type"] as? String == "response", object?["output"] is [Any] { bodyShape = "json-response" }
        else if object != nil { bodyShape = "json-object" }
        else if body.starts(with: Data("data:".utf8)) || body.starts(with: Data("event:".utf8)) { bodyShape = "sse-prefix" }
        else { bodyShape = "non-json" }
    }
    var errorDescription: String? {
        String(localized: "The model service did not return an SSE stream (HTTP \(status); type \(contentType); structure \(bodyShape)). This run did not finish and was not retried automatically.") + (errorCode.map { "；" + $0 } ?? "")
    }
}

/// Console diagnostics contain structural metadata and known local error literals
/// only. No server message, raw JSON, text, arguments, identity or bearer credential.
enum LLMDiagnostics {
    private static let logger = Logger(subsystem: "com.ja1chen.PhoneAgent", category: "LLM")
    static func emit(_ line: String) { logger.error("\(line, privacy: .public)") }
    static func log(_ error: Error, stage: String, attempt: UUID = UUID(), shape: String = "event=none") {
        if error is CancellationError || Task.isCancelled { return }
        emit(failure(error, attempt: attempt, stage: stage, shape: shape))
    }
    static func runnerWarning(_ message: String) {
        let kind = message.hasPrefix("Planning failed:") ? "planningFailed" : "runnerWarning"
        emit("[LLM] stage=agent.logger error=" + kind + " detail=redacted#" + fingerprint(message))
    }
    static func toolFailure(_ message: String, attempt: UUID) {
        emit("[LLM] attempt=\(attempt.uuidString) stage=tool.result error=ToolFailure reason=" + safeReason(message))
    }
    private static func safeReason(_ reason: String) -> String {
        reasons.contains(reason) ? reason : "redacted#" + fingerprint(reason)
    }
    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    private static let events: Set<String> = ["response.created", "response.in_progress", "response.output_item.added", "response.output_item.done", "response.output_text.delta", "response.output_text.done", "response.refusal.delta", "response.refusal.done", "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done", "response.reasoning_text.delta", "response.reasoning_text.done", "response.function_call_arguments.delta", "response.function_call_arguments.done", "response.content_part.added", "response.content_part.done", "response.reasoning_summary_part.added", "response.reasoning_summary_part.done", "response.output_text.annotation.added", "response.completed", "response.failed", "response.incomplete", "response.cancelled", "error", "ping", "keepalive"]
    private static let reasons: Set<String> = [
        "401：密钥无效或未提供；请检查此供应商的密钥",
        "403：此密钥无权查看模型；可手动填写已授权的模型 ID",
        "404：模型接口不存在；请核对协议与基础地址，或手动填写模型 ID",
        "429：供应商限流；请稍后刷新，未自动重试",
        "App 列表格式无效",
        "App 标识无效",
        "Arguments done missing full value",
        "Background generation is not implemented",
        "Branch revision conflict",
        "Chat Completions has no Responses continuation",
        "Chat Completions response required",
        "Chat Completions 响应格式不兼容",
        "Chat reasoning scope mismatch",
        "Chat response did not complete successfully",
        "ChatGPT 订阅不接收 API 密钥",
        "ChatGPT 订阅仅支持已核实的思考档位；请清空其它模型参数",
        "Completed response contains failure details",
        "Completed snapshot has missing/conflicting items",
        "Conflicting sequence replay",
        "Continuation scope/storage mismatch",
        "Conversations are not implemented",
        "Delta address missing",
        "Endpoint supports stateless Responses only",
        "Event item address mismatch",
        "Event missing sequence",
        "Function item is not completed",
        "Function scope mismatch",
        "HTTPS endpoint required",
        "Hosted/unknown output is not enabled",
        "Image exceeds byte limit",
        "Incomplete function call",
        "Invalid SSE UTF-8",
        "Invalid arguments delta",
        "Invalid model response",
        "Invalid output address",
        "Invalid reasoning text content",
        "Invalid subscription event",
        "Item done address conflict",
        "JSON nesting limit",
        "Late/out of order response event",
        "Lifecycle missing response ID",
        "Message is not completed",
        "Message scope mismatch",
        "Missing tool results for committed response",
        "Model scope changed",
        "Model scope mismatch",
        "Non-HTTP response",
        "Only completed output can advance head",
        "Opaque scope mismatch",
        "Output item IDs missing/duplicated",
        "Output missing item ID",
        "Output missing type",
        "Output text missing",
        "Provider checkpoint scope/version mismatch",
        "Reasoning scope mismatch",
        "Refusal missing",
        "Response commit scope mismatch",
        "Response envelope missing ID/status/output",
        "Response exceeds 4 MiB",
        "Response scope changed",
        "Response size limit",
        "Responses 尚未支持 seed 参数，请清空后保存",
        "Runtime message coordinator requires portable messages; explicit native context belongs at the wire adapter boundary",
        "SSE event missing type",
        "SSE event size limit",
        "Stream consumer buffer exceeded",
        "Subscription SSE buffer exceeded",
        "Subscription did not return SSE",
        "Subscription request exceeds limit",
        "Subscription requires local stateless foreground context",
        "Subscription stream buffer exceeded",
        "Subscription tool namespace/name mismatch",
        "Subscription tool replay scope changed",
        "Subscription usage unavailable",
        "System instructions belong in instructions",
        "Terminal changed completed item",
        "Terminal missing snapshot",
        "Terminal status/scope mismatch",
        "Tool call missing original ID",
        "Tool result missing ID",
        "Tool result missing call ID",
        "Truncated SSE frame",
        "Unknown output cannot be replayed",
        "Unknown/hosted output cannot be replayed",
        "Unsupported JSON value",
        "Unsupported execution/output item",
        "Unsupported image type",
        "Unsupported output content",
        "reasoning_details 格式不兼容",
        "text 缺失或为空",
        "上下文已改变；不能静默剪链或重放动作，请开始新的任务",
        "供应商返回重定向；为保护密钥未跟随，请直接填写最终基础地址",
        "历史续接仅支持 Responses",
        "合成夹具未找到已启用技能",
        "合成夹具没有收到技能正文",
        "合成服务中断",
        "启动参数无效",
        "启动参数过长",
        "图片未缓存：链接可能已过期或网络不可用。可重试；未缓存的失效图片无法恢复",
        "图片链接不属于此消息",
        "坐标参照已变化；本次动作未发送",
        "工具 ID 冲突",
        "工具参数不完整，已阻止执行",
        "工具片段缺少 index",
        "工具调用 ID 缺失、重复或参数不完整；本批未执行",
        "工具调用缺少参数；没有重复请求",
        "已有输入动作正在执行",
        "技能不存在、已禁用或版本不属于当前运行；请使用本轮系统提示词中的技能元数据",
        "技能分页位置无效",
        "技能工具需要当前运行上下文",
        "拖动时长必须为 100–2000 毫秒",
        "文本过长或含无效字符；未发送任何按键。",
        "旧 Host PSK 需为 64 位十六进制随机密钥",
        "未注册的工具",
        "未知技能工具",
        "模型元数据响应过大，旧缓存已保留",
        "模型分页未取得进展或列表过大；旧缓存已保留",
        "模型列表中有无效 ID",
        "模型列表响应无效",
        "模型列表格式与所选协议不匹配",
        "模型工具调用 ID 缺失或重复；本批未执行，不会重放旧动作",
        "模型接口未返回有效 JSON 对象；请核对协议与基础地址",
        "模型流未成功完成；没有重试",
        "模型流格式不兼容",
        "模型流超过大小限制",
        "模型流返回错误；没有自动重试",
        "模型生成未完成（cancelled）；没有执行工具或自动重试",
        "模型生成未完成（failed）；没有执行工具或自动重试",
        "模型生成未完成（in_progress）；没有执行工具或自动重试",
        "模型生成未完成（incomplete）；没有执行工具或自动重试",
        "模型生成未完成（queued）；没有执行工具或自动重试",
        "模型能力尚未核对",
        "模型请求超过 24 MiB 限制",
        "模型输出缓冲超过限制",
        "正在清理附件，请稍后重试",
        "此供应商 Responses 仅支持无状态请求",
        "此供应商协议尚未验证 Responses 推理",
        "此图源未返回有效图片",
        "此工具只允许带请求上下文调用",
        "此版本没有该文档；只可读取技能包内列出的相对文本路径",
        "流终态冲突",
        "测试未收到对应工具的完整失败结果",
        "等待必须为 1–3000 毫秒",
        "结束后出现新模型输出",
        "缺少点击或拖动所需的坐标参照画面",
        "设备会话已变化；本次动作授权失效，请重新决定下一步",
        "请先在设置中保存独立桥接 PSK；不是 iPhone 配对证书",
        "请先设置模型 API 密钥",
        "请先选择模型",
        "请在会话中选择供应商；原供应商可能已移除",
        "资源路径必须是文本",
        "附件不是 UTF-8 文本",
        "附件或模型选择已改变，请重新发送"
    ]
    private static func atom(_ value: Any?, allowed: Set<String>) -> String {
        guard let value else { return "missing" }
        if value is NSNull { return "null" }
        guard let string = value as? String else { return "invalid-type" }
        return allowed.contains(string) ? string : "unknown#" + fingerprint(string)
    }
    static func eventShape(_ payload: String) -> String {
        if payload == "[DONE]" { return "event=DONE" }
        guard let o = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return "event=invalid-json" }
        var fields = ["event=" + atom(o["type"], allowed: events)]
        for key in ["sequence_number", "output_index", "content_index", "summary_index"] {
            if let n = o[key] as? Int { fields.append(key + "=" + String(n)) }
        }
        let statuses: Set<String> = ["queued", "in_progress", "completed", "incomplete", "failed", "cancelled"]
        func describe(_ item: [String: Any]) -> String {
            "item=" + atom(item["type"], allowed: ["message", "reasoning", "function_call"]) +
            ",status=" + atom(item["status"], allowed: statuses) +
            ",namespace=" + atom(item["namespace"], allowed: ["actell"]) +
            ",hasID=" + String((item["id"] as? String)?.isEmpty == false) +
            ",hasCallID=" + String((item["call_id"] as? String)?.isEmpty == false)
        }
        if let item = o["item"] as? [String: Any] { fields.append(describe(item)) }
        if let response = o["response"] as? [String: Any] {
            fields.append("responseStatus=" + atom(response["status"], allowed: statuses))
            if let output = response["output"] as? [[String: Any]] {
                fields.append("outputCount=" + String(output.count))
                fields.append(output.prefix(8).map(describe).joined(separator: ";"))
            }
        }
        if let choices = o["choices"] as? [[String: Any]] {
            fields.append("wire=chatCompletions choices=\(choices.count)")
            if let choice = choices.first {
                fields.append("finishReason=" + atom(choice["finish_reason"], allowed: ["stop", "tool_calls", "length", "content_filter", "function_call"]))
                if let delta = choice["delta"] as? [String: Any] {
                    fields.append("hasText=" + String(delta["content"] != nil))
                    fields.append("toolFragments=" + String((delta["tool_calls"] as? [Any])?.count ?? 0))
                }
            }
        }
        fields.append("hasServerError=" + String(o["error"] != nil && !(o["error"] is NSNull)))
        return fields.joined(separator: " ")
    }
    static func failure(_ error: Error, attempt: UUID, stage: String, shape: String) -> String {
        let detail: String
        if let model = error as? ModelError {
            let kind: String, reason: String?
            switch model {
            case .protocolViolation(let s): kind = "protocolViolation"; reason = s
            case .invalidResponse(let s): kind = "invalidResponse"; reason = s
            case .invalidRequest(let s): kind = "invalidRequest"; reason = s
            case .unsupportedCapability(let s): kind = "unsupportedCapability"; reason = s
            case .providerError(let s): kind = "providerError"; reason = s
            case .streamingError(let s): kind = "streamingError"; reason = s
            case .networkError(let s): kind = "networkError"; reason = s
            case .unsupportedOperation(let s): kind = "unsupportedOperation"; reason = s
            case .unknownProvider(let s): kind = "unknownProvider"; reason = s
            case .httpError(let status, _): kind = "httpError(\(status))"; reason = nil
            case .interrupted: kind = "interrupted"; reason = nil
            case .cancelledLocally: kind = "cancelledLocally"; reason = nil

            }
            detail = "error=ModelError." + kind + " reason=" + (reason.map { safeReason($0) } ?? "none")
        } else if let agent = error as? AgentError {
            let kind: String
            switch agent {
            case .providerError: kind = "providerError"
            case .providerRefused: kind = "providerFailure wrapper=providerRefused"
            case .toolExecutionFailed: kind = "toolExecutionFailed"
            case .toolNotFound: kind = "toolNotFound"
            case .toolCancelled: kind = "toolCancelled"
            case .cancelled: kind = "cancelled"
            case .noProviderConfigured: kind = "noProviderConfigured"
            case .planningFailed: kind = "planningFailed"
            case .repairRetryExhausted(let n): kind = "repairRetryExhausted attempts=\(n)"
            case .maxTurnsReached(let n), .maxTurnsReachedWithSummary(let n, _): kind = "maxTurnsReached turns=\(n)"
            case .runInProgress: kind = "runInProgress"
            case .loopDetected(_, let n): kind = "loopDetected count=\(n)"
            case .unknown: kind = "unknown"
            }
            detail = "error=AgentError." + kind
        } else if let app = error as? AppError {
            detail = "error=AppError reason=" + safeReason(app.localizedDescription)
        } else if let stalled = error as? ModelStreamStalled {
            detail = "error=ModelStreamStalled seconds=\(stalled.seconds)"
        } else if let response = error as? LLMUnexpectedResponse {
            detail = "error=UnexpectedResponse httpStatus=\(response.status) contentType=\(response.contentType) bodyShape=\(response.bodyShape) truncated=\(response.truncated)" + (response.errorCode.map { " errorCode=" + $0 } ?? "")
        } else if let admission = error as? ChatGPTAdmissionFailure { detail = "error=HTTP status=\(admission.status) " + admission.localizedDescription }
        else if let decoding = error as? DecodingError {
            let kind: String, path: [any CodingKey]
            switch decoding {
            case .keyNotFound(let key, let c): kind = "keyNotFound"; path = c.codingPath + [key]
            case .typeMismatch(_, let c): kind = "typeMismatch"; path = c.codingPath
            case .valueNotFound(_, let c): kind = "valueNotFound"; path = c.codingPath
            case .dataCorrupted(let c): kind = "dataCorrupted"; path = c.codingPath
            @unknown default: kind = "unknown"; path = []
            }
            let keys: Set<String> = ["response", "output", "item", "id", "type", "status", "role", "content", "text", "annotations", "logprobs", "summary", "encrypted_content", "call_id", "name", "arguments", "namespace", "phase", "error", "incomplete_details"]
            detail = "error=DecodingError." + kind + " path=" + path.map { $0.intValue.map { "[\($0)]" } ?? (keys.contains($0.stringValue) ? $0.stringValue : "<redacted-key>") }.joined(separator: ".")
        } else if let network = error as? URLError { detail = "error=URLError code=\(network.errorCode)" + networkCauses(network as NSError) }
        else if let auth = error as? ChatGPTAuthError { detail = "error=ChatGPTAuthError " + auth.localizedDescription }
        else {
            let ns = error as NSError
            let domains: Set<String> = [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain]
            detail = "error=NSError domain=" + atom(ns.domain, allowed: domains) + " code=\(ns.code)" + networkCauses(ns)
        }
        // attempt/stage/shape are generated locally by the stream consumer.
        return "[LLM] attempt=\(attempt.uuidString) stage=\(stage) \(detail) \(shape)"
    }

    /// Keep only bounded, structured error codes. NSError descriptions/userInfo can contain credentials and URLs.
    private static func networkCauses(_ root: NSError) -> String {
        let domains: Set<String> = [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                                    "kCFErrorDomainCFNetwork", "kCFErrorDomainSSL"]
        var current: NSError? = root
        var seen = Set<ObjectIdentifier>()
        var fields: [String] = []
        for index in 0..<4 {
            guard let error = current, seen.insert(ObjectIdentifier(error)).inserted else { break }
            // SSL codes are meaningful only in their known security error domains.
            if error.domain == NSOSStatusErrorDomain || error.domain == "kCFErrorDomainSSL" {
                if error.code == Int(errSSLBadRecordMac) { fields.append("tls=badRecordMac") }
                else if error.code == Int(errSSLDecryptionFail) { fields.append("tls=decryptionFailed") }
            }
            if index > 0 {
                fields.append("cause\(index)=" + atom(error.domain, allowed: domains) + ":\(error.code)")
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return fields.isEmpty ? "" : " " + fields.joined(separator: " ")
    }
}
