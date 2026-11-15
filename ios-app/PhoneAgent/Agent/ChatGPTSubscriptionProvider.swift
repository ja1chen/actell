import Foundation
import ProviderCore
import OpenAIAdapter

protocol CancellableModelProvider: ModelProvider { func cancel() }
extension PrivateVisionProvider: CancellableModelProvider {}

/// Official SIWC HTTP subset, layered over our codec/reducer, never a user API key.
final class ChatGPTSubscriptionProvider: CancellableModelProvider, @unchecked Sendable {
    static let name = "chatgpt-subscription"
    let configuration: ProviderConfiguration
    private let profileID: UUID, account: String
    private let manager: ChatGPTAccountManager
    var replayScope: ProviderReplayScope { codec.scope }
    private let codec: OpenAIWireCodec, transport: ResponsesTransport
    private let effort: String?
    private let failureLock = NSLock()
    private var failureMessage: String?
    private var diagnostic: String?
    var lastDiagnostic: String? { failureLock.withLock { diagnostic } }
    private func recordDiagnostic(_ value: String) {
        failureLock.withLock { diagnostic = value }
        LLMDiagnostics.emit(value)
    }
    var safeFailureMessage: String? { failureLock.withLock { failureMessage } }
    private func recordFailure(_ message: String?) { failureLock.withLock { failureMessage = message } }
    init(profile: ProviderProfile, model: String, account: String, sessionID: UUID, manager: ChatGPTAccountManager = .shared, transport: ResponsesTransport = ResponsesTransport()) throws {
        guard profile.providerKind == .chatGPTSubscription, profile.contextPolicy == .stateless,
              try profile.providerKind.baseURL(profile.settings.baseURL) == ChatGPTSubscriptionPolicy.resource, !model.isEmpty else { throw ChatGPTAuthError.disconnected }
        // Other profile parameters must be removed, never forwarded on this route.
        let fields = try profile.parameters(for: model).requestFields(providerKind: .chatGPTSubscription, model: profile.metadata(for: model))
        guard fields.keys.allSatisfy({ $0 == "reasoning_effort" }) else { throw AppError.invalid(String(localized: "ChatGPT subscriptions only support verified reasoning levels. Clear other model parameters.")) }
        effort = fields["reasoning_effort"] as? String
        configuration = .init(name: Self.name, baseURL: ChatGPTSubscriptionPolicy.resource, defaultModel: model)
        let scope = ProviderScope(provider: Self.name, endpoint: ChatGPTSubscriptionPolicy.resource.absoluteString, account: account, model: model, session: sessionID)
        codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        profileID = profile.id; self.account = account; self.manager = manager; self.transport = transport
    }
    func capabilities(for model: String) async throws -> ProviderCapabilities { guard model == configuration.defaultModel else { throw ModelError.unsupportedCapability("Model scope changed") }; return .init(responseChain: false) }
    func cancel() { transport.cancel() }
    /// Encoding is independent of credentials so tests can inspect the official subset.
    func prepareRequest(_ request: ModelRequest, token: String) throws -> URLRequest {
        guard request.model == configuration.defaultModel, request.storage == .none, request.execution == .foreground, request.context == .stateless else { throw ModelError.invalidRequest("Subscription requires local stateless foreground context") }
        let items = try request.input ?? ModelInputProjection.input(messages: request.messages.filter { $0.role != .system })
        var input = try items.map(codec.inputObject)
        for i in input.indices where input[i]["type"] as? String == "function_call" {
            // Historical calls remain replayable after a tool/skill is disabled.
            // Only newly generated calls must match the current advertised definitions.
            guard let name = input[i]["name"] as? String, !name.isEmpty,
                  input[i]["namespace"] == nil || input[i]["namespace"] as? String == "actell" else { throw ModelError.protocolViolation("Subscription tool replay scope changed") }
            input[i]["namespace"] = "actell"
        }
        var body: [String: Any] = ["model": request.model, "input": input, "stream": true, "store": false, "include": ["reasoning.encrypted_content"]]
        let instructions = request.instructions ?? request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        if !instructions.isEmpty { body["instructions"] = instructions }
        if !request.tools.isEmpty {
            // Namespace schema is serialized in our adapter; SDK source is untouched.
            body["tools"] = [["type": "namespace", "name": "actell", "description": "Actell local device tools", "tools": request.tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters, "strict": false] as [String: Any] }]]
        }
        if let effort { body["reasoning"] = ["effort": effort] }
        if let key = request.cachePolicy?.key { body["prompt_cache_key"] = key }
        var outgoing = URLRequest(url: ChatGPTSubscriptionPolicy.resource.appendingPathComponent("responses"))
        outgoing.httpMethod = "POST"; outgoing.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type"); outgoing.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        outgoing.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        guard outgoing.httpBody!.count <= 24 * 1024 * 1024 else { throw ModelError.invalidRequest("Subscription request exceeds limit") }
        return outgoing
    }
    private func normalize(_ payload: String, tools: Set<String>, checkpoint: StreamCheckpoint, attempt: UUID) throws -> String {
        guard payload != "[DONE]" else { return payload }
        guard var o = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw ModelError.invalidResponse("Invalid subscription event") }
        let type = o["type"] as? String ?? ""
        // Unknown extension fields are opaque. Only normalize output carried
        // by known item/lifecycle events; the reducer still checks scope/order.
        guard ["response.output_item.added", "response.output_item.done", "response.created", "response.in_progress", "response.completed", "response.failed", "response.incomplete", "response.cancelled"].contains(type) else { return payload }
        func item(_ value: [String: Any], completedBoundary: Bool) throws -> [String: Any] {
            guard value["type"] as? String == "function_call" else { return value }
            guard let name = value["name"] as? String, tools.contains(name), value["namespace"] as? String == "actell" else { throw ModelError.protocolViolation("Subscription tool namespace/name mismatch") }
            var normalized = value
            // The official function-call status is optional. A done item plus
            // a completed terminal snapshot are still required by the reducer.
            // Never replace an explicit in_progress/incomplete/unknown status.
            if completedBoundary, value["status"] == nil || value["status"] is NSNull {
                normalized["status"] = "completed"
            }
            return normalized // Preserve namespace for replay and equality.
        }
        if let value = o["item"] as? [String: Any] { o["item"] = try item(value, completedBoundary: type == "response.output_item.done") }
        if var response = o["response"] as? [String: Any], let output = response["output"] as? [[String: Any]] {
            let completed = type == "response.completed" && response["status"] as? String == "completed"
            response["output"] = try output.map { try item($0, completedBoundary: completed) }
            // The subscription stream may omit the final output snapshot after
            // sending all final item.done objects. Use only the reducer's already
            // validated items, never text/argument previews or a previous turn.
            let count = checkpoint.itemIDs.count
            if completed, output.isEmpty, count > 0,
               checkpoint.scope == codec.scope, checkpoint.terminal == nil,
               response["id"] as? String == checkpoint.responseID,
               response["error"] == nil || response["error"] is NSNull,
               response["incomplete_details"] == nil || response["incomplete_details"] is NSNull,
               checkpoint.completedItems.count == count,
               Set(checkpoint.itemIDs.keys) == Set(0..<count),
               Set(checkpoint.completedItems.keys) == Set(0..<count) {
                var restored: [[String: Any]] = []
                for index in 0..<count {
                    let value = checkpoint.completedItems[index]!
                    switch value {
                    case .message(let message):
                        guard message.status == .completed else { throw ModelError.protocolViolation("Message is not completed") }
                    case .functionCall(let call):
                        guard call.status == .completed else { throw ModelError.protocolViolation("Function item is not completed") }
                    case .reasoning: break
                    case .compaction: throw ModelError.unsupportedCapability("Subscription native compaction is not enabled")
                    case .unknown, .providerOwned: throw ModelError.unsupportedCapability("Hosted/unknown output is not enabled")
                    }
                    let encoded = try codec.inputObject(.replay(value))
                    guard encoded["id"] as? String == checkpoint.itemIDs[index] else { throw ModelError.protocolViolation("Item done address conflict") }
                    restored.append(encoded)
                }
                response["output"] = restored
                LLMDiagnostics.verbose("[LLM] attempt=\(attempt.uuidString) stage=event.normalize notice=EmptyTerminalOutput action=useCompletedItems itemCount=\(count)")
            }
            o["response"] = response
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        recordFailure(nil)
        failureLock.withLock { diagnostic = nil }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task {
                let attempt = UUID()
                var stage = "authorization", shape = "event=none"
                do {
                    let grant = try await manager.access(profileID: profileID, expectedAccount: account)
                    try Task.checkCancellation()
                    stage = "context.prepare"
                    let actual = request
                    var reducer = ResponsesReducer(codec: codec, request: actual)
                    stage = "request.encode"
                    let outgoing = try prepareRequest(actual, token: grant.token)
                    LLMDiagnostics.verbose("[LLM] attempt=\(attempt.uuidString) stage=request.send bodyBytes=\(outgoing.httpBody?.count ?? 0) toolCount=\(actual.tools.count)")
                    stage = "stream.receive"
                    for try await payload in payloads(outgoing, attempt: attempt) {
                        shape = LLMDiagnostics.eventShape(payload)
                        LLMDiagnostics.traceEvent(payload, attempt: attempt)
                        try Task.checkCancellation(); try await manager.requireCurrent(grant, profileID: profileID)
                        stage = "event.normalize"
                        let checkpoint = reducer.checkpoint
                        shape += " addedItems=\(checkpoint.itemIDs.count) doneItems=\(checkpoint.completedItems.count)"
                        let normalized = try normalize(payload, tools: Set(actual.tools.map(\.name)), checkpoint: checkpoint, attempt: attempt)
                        stage = "event.reduce"
                        let events = try reducer.consume(payload: normalized)
                        if reducer.retainedUnknownEvent {
                            LLMDiagnostics.warning(LLMDiagnostics.retainedEvent(attempt: attempt, shape: shape))
                        }
                        for event in events {
                            if case .terminal(let response) = event {
                                stage = "terminal.validate"
                                if response.status == .failed, let rawCode = response.error?.code,
                                   let code = ChatGPTServiceCode(rawValue: rawCode) { throw code }
                                try ResponsesReducer.requireExecutable(response)
                                try await manager.requireCurrent(grant, profileID: profileID); try Task.checkCancellation()
                                LLMDiagnostics.verbose("[LLM] attempt=\(attempt.uuidString) stage=terminal.validated outputCount=\(response.output.count) toolCount=\(response.toolCalls.count)")
                            }
                            if case .dropped = continuation.yield(event) { throw ModelError.protocolViolation("Subscription stream buffer exceeded") }
                        }
                        if reducer.response != nil { break }
                        stage = "stream.receive"
                    }
                    stage = "stream.finish"
                    _ = try reducer.finish(); continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError()); return
                    }
                    recordDiagnostic(LLMDiagnostics.failure(error, attempt: attempt, stage: stage, shape: shape))
                    if safeFailureMessage == nil { recordFailure(Self.failureSummary(error)) }
                    if let admission = error as? ChatGPTAdmissionFailure {
                        if admission.status == 400, admission.code == "context_length_exceeded" { continuation.finish(throwing: ModelError.rejectedBeforeAcceptance(reason: .contextCapacity)); return }
                        if admission.serviceCode == .usageLimited { try? await manager.report(.usageLimited, account: account) }
                        continuation.finish(throwing: ModelError.providerError(admission.localizedDescription))
                    } else if let code = error as? ChatGPTServiceCode {
                        if code == .usageLimited { try? await manager.report(.usageLimited, account: account) }
                        continuation.finish(throwing: ModelError.providerError(code.localizedDescription))
                    } else if let safe = error as? ChatGPTAuthError { continuation.finish(throwing: ModelError.providerError(safe.localizedDescription)) }
                    else if let safe = error as? ModelError { continuation.finish(throwing: safe) }
                    else { continuation.finish(throwing: ModelError.interrupted) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func failureSummary(_ error: Error) -> String {
        if error is LLMUnexpectedResponse { return String(localized: "ChatGPT returned an unexpected response. Check your connection and try again.") }
        if let admission = error as? ChatGPTAdmissionFailure { return admission.localizedDescription }
        if let service = error as? ChatGPTServiceCode { return service.localizedDescription }
        if let auth = error as? ChatGPTAuthError { return auth.localizedDescription }
        if let network = error as? URLError {
            return ChatGPTNetworkMessage.summary(network.code) ?? String(localized: "The reply was interrupted.")
        }
        if let model = error as? ModelError {
            switch model {
            case .httpError(let status, _): return ChatGPTAdmissionFailure.httpMessage(status)
            case .invalidRequest: return String(localized: "The model or context settings are incompatible.")
            case .protocolViolation, .invalidResponse, .streamingError, .unsupportedCapability, .interrupted: return String(localized: "The reply could not be verified.")
            case .cancelledLocally: return String(localized: "Stopped locally; the service may still be processing.")
            default: break
            }
        }
        return String(localized: "The reply was interrupted.")
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        var terminal: ModelResponse?
        for try await event in stream(request) { if case .terminal(let response) = event { terminal = response } }
        guard let terminal else { throw ModelError.interrupted }; return terminal
    }
    func payloads(_ request: URLRequest, attempt: UUID) -> AsyncThrowingStream<String, Error> {
        let cursor = ChatGPTPayloadCursor(session: transport.session, request: request, attempt: attempt)
        return AsyncThrowingStream(unfolding: { try await cursor.next() })
    }
}

/// Pull frames as validation consumes them, without a separate producer queue.
/// The iterator is serial; only cancellation crosses threads.
final class ChatGPTPayloadCursor: @unchecked Sendable {
    private let session: URLSession, request: URLRequest, attempt: UUID
    private let cancellation = ChatGPTStreamCancellation()
    private var iterator: URLSession.AsyncBytes.Iterator?
    private var decoder = SSEFrameDecoder()
    private var pendingProbeFrame: String?
    private var finished = false
    init(session: URLSession, request: URLRequest, attempt: UUID) {
        self.session = session; self.request = request; self.attempt = attempt
    }
    deinit { cancellation.cancel() }
    func next() async throws -> String? {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                guard !finished else { return nil }
                if iterator == nil {
                    let (bytes, response) = try await session.bytes(for: request)
                    cancellation.install(bytes.task)
                    try Task.checkCancellation()
                    guard let h = response as? HTTPURLResponse else { throw ChatGPTAuthError.network }
                    LLMDiagnostics.verbose("[LLM] attempt=\(attempt.uuidString) stage=stream.headers httpStatus=\(h.statusCode)")
                    if !(200..<300).contains(h.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if body.count >= 64 * 1024 { break }
                            body.append(byte)
                        }
                        throw ChatGPTAdmissionFailure(response: h, body: body)
                    }
                    let mediaType = LLMUnexpectedResponse.mediaType(h)
                    if mediaType != "text/event-stream", mediaType != "missing" {
                        var body = Data(), truncated = false
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if body.count >= 64 * 1024 { truncated = true; break }
                            body.append(byte)
                        }
                        throw LLMUnexpectedResponse(response: h, body: body, truncated: truncated)
                    }
                    var iterator = bytes.makeAsyncIterator()
                    if mediaType == "missing" {
                        // Some successful native responses omit Content-Type.
                        // Probe at most 1 KiB, then feed the exact bytes back into
                        // the same SSE decoder. No second request or body fallback.
                        var probe = Data()
                        while probe.count < 1024, let byte = try await iterator.next() {
                            try Task.checkCancellation()
                            probe.append(byte)
                            if byte == 10, !String(decoding: probe, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                        }
                        let first = String(decoding: probe, as: UTF8.self).trimmingCharacters(in: .newlines)
                        guard ["data:", "event:", ":", "id:", "retry:"].contains(where: { first.hasPrefix($0) }) else {
                            throw LLMUnexpectedResponse(response: h, body: probe, truncated: probe.count == 1024)
                        }
                        LLMDiagnostics.verbose("[LLM] attempt=\(attempt.uuidString) stage=stream.headers notice=MissingContentType action=parseValidatedSSE httpStatus=\(h.statusCode)")
                        for byte in probe {
                            if let payload = try decoder.consume(byte) { pendingProbeFrame = payload }
                        }
                    }
                    self.iterator = iterator
                }
                if let frame = pendingProbeFrame { pendingProbeFrame = nil; return frame }
                while let byte = try await iterator!.next() {
                    try Task.checkCancellation()
                    if let payload = try decoder.consume(byte) { return payload }
                }
                try decoder.finish()
                finished = true; cancellation.cancel()
                return nil
            } catch {
                finished = true; cancellation.cancel()
                throw Task.isCancelled ? CancellationError() : error
            }
        } onCancel: { cancellation.cancel() }
    }
}

