import Foundation
import CryptoKit
import ProviderCore

/// Frame decoder accepts split UTF-8 and CRLF/multiline SSE. EOF is never a terminal.
public struct SSEFrameDecoder: Sendable {
    private var line = Data(), dataLines: [String] = [], eventBytes = 0, total = 0
    public init() {}
    public mutating func consume(_ byte: UInt8) throws -> String? {
        total += 1
        guard total <= 4 * 1024 * 1024, line.count < 256 * 1024 else { throw ModelError.protocolViolation("模型流超过大小限制") }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else { throw ModelError.protocolViolation("Invalid SSE UTF-8") }; line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventBytes = 0 }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
        guard text.hasPrefix("data:") else { return nil }
        var payload = String(text.dropFirst(5)); if payload.first == " " { payload.removeFirst() }
        eventBytes += payload.utf8.count
        guard eventBytes <= 256 * 1024 else { throw ModelError.protocolViolation("SSE event size limit") }
        dataLines.append(payload); return nil
    }
    public func finish() throws { guard line.isEmpty, dataLines.isEmpty else { throw ModelError.protocolViolation("Truncated SSE frame") } }
}
/// Single writer, per-response reducer. Final snapshots are authoritative; only
/// previews append deltas. Sequence digests deduplicate original events; only credential-redacted extension
/// payloads are retained as non-executable response attachments.
public struct ResponsesReducer: Sendable {
    private let codec: OpenAIWireCodec
    private let request: ModelRequest
    private var sequences: [Int: Data] = [:]
    private var lastSequence: Int?
    private var responseID: String?
    private var itemIDs: [Int: String] = [:]
    private var doneItems: [Int: ModelOutputItem] = [:]
    private var contentPreviews: [String: String] = [:]
    private var argumentPreviews: [String: String] = [:]
    private var retainedEvents: [ProviderStreamEvent] = []
    private var retainedBytes = 0
    public private(set) var response: ModelResponse?
    /// Applies only to the latest consume call; attachments cannot execute tools.
    public private(set) var retainedExtensionEvent = false
    /// Known metadata is retained silently; only novel event types need a warning.
    public var retainedUnknownEvent: Bool {
        retainedExtensionEvent && retainedEvents.last?.type != "response.metadata"
    }
    public var checkpoint: StreamCheckpoint {
        var value = StreamCheckpoint(responseID: responseID, sequence: lastSequence, terminal: response?.status)
        value.scope = codec.scope
        value.itemIDs = itemIDs; value.completedItems = doneItems; value.contentPreviews = contentPreviews; value.argumentPreviews = argumentPreviews
        value.events = retainedEvents.isEmpty ? nil : retainedEvents
        return value
    }
    public init(codec: OpenAIWireCodec, request: ModelRequest) { self.codec = codec; self.request = request }
    public mutating func consume(payload: String) throws -> [ModelEvent] {
        retainedExtensionEvent = false
        let previous = lastSequence
        var output = try reduce(payload: payload)
        if lastSequence != previous, response == nil, !retainedExtensionEvent,
           let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
            output.append(.progress(.init(responseID: responseID, sequence: lastSequence,
                itemID: object["item_id"] as? String ?? (object["item"] as? [String: Any])?["id"] as? String,
                outputIndex: object["output_index"] as? Int,
                contentIndex: object["content_index"] as? Int ?? object["summary_index"] as? Int,
                kind: object["type"] as? String ?? "")))
        }
        return output
    }
    private mutating func reduce(payload: String) throws -> [ModelEvent] {
        guard payload.utf8.count <= 256 * 1024 else { throw ModelError.protocolViolation("SSE event size limit") }
        if payload == "[DONE]" { return [] }
        guard let o = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], let type = o["type"] as? String else { throw ModelError.protocolViolation("SSE event missing type") }
        // Heartbeats need no sequence. Other extensions retain sequence/scope
        // checks and never supply output or authorize completion/execution.
        if ["ping", "keepalive"].contains(type) || type.hasPrefix("vendor.metrics.") { return [] }
        guard let seq = o["sequence_number"] as? Int, seq >= 0 else { throw ModelError.protocolViolation("Event missing sequence") }
        let canonical = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        let digest = Data(SHA256.hash(data: canonical))
        if let seen = sequences[seq] {
            guard seen == digest else { throw ModelError.protocolViolation("Conflicting sequence replay") }; return []
        }
        guard response == nil, lastSequence.map({ seq > $0 }) ?? true, sequences.count < 65536 else { throw ModelError.protocolViolation("Late/out of order response event") }
        sequences[seq] = digest; lastSequence = seq
        if let r = o["response"] as? [String: Any], let id = r["id"] as? String {
            if let previous = responseID, previous != id { throw ModelError.protocolViolation("Response scope changed") }
            // An extension may reference the response, but cannot establish
            // the identity needed to validate later output/completion.
            if ["response.created", "response.in_progress", "response.completed", "response.incomplete", "response.failed", "response.cancelled"].contains(type) {
                retainedEvents = try retainedEvents.map { try $0.bound(to: id) }
                responseID = id
            }
        }
        if let id = o["response_id"] as? String, let previous = responseID, id != previous { throw ModelError.protocolViolation("Response scope changed") }
        switch type {
        case "response.created", "response.in_progress":
            guard responseID != nil else { throw ModelError.protocolViolation("Lifecycle missing response ID") }; return []
        case "response.output_item.added":
            guard let index = o["output_index"] as? Int, let item = o["item"] as? [String: Any], let id = item["id"] as? String, itemIDs[index] == nil, !itemIDs.values.contains(id) else { throw ModelError.protocolViolation("Invalid output address") }
            guard ["message", "reasoning", "function_call"].contains(item["type"] as? String ?? "") else { throw ModelError.unsupportedCapability("Unsupported execution/output item") }
            itemIDs[index] = id; return []
        case "response.output_item.done":
            let index = try address(o)
            guard let item = o["item"] as? [String: Any], item["id"] as? String == itemIDs[index], doneItems[index] == nil else { throw ModelError.protocolViolation("Item done address conflict") }
            doneItems[index] = try codec.outputItem(item); return []
        case "response.output_text.delta", "response.refusal.delta", "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            let index = try address(o)
            let content = o["content_index"] as? Int ?? o["summary_index"] as? Int
            guard let content, content >= 0, let delta = o["delta"] as? String, doneItems[index] == nil else { throw ModelError.protocolViolation("Delta address missing") }
            let key = "\(index):\(content):\(type)"; contentPreviews[key, default: ""] += delta
            return [type == "response.reasoning_summary_text.delta" || type == "response.reasoning_text.delta" ? .reasoning(delta) : .text(delta)]
        case "response.function_call_arguments.delta":
            let index = try address(o)
            guard let delta = o["delta"] as? String, doneItems[index] == nil else { throw ModelError.protocolViolation("Invalid arguments delta") }
            argumentPreviews[itemIDs[index]!, default: ""] += delta; return []
        case "response.function_call_arguments.done":
            let index = try address(o)
            guard let args = o["arguments"] as? String else { throw ModelError.protocolViolation("Arguments done missing full value") }
            argumentPreviews[itemIDs[index]!] = args; return []
        case "response.output_text.done", "response.refusal.done", "response.reasoning_summary_text.done", "response.reasoning_text.done", "response.content_part.added", "response.content_part.done", "response.reasoning_summary_part.added", "response.reasoning_summary_part.done", "response.output_text.annotation.added":
            _ = try address(o); return []
        case "response.completed", "response.incomplete", "response.failed", "response.cancelled":
            guard let r = o["response"] as? [String: Any] else { throw ModelError.protocolViolation("Terminal missing snapshot") }
            let parsed = try codec.nativeResponse(r, request: request)
            guard type == "response." + parsed.status.rawValue, parsed.id == responseID else { throw ModelError.protocolViolation("Terminal status/scope mismatch") }
            if parsed.status == .completed {
                guard parsed.error == nil, parsed.incomplete == nil || parsed.incomplete == .null,
                      parsed.output.count == itemIDs.count, doneItems.count == itemIDs.count else { throw ModelError.protocolViolation("Completed snapshot has missing/conflicting items") }
                for (index, item) in doneItems {
                    guard parsed.output.indices.contains(index), parsed.output[index] == item else { throw ModelError.protocolViolation("Terminal changed completed item") }
                }
                try Self.requireExecutable(parsed)
            }
            let attached = try retainedEvents.map { try $0.bound(to: parsed.id) }
            let result = ModelResponse(id: parsed.id, model: parsed.model, status: parsed.status, scope: parsed.scope, output: parsed.output, usage: parsed.usage, error: parsed.error, incomplete: parsed.incomplete, extra: parsed.extra, streamEvents: attached, request: parsed.request, providerName: parsed.providerName, permitsTextToolInference: parsed.permitsTextToolInference)
            retainedEvents = attached
            response = result; return [.terminal(result)]
        case "error": throw ModelError.providerError("模型流返回错误；没有自动重试")
        default:
            guard retainedEvents.count < 128, retainedBytes + canonical.count <= 512 * 1024 else { throw ModelError.protocolViolation("Stream extension limit") }
            if let direct = o["response_id"] as? String, let nested = (o["response"] as? [String: Any])?["id"] as? String, direct != nested { throw ModelError.protocolViolation("Response scope changed") }
            let hint = o["response_id"] as? String ?? (o["response"] as? [String: Any])?["id"] as? String
            if let responseID, let hint, hint != responseID { throw ModelError.protocolViolation("Response scope changed") }
            let retainedJSON = try JSONSerialization.data(withJSONObject: EventCredentialRedactor.redact(o), options: [.sortedKeys, .withoutEscapingSlashes])
            let event = ProviderStreamEvent(type: type, sequence: seq, responseID: responseID ?? hint, payloadJSON: retainedJSON)
            retainedEvents.append(event); retainedBytes += canonical.count
            retainedExtensionEvent = true
            return []
        }
    }
    private func address(_ o: [String: Any]) throws -> Int {
        guard let i = o["output_index"] as? Int, let id = o["item_id"] as? String ?? (o["item"] as? [String: Any])?["id"] as? String,
              itemIDs[i] == id else { throw ModelError.protocolViolation("Event item address mismatch") }; return i
    }
    public func finish() throws -> ModelResponse { guard let response else { throw ModelError.interrupted }; return response }
    public static func requireExecutable(_ response: ModelResponse) throws {
        guard response.status == .completed else { throw ModelError.protocolViolation("模型生成未完成（\(response.status.rawValue)）；没有执行工具或自动重试") }
        guard response.error == nil, response.incomplete == nil || response.incomplete == .null else { throw ModelError.protocolViolation("Completed response contains failure details") }
        guard response.output.allSatisfy({ if case .unknown = $0 { return false }; if case .providerOwned = $0 { return false }; return true }) else { throw ModelError.unsupportedCapability("Hosted/unknown output is not enabled") }
        for item in response.output {
            if case .message(let m) = item, m.status != .completed { throw ModelError.protocolViolation("Message is not completed") }
            if case .functionCall(let c) = item, c.status != .completed { throw ModelError.protocolViolation("Function item is not completed") }
        }
        try ToolBatchValidator.validate(response.toolCalls)
    }
}
