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
    private let codec: OpenAIWireCodec, context: ContextCoordinator, transport: ResponsesTransport
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
    init(profile: ProviderProfile, model: String, account: String, runID: UUID, checkpointFile: URL? = nil, manager: ChatGPTAccountManager = .shared, transport: ResponsesTransport = ResponsesTransport()) throws {
        guard profile.providerKind == .chatGPTSubscription, profile.contextPolicy == .stateless,
              try profile.providerKind.baseURL(profile.settings.baseURL) == ChatGPTSubscriptionPolicy.resource, !model.isEmpty else { throw ChatGPTAuthError.disconnected }
        // Other profile parameters must be removed, never forwarded on this route.
        let fields = try profile.parameters(for: model).requestFields(providerKind: .chatGPTSubscription, model: profile.metadata(for: model))
        guard fields.keys.allSatisfy({ $0 == "reasoning_effort" }) else { throw AppError.invalid(String(localized: "ChatGPT subscriptions only support verified reasoning levels. Clear other model parameters.")) }
        effort = fields["reasoning_effort"] as? String
        configuration = .init(name: Self.name, baseURL: ChatGPTSubscriptionPolicy.resource, defaultModel: model)
        let scope = ProviderScope(provider: Self.name, endpoint: ChatGPTSubscriptionPolicy.resource.absoluteString, account: account, model: model, run: runID, branch: UUID())
        codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        context = try ContextCoordinator(scope: scope, storage: .none, checkpointFile: checkpointFile)
        profileID = profile.id; self.account = account; self.manager = manager; self.transport = transport
    }
    func capabilities(for model: String) async throws -> ProviderCapabilities { guard model == configuration.defaultModel else { throw ModelError.unsupportedCapability("Model scope changed") }; return .init(responseChain: false) }
    func cancel() { try? context.cancel(); transport.cancel() }
    /// Encoding is independent of credentials so tests can inspect the official subset.
    func prepareRequest(_ request: ModelRequest, token: String) throws -> URLRequest {
        guard request.model == configuration.defaultModel, request.storage == .none, request.execution == .foreground, request.context == .stateless else { throw ModelError.invalidRequest("Subscription requires local stateless foreground context") }
        let items = try request.input ?? ContextCoordinator.input(messages: request.messages.filter { $0.role != .system })
        var input = try items.map(codec.inputObject)
        let names = Set(request.tools.map(\.name))
        for i in input.indices where input[i]["type"] as? String == "function_call" {
            guard let name = input[i]["name"] as? String, names.contains(name) else { throw ModelError.protocolViolation("Subscription tool replay scope changed") }
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
        var outgoing = URLRequest(url: ChatGPTSubscriptionPolicy.resource.appendingPathComponent("responses"))
        outgoing.httpMethod = "POST"; outgoing.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type"); outgoing.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        outgoing.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard outgoing.httpBody!.count <= 24 * 1024 * 1024 else { throw ModelError.invalidRequest("Subscription request exceeds limit") }
        return outgoing
    }
    private func normalize(_ payload: String, tools: Set<String>, checkpoint: StreamCheckpoint) throws -> String {
        guard payload != "[DONE]" else { return payload }
        guard var o = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw ModelError.invalidResponse("Invalid subscription event") }
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
        if let value = o["item"] as? [String: Any] { o["item"] = try item(value, completedBoundary: o["type"] as? String == "response.output_item.done") }
        if var response = o["response"] as? [String: Any], let output = response["output"] as? [[String: Any]] {
            let completed = o["type"] as? String == "response.completed" && response["status"] as? String == "completed"
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
                    case .unknown, .providerOwned: throw ModelError.unsupportedCapability("Hosted/unknown output is not enabled")
                    }
                    let encoded = try codec.inputObject(.replay(value))
                    guard encoded["id"] as? String == checkpoint.itemIDs[index] else { throw ModelError.protocolViolation("Item done address conflict") }
                    restored.append(encoded)
                }
                response["output"] = restored
                LLMDiagnostics.emit("[LLM] stage=event.normalize notice=EmptyTerminalOutput action=useCompletedItems itemCount=\(count)")
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
                    let prepared = try context.prepare(PortableContextRequest.normalized(request)), actual = prepared.request
                    var reducer = ResponsesReducer(codec: codec, request: actual)
                    stage = "request.encode"
                    let outgoing = try prepareRequest(actual, token: grant.token)
                    stage = "stream.receive"
                    for try await payload in payloads(outgoing) {
                        shape = LLMDiagnostics.eventShape(payload)
                        try Task.checkCancellation(); try await manager.requireCurrent(grant, profileID: profileID)
                        stage = "event.normalize"
                        let checkpoint = reducer.checkpoint
                        shape += " addedItems=\(checkpoint.itemIDs.count) doneItems=\(checkpoint.completedItems.count)"
                        let normalized = try normalize(payload, tools: Set(actual.tools.map(\.name)), checkpoint: checkpoint)
                        stage = "event.reduce"
                        let events = try reducer.consume(payload: normalized)
                        stage = "checkpoint.write"
                        try context.recordStream(reducer.checkpoint)
                        for event in events {
                            if case .terminal(let response) = event {
                                if let code = response.error?.code, code == "subscription_sharing_usage_limit_exceeded" {
                                    try await manager.report(.usageLimited, account: account); throw ChatGPTAuthError.usageLimited
                                }
                                if response.error?.code == "subscription_sharing_usage_unavailable" {
                                    recordFailure(String(localized: "ChatGPT subscription usage could not be checked. Credentials were kept. No retry or billing change was made."))
                                    throw ModelError.providerError("Subscription usage unavailable")
                                }
                                stage = "terminal.validate"
                                try ResponsesReducer.requireExecutable(response)
                                try await manager.requireCurrent(grant, profileID: profileID); try Task.checkCancellation()
                                stage = "context.commit"
                                try context.commit(response, prepared: prepared)
                            }
                            if case .dropped = continuation.yield(event) { throw ModelError.protocolViolation("Subscription stream buffer exceeded") }
                        }
                        if reducer.response != nil { break }
                        stage = "stream.receive"
                    }
                    stage = "stream.finish"
                    _ = try reducer.finish(); continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError { continuation.finish(throwing: CancellationError()); return }
                    recordDiagnostic(LLMDiagnostics.failure(error, attempt: attempt, stage: stage, shape: shape))
                    if safeFailureMessage == nil { recordFailure(Self.failureSummary(error)) }
                    if let admission = error as? ChatGPTAdmissionFailure {
                        if admission.status == 401 { try? await manager.report(.expired, account: account) }
                        if admission.status == 429 { try? await manager.report(.usageLimited, account: account) }
                        continuation.finish(throwing: ModelError.providerError(admission.localizedDescription))
                    } else if case ModelError.httpError(let status, _) = error {
                        if status == 401 { try? await manager.report(.expired, account: account) }
                        if status == 429 { try? await manager.report(.usageLimited, account: account) }
                        continuation.finish(throwing: ModelError.providerError(status == 429 ? ChatGPTConnectionStatus.usageLimited.message : String(localized: "The ChatGPT subscription request was denied (HTTP \(status)). Check account permissions. No retry or billing change was made.")))
                    } else if let safe = error as? ChatGPTAuthError { continuation.finish(throwing: ModelError.providerError(safe.localizedDescription)) }
                    else if let safe = error as? ModelError { continuation.finish(throwing: safe) }
                    else { continuation.finish(throwing: ModelError.interrupted) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func failureSummary(_ error: Error) -> String {
        if let response = error as? LLMUnexpectedResponse { return response.localizedDescription }
        if let admission = error as? ChatGPTAdmissionFailure { return admission.localizedDescription }
        if let auth = error as? ChatGPTAuthError { return auth.localizedDescription }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet: return String(localized: "The ChatGPT request did not finish because the device is offline. It was not retried automatically.")
            case .timedOut: return String(localized: "The ChatGPT request timed out. Acceptance is unknown. It was not retried automatically.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return String(localized: "Could not connect to OpenAI inference. Check the network. The request was not retried automatically.")
            case .secureConnectionFailed, .serverCertificateUntrusted: return String(localized: "A secure connection to OpenAI inference failed. Check the network. The request was not retried automatically.")
            default: break
            }
        }
        if let model = error as? ModelError {
            switch model {
            case .httpError(let status, _): return String(localized: "The ChatGPT request was denied (HTTP \(status)). It was not retried automatically.")
            case .invalidRequest: return String(localized: "The ChatGPT request was not sent. The current model or context parameters are incompatible.")
            case .protocolViolation, .invalidResponse, .streamingError: return String(localized: "The ChatGPT response format or tool state is incompatible. This turn did not finish and was not retried automatically.")
            case .cancelledLocally: return String(localized: "The ChatGPT request was stopped locally. Remote cancellation was not confirmed.")
            default: break
            }
        }
        return String(localized: "The ChatGPT response stream was interrupted. Acceptance is unknown. It was not retried automatically.")
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        var terminal: ModelResponse?
        for try await event in stream(request) { if case .terminal(let response) = event { terminal = response } }
        guard let terminal else { throw ModelError.interrupted }; return terminal
    }
    private func payloads(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            let cancellation = ChatGPTStreamCancellation()
            let task = Task {
                do {
                    let (bytes, response) = try await transport.session.bytes(for: request)
                    cancellation.install(bytes.task)
                    defer { cancellation.cancel() }
                    guard let h = response as? HTTPURLResponse else { throw ChatGPTAuthError.network }
                    if !(200..<300).contains(h.statusCode) {
                        var body = Data()
                        for try await byte in bytes { try Task.checkCancellation(); guard body.count < 64 * 1024 else { throw ChatGPTAuthError.network }; body.append(byte) }
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
                    var decoder = SSEFrameDecoder()
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
                        LLMDiagnostics.emit("[LLM] stage=stream.headers notice=MissingContentType action=parseValidatedSSE httpStatus=\(h.statusCode)")
                        for byte in probe {
                            if let payload = try decoder.consume(byte), case .dropped = continuation.yield(payload) { throw ModelError.protocolViolation("Subscription SSE buffer exceeded") }
                        }
                    }
                    while let byte = try await iterator.next() {
                        try Task.checkCancellation()
                        if let payload = try decoder.consume(byte), case .dropped = continuation.yield(payload) { throw ModelError.protocolViolation("Subscription SSE buffer exceeded") }
                    }
                    try decoder.finish(); continuation.finish()
                } catch { continuation.finish(throwing: Task.isCancelled ? CancellationError() : error) }
            }
            continuation.onTermination = { _ in cancellation.cancel(); task.cancel() }
        }
    }
}