private final class ChatGPTStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?, cancelled = false
    func install(_ value: URLSessionTask) { lock.withLock { if cancelled { value.cancel() } else { task = value } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel(); task = nil } }
}

/// The documented SIWC codes are shared by HTTP admission and failed Responses events.
enum ChatGPTServiceCode: String, Error, LocalizedError {
    case usageLimited = "subscription_sharing_usage_limit_exceeded"
    case usageUnavailable = "subscription_sharing_usage_unavailable"
    case ineligible = "subscription_sharing_user_not_eligible"
    case unsupported = "subscription_sharing_unsupported_capability"
    case unsupportedRoute = "subscription_sharing_route_not_supported"
    case invalidUser = "subscription_sharing_invalid_user"
    case unauthorizedScope = "chatpass_v2_scope_not_authorized"
    case invalidAuthorizationContext = "chatpass_v2_invalid_authorization_context"
    case userUnavailable = "subscription_sharing_user_unavailable"

    var errorDescription: String? {
        switch self {
        case .usageLimited: return ChatGPTConnectionStatus.usageLimited.message
        case .usageUnavailable: return String(localized: "Subscription usage could not be checked. Try again later.")
        case .ineligible: return String(localized: "This ChatGPT account or workspace cannot use its plan with this app.")
        case .unsupported: return String(localized: "ChatGPT does not support this request. Check the selected model and settings.")
        case .unsupportedRoute: return String(localized: "ChatGPT does not support this operation in the app.")
        case .invalidUser: return ChatGPTAdmissionFailure.httpMessage(401)
        case .unauthorizedScope, .invalidAuthorizationContext:
            return String(localized: "This app is not authorized to use the selected ChatGPT account for this request.")
        case .userUnavailable:
            return String(localized: "ChatGPT could not check your account or workspace. Try again later.")
        }
    }
}

