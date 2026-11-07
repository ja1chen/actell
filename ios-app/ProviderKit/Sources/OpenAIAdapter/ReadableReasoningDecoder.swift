import Foundation

/// Only explicit provider-supplied readable fields enter the presentation path.
/// Never interpret answer tags, signatures, encrypted data or unknown objects.
public struct ReadableReasoningDecoder {
    public init() {}
    public static let fields = ["reasoning_details", "reasoning_content", "reasoning"]
    private var source: String?
    private var lastDetail: String?

    public mutating func consume(_ message: [String: Any]) -> String {
        let details = (message["reasoning_details"] as? [[String: Any]] ?? []).compactMap { item -> (String, String)? in
            let type = item["type"] as? String ?? ""
            let field: String
            switch type {
            case "reasoning.summary": field = "summary"
            case "reasoning.text": field = "text"
            default: return nil
            }
            guard let text = item[field] as? String, !text.isEmpty else { return nil }
            let key = type + ":" + ((item["index"] as? NSNumber)?.stringValue ?? (item["id"] as? String ?? ""))
            return (key, text)
        }
        if source == nil {
            if !details.isEmpty { source = "reasoning_details" }
            else { source = Self.fields.dropFirst().first { (message[$0] as? String)?.isEmpty == false } }
        }
        guard let source else { return "" }
        if source != "reasoning_details" { return message[source] as? String ?? "" }
        var result = ""
        for (key, text) in details {
            if let lastDetail, lastDetail != key { result += "\n\n" }
            result += text; lastDetail = key
        }
        return result
    }
    public static func text(in message: [String: Any]) -> String? {
        var decoder = Self(); let value = decoder.consume(message)
        return value.isEmpty ? nil : value
    }
    public static func removingFields(from message: [String: Any]) -> [String: Any] {
        message.filter { !fields.contains($0.key) }
    }
}