private final class ChatGPTStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?, cancelled = false
    func install(_ value: URLSessionTask) { lock.withLock { if cancelled { value.cancel() } else { task = value } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel(); task = nil } }
}

/// Keep structured diagnostic fields in memory without retaining raw error bodies.
/// UI messages never echo a server-supplied detail/message or unknown code.
struct ChatGPTAdmissionFailure: Error, LocalizedError {
    let status: Int, code: String?, param: String?, requestID: String?, bodyShape: String
    init(response: HTTPURLResponse, body: Data) {
        status = response.statusCode; requestID = response.value(forHTTPHeaderField: "x-request-id")
        let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let e = o?["error"] as? [String: Any]
        code = e?["code"] as? String; param = e?["param"] as? String
        bodyShape = e != nil ? "error" : o?["detail"] != nil ? "detail" : o != nil ? "object" : "non-json"
    }
    var errorDescription: String? {
        let summary: String
        if code == "subscription_sharing_usage_limit_exceeded" { summary = ChatGPTConnectionStatus.usageLimited.message }
        else if code == "subscription_sharing_usage_unavailable" { summary = String(localized: "Subscription usage could not be checked. Retry manually later.") }
        else {
            switch status {
            case 400, 422: summary = String(localized: "ChatGPT request parameters were rejected. Check the request format.")
            case 401: summary = String(localized: "The ChatGPT identity or subscription permission was not accepted. Reconnect.")
            case 403: summary = String(localized: "This account, workspace, service region, or route does not permit this subscription request. Check permissions.")
            case 404: summary = String(localized: "The ChatGPT model or inference route is unavailable. Refresh this account's model list.")
            case 429: summary = String(localized: "The ChatGPT request was limited. Subscription usage or request frequency may be restricted.")
            case 503: summary = String(localized: "The ChatGPT subscription service or usage check is temporarily unavailable. Credentials were kept.")
            default: summary = String(localized: "The ChatGPT subscription request failed")
            }
        }
        let codes: Set<String> = ["invalid_request_error", "unsupported_parameter", "unknown_parameter", "invalid_value", "model_not_found", "permission_denied", "insufficient_permissions", "invalid_api_key", "insufficient_quota", "rate_limit_exceeded", "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"]
        let safeCode = code.flatMap { codes.contains($0) ? $0 : nil }
        let fields = ["model", "input", "tools", "instructions", "include", "reasoning", "store", "stream"]
        let safeParam = fields.first { param == $0 || param?.hasPrefix($0 + ".") == true || param?.hasPrefix($0 + "[") == true }
        var details = ["HTTP \(status)"]
        if let safeCode { details.append(safeCode) }
        if let safeParam { details.append(String(localized: "Field \(safeParam)")) }
        return String(localized: "\(summary) (\(details.joined(separator: "; "))); no automatic retry or billing change was made")
    }
}