/// Keep structured diagnostic fields in memory without retaining raw error bodies.
/// UI messages never echo a server-supplied detail/message or unknown code.
struct ChatGPTAdmissionFailure: Error, LocalizedError {
    let status: Int, code: String?, param: String?, requestID: String?, bodyShape: String
    init(response: HTTPURLResponse, body: Data) {
        self.init(status: response.statusCode, body: body, requestID: response.value(forHTTPHeaderField: "x-request-id"))
    }
    init(status: Int, body: Data, requestID: String? = nil) {
        self.status = status; self.requestID = requestID
        let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let e = o?["error"] as? [String: Any]
        code = e?["code"] as? String; param = e?["param"] as? String
        bodyShape = e != nil ? "error" : o?["detail"] != nil ? "detail" : o != nil ? "object" : "non-json"
    }
    var serviceCode: ChatGPTServiceCode? { code.flatMap(ChatGPTServiceCode.init(rawValue:)) }
    var diagnosticSummary: String {
        let codes: Set<String> = ["invalid_request_error", "unsupported_parameter", "unknown_parameter", "invalid_value", "model_not_found", "permission_denied", "insufficient_permissions", "invalid_api_key", "insufficient_quota", "rate_limit_exceeded", "context_length_exceeded"]
        let fields = ["model", "input", "tools", "instructions", "include", "reasoning", "store", "stream"]
        let safeParam = fields.first { param == $0 || param?.hasPrefix($0 + ".") == true || param?.hasPrefix($0 + "[") == true }
        let safeCode = serviceCode?.rawValue ?? code.flatMap { codes.contains($0) ? $0 : nil }
        return "httpStatus=\(status) bodyShape=\(bodyShape)" + (safeCode.map { " errorCode=" + $0 } ?? "") + (safeParam.map { " field=" + $0 } ?? "")
    }
    var errorDescription: String? {
        serviceCode?.localizedDescription ?? Self.httpMessage(status)
    }
    static func httpMessage(_ status: Int) -> String {
        switch status {
        case 400, 422: return String(localized: "The request settings were rejected.")
        case 401: return String(localized: "ChatGPT did not accept this request’s authorization. Check the selected account in Settings.")
        case 403: return String(localized: "This account cannot use the selected service.")
        case 404: return String(localized: "The model is unavailable. Refresh the model list.")
        case 408, 504: return String(localized: "The request timed out.")
        case 429: return String(localized: "ChatGPT is receiving too many requests. Try again later.")
        case 500...599: return String(localized: "ChatGPT is temporarily unavailable. Try again later.")
        default: return String(localized: "The model request failed.")
        }
    }
}
