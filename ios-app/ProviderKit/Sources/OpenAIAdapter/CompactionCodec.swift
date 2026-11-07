import Foundation
import ProviderCore

extension OpenAIWireCodec {
    /// Explicit native capability: callers never infer compact support from Responses alone.
    public func prepareCompaction(_ request: ModelCompactionRequest) throws -> URLRequest {
        guard wire == .responses, capabilities.compaction else { throw ModelError.unsupportedCapability("Native compaction is unavailable") }
        guard request.model == scope.model, configuration.baseURL.scheme == "https", configuration.baseURL.user == nil, configuration.baseURL.password == nil else { throw ModelError.invalidRequest("Compaction model/endpoint mismatch") }
        var body: [String: Any] = ["model": request.model, "input": try request.input.map(inputObject)]
        if let instructions = request.instructions { body["instructions"] = instructions }
        var result = URLRequest(url: configuration.baseURL.appendingPathComponent("responses/compact"))
        result.httpMethod = "POST"; result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = configuration.apiKey { result.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        result.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        guard result.httpBody!.count <= 24 * 1024 * 1024 else { throw ModelError.invalidRequest("Compaction request exceeds byte limit") }
        return result
    }
    static func validateCompactedInput(_ value: [String: Any]) throws {
        if value["type"] as? String == "function_call_output" {
            guard let call = value["call_id"] as? String, !call.isEmpty, value["output"] is String else { throw ModelError.protocolViolation("Invalid compacted tool result") }; return
        }
        guard value["type"] as? String == "message", value["role"] as? String == "user", let content = value["content"] as? [[String: Any]] else { throw ModelError.unsupportedCapability("Unsupported compacted input item") }
        for part in content {
            switch part["type"] as? String {
            case "input_text": guard part["text"] is String else { throw ModelError.protocolViolation("Invalid compacted text") }
            case "input_image": guard part["image_url"] is String || part["file_id"] is String else { throw ModelError.protocolViolation("Invalid compacted image") }
            default: throw ModelError.unsupportedCapability("Unsupported compacted input content")
            }
        }
    }
    public func parseCompaction(_ data: Data) throws -> ModelCompactionResponse {
        guard capabilities.compaction, data.count <= 4 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["object"] as? String == "response.compaction",
              let id = object["id"] as? String, !id.isEmpty,
              let output = object["output"] as? [[String: Any]], !output.isEmpty else { throw ModelError.protocolViolation("Invalid compaction response") }
        let items = try output.map { value -> ModelInputItem in
            if value["type"] as? String == "function_call_output" || (value["type"] as? String == "message" && value["role"] as? String != "assistant") {
                try Self.validateCompactedInput(value)
                return .compacted(.init(type: value["type"] as! String, payload: try JSONValue(any: value), scope: scope))
            }
            return try outputItem(value).asReplayInput(scope: scope)
        }
        guard items.contains(where: { if case .replay(.compaction) = $0 { return true }; return false }) else { throw ModelError.protocolViolation("Compaction response missing compaction item") }
        return .init(id: id, scope: scope, input: items, usage: Self.usage(object["usage"] as? [String: Any]))
    }
}
