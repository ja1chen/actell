import Foundation
import CryptoKit
import ImageIO

// JSONValue never carries credentials. The TLS PSK stays in Security/Network.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String), int(Int), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var int: Int? { if case .int(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
}
struct Envelope: Codable, Sendable {
    let version: Int
    let session_id: String
    let request_id: String
    let type: String
    let payload: [String: JSONValue]
    init(session: String, request: String, type: String, payload: [String: JSONValue]) {
        version = 1; session_id = session; request_id = request; self.type = type; self.payload = payload
    }
}
enum Wire {
    static let port: UInt16 = 28765
    static let maxFrameBytes = 65_536
    static let maxImageBytes = 15 * 1_024 * 1_024
    static let maxChunkBytes = 16_384
    static func encode(_ envelope: Envelope) throws -> Data {
        let body = try JSONEncoder().encode(envelope)
        guard !body.isEmpty, body.count <= maxFrameBytes else { throw AppError.protocolViolation(String(localized: "Control frame is too large")) }
        var length = UInt32(body.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(body); return data
    }
    static func length(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw AppError.protocolViolation(String(localized: "Invalid frame header length")) }
        let n = header.reduce(0) { ($0 << 8) | Int($1) }
        guard n > 0, n <= maxFrameBytes else { throw AppError.protocolViolation(String(localized: "Rejected an invalid or oversized frame")) }; return n
    }
    static func normalized(pixel: Int, dimension: Int) throws -> Int {
        guard dimension > 1, pixel >= 0, pixel < dimension else { throw AppError.invalid(String(localized: "Coordinates are outside the current screenshot")) }
        return Int((Double(pixel) / Double(dimension - 1) * 65_535).rounded())
    }
}
struct ImageAssembler {
    private(set) var id: String?
    private var bytes = Data()
    private var nextSequence = 0
    private var ceiling = 0
    private var completed: FrameImage?
    mutating func begin(_ p: [String: JSONValue], limit: Int) throws {
        guard id == nil, let imageID = p["image_id"]?.string, !imageID.isEmpty, imageID.count <= 128,
              p["mime_type"]?.string == "image/png", let cap = p["max_bytes"]?.int,
              cap > 0, cap <= limit, cap <= Wire.maxImageBytes else { throw AppError.protocolViolation(String(localized: "Invalid screenshot header")) }
        id = imageID; ceiling = cap
    }
    mutating func chunk(_ p: [String: JSONValue]) throws {
        guard completed == nil, let id, p["image_id"]?.string == id,
              p["sequence"]?.int == nextSequence, p["offset"]?.int == bytes.count,
              let b64 = p["data_base64"]?.string, b64.utf8.count <= 21_848,
              let data = Data(base64Encoded: b64), !data.isEmpty, data.count <= Wire.maxChunkBytes,
              bytes.count + data.count <= ceiling else { throw AppError.protocolViolation(String(localized: "Invalid screenshot chunk order, size, or encoding")) }
        bytes.append(data); nextSequence += 1
    }
    mutating func end(_ p: [String: JSONValue]) throws {
        guard completed == nil, let id, p["image_id"]?.string == id,
              p["total_bytes"]?.int == bytes.count, !bytes.isEmpty,
              p["sha256"]?.string == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined(),
              bytes.prefix(8) == Data([137,80,78,71,13,10,26,10]),
              let width = p["width"]?.int, let height = p["height"]?.int,
              width > 1, height > 1, width <= 8_192, height <= 8_192,
              width * height <= 24_000_000,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw AppError.protocolViolation(String(localized: "Screenshot validation, dimensions, or PNG decoding failed")) }
        completed = FrameImage(id: id, png: bytes, width: width, height: height, capturedAt: Date(), isDemo: false)
    }
    func committed(imageID: String) throws -> FrameImage {
        guard let completed, completed.id == imageID else { throw AppError.protocolViolation(String(localized: "An unverified screenshot cannot be submitted")) }
        return completed
    }
}
