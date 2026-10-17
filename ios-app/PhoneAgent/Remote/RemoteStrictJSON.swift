import Foundation

/// JSONSerialization alone silently accepts duplicate keys. This bounded scanner
/// rejects duplicates at every nesting level before Foundation parses the object.
/// It does not normalize bytes: HMAC still covers the original request body.
enum RemoteStrictJSON {
    static func validate(_ data: Data, maximumDepth: Int = 32, unsignedIntegersOnly: Bool = false) throws {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw RemoteRPCError("bad_request", "Invalid JSON size") }
        guard String(data: data, encoding: .utf8) != nil else { throw RemoteRPCError("bad_request", "Invalid UTF-8") }
        var parser = Scanner(bytes: Array(data), maximumDepth: maximumDepth, unsignedIntegersOnly: unsignedIntegersOnly)
        try parser.value(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count else { throw RemoteRPCError("bad_request", "Trailing JSON bytes") }
        _ = try JSONSerialization.jsonObject(with: data)
    }
    private struct Scanner {
        let bytes: [UInt8]
        let maximumDepth: Int
        let unsignedIntegersOnly: Bool
        var index = 0
        var tokens = 0
        mutating func space() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func expect(_ byte: UInt8) throws {
            space()
            guard index < bytes.count, bytes[index] == byte else { throw RemoteRPCError("bad_request", "Malformed JSON") }
            index += 1
        }
        mutating func string() throws -> String {
            space(); let start = index
            try expect(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                if byte == 92 {
                    guard index < bytes.count else { break }
                    index += 1
                }
            }
            throw RemoteRPCError("bad_request", "Unterminated JSON string")
        }
        mutating func value(depth: Int) throws {
            guard depth <= maximumDepth, tokens < 100_000 else { throw RemoteRPCError("bad_request", "JSON nesting or token limit exceeded") }
            tokens += 1; space()
            guard index < bytes.count else { throw RemoteRPCError("bad_request", "Missing JSON value") }
            switch bytes[index] {
            case 123:
                index += 1; space(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string()
                    guard keys.insert(key).inserted else { throw RemoteRPCError("bad_request", "Duplicate JSON key") }
                    try expect(58); try value(depth: depth + 1); space()
                    guard index < bytes.count else { throw RemoteRPCError("bad_request", "Unterminated JSON object") }
                    if bytes[index] == 125 { index += 1; return }
                    try expect(44)
                }
            case 91:
                index += 1; space()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    guard index < bytes.count else { throw RemoteRPCError("bad_request", "Unterminated JSON array") }
                    if bytes[index] == 93 { index += 1; return }
                    try expect(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw RemoteRPCError("bad_request", "Malformed JSON value") }
                if unsignedIntegersOnly {
                    let token = String(decoding: bytes[start..<index], as: UTF8.self)
                    guard !token.isEmpty, token.utf8.allSatisfy({ (48...57).contains($0) }),
                          token == "0" || !token.hasPrefix("0"), UInt32(token) != nil else {
                        throw RemoteRPCError("bad_request", "Expected unsigned 32-bit integer")
                    }
                }
            }
        }
    }
}

@MainActor enum RemoteToolSchema {
    static var capabilities: [[String: Any]] {
        RemoteToolsService.toolNames.map { name in
            let schema = DeviceTool.parameters(for: name)
            var properties: [String: Any] = [:]
            for (key, field) in schema.properties {
                var value: [String: Any] = ["type": field.type, "description": field.description]
                if let itemsType = field.itemsType { value["items"] = ["type": itemsType] }
                if let choices = field.enum { value["enum"] = choices }
                properties[key] = value
            }
            let parameters: [String: Any] = ["type": "object", "properties": properties,
                                            "required": schema.required, "additionalProperties": false]
            return ["name": name, "description": DeviceTool.description(for: name), "parameters": parameters]
        }
    }
}
