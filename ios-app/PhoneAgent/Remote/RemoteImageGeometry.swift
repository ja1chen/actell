import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// The v2 transform is deliberately limited to a full decoded visible raster.
/// No guessed UIKit scale, physical orientation, clean aperture or letterbox.
struct RemoteImageGeometry: Equatable, Sendable, Codable {
    static let contract = "thumbnail-v2"
    static let maxDimension = 1280
    static let maxAge: TimeInterval = 60
    static let maxBytes = 256 * 1024
    let revision: String
    let originalWidth: Int
    let originalHeight: Int
    let deliveredWidth: Int
    let deliveredHeight: Int

    init(revision: String, originalWidth: Int, originalHeight: Int, deliveredWidth: Int, deliveredHeight: Int) throws {
        guard !revision.isEmpty, [originalWidth, originalHeight, deliveredWidth, deliveredHeight].allSatisfy({ (2...16384).contains($0) }),
              originalWidth * originalHeight <= 24_000_000,
              deliveredWidth <= originalWidth, deliveredHeight <= originalHeight else {
            throw RemoteRPCError("invalid_geometry", "Invalid image geometry")
        }
        self.revision = revision; self.originalWidth = originalWidth; self.originalHeight = originalHeight
        self.deliveredWidth = deliveredWidth; self.deliveredHeight = deliveredHeight
    }
    var wire: [String: Any] {
        ["revision": revision, "coordinate_space": "delivered-image-pixels", "mapping": "endpoint-aligned-nearest-v1",
         "original_width": originalWidth, "original_height": originalHeight,
         "delivered_width": deliveredWidth, "delivered_height": deliveredHeight,
         "crop": ["x": 0, "y": 0, "width": originalWidth, "height": originalHeight],
         "geometry_validation": "cached-decoder-and-native-generation", "device_orientation": "unknown", "source_raster": "decoded-visible-image", "rotation_degrees": 0, "mirrored": false, "padding": ["left": 0, "top": 0, "right": 0, "bottom": 0]]
    }
    func originalPoint(x: Int, y: Int) throws -> (x: Int, y: Int) {
        guard (0..<deliveredWidth).contains(x), (0..<deliveredHeight).contains(y) else {
            throw RemoteRPCError("coordinate_out_of_bounds", "Coordinates must be integer pixels inside the delivered image")
        }
        // Integer arithmetic, nearest with positive half-ties up. Endpoints stay
        // endpoints through the existing InputCoordinates.normalized dimension-1 mapping.
        func map(_ p: Int, _ original: Int, _ delivered: Int) -> Int {
            (2 * p * (original - 1) + delivered - 1) / (2 * (delivered - 1))
        }
        return (map(x, originalWidth, deliveredWidth), map(y, originalHeight, deliveredHeight))
    }
}

struct RemoteThumbnail {
    let data: Data
    let geometry: RemoteImageGeometry
    let jpegQuality: Double

    static func make(frame: FrameImage) throws -> Self {
        guard frame.png.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(frame.png as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == frame.width,
              properties[kCGImagePropertyPixelHeight] as? Int == frame.height,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              frame.width > 1, frame.height > 1, frame.width <= 16384, frame.height <= 16384,
              frame.width * frame.height <= 24_000_000 else {
            throw RemoteRPCError("invalid_geometry", "Screenshot raster metadata is invalid or requires an unsupported orientation transform")
        }
        var edge = min(RemoteImageGeometry.maxDimension, max(frame.width, frame.height))
        while edge >= 2 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false, kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw RemoteRPCError("image_encoding_failed", "Cannot decode screenshot")
            }
            for quality in [0.8, 0.65, 0.5, 0.35] {
                let buffer = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), buffer.length <= RemoteImageGeometry.maxBytes {
                    let geometry = try RemoteImageGeometry(revision: UUID().uuidString, originalWidth: frame.width,
                        originalHeight: frame.height, deliveredWidth: image.width, deliveredHeight: image.height)
                    return Self(data: buffer as Data, geometry: geometry, jpegQuality: quality)
                }
            }
            edge = edge * 3 / 4
        }
        throw RemoteRPCError("image_budget_exceeded", "Cannot encode screenshot within the thumbnail budget")
    }
}

/// Separate from observation admission: historical JPEGs never authorize input.
/// Protected atomic records keep image retrieval independent of run ownership leases.
final class RemoteImageResultCache {
    static let retention: TimeInterval = 30 * 60
    static let maximumCount = 64
    static let maximumBytes = 16 * 1024 * 1024
    struct Record: Codable {
        let client: String
        let run: String
        let image: String
        let generation: Int
        let capturedAt: Date
        let width: Int
        let height: Int
        let geometry: RemoteImageGeometry
        let data: Data
        let sha256: String
        init(client: String, run: String, image: String, generation: Int, capturedAt: Date, width: Int, height: Int, geometry: RemoteImageGeometry, data: Data) {
            self.client = client; self.run = run; self.image = image; self.generation = generation; self.capturedAt = capturedAt
            self.width = width; self.height = height; self.geometry = geometry; self.data = data
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var expiresAt: Date { capturedAt.addingTimeInterval(RemoteImageResultCache.retention) }
    }
    private let directory: URL
    private let now: () -> Date
    init(directory: URL, now: @escaping () -> Date = Date.init) throws {
        self.directory = directory; self.now = now
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        _ = try inventory()
    }
    private func url(_ client: String, _ run: String, _ image: String) -> URL {
        let digest = SHA256.hash(data: Data((client + "/" + run + "/" + image).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    private func load(_ file: URL) throws -> Record? {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 400_000 else { throw RemoteRPCError("image_cache_invalid", "Image cache record exceeds its size budget") }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard record.data.count <= RemoteImageGeometry.maxBytes, record.width == record.geometry.deliveredWidth,
              record.height == record.geometry.deliveredHeight,
              record.sha256 == SHA256.hash(data: record.data).map({ String(format: "%02x", $0) }).joined(),
              file.standardizedFileURL.path == url(record.client, record.run, record.image).standardizedFileURL.path else { throw RemoteRPCError("image_cache_invalid", "Image cache identity is invalid") }
        if now() >= record.expiresAt { try FileManager.default.removeItem(at: file); return nil }
        return record
    }
    private func inventory() throws -> (records: [Record], unavailable: Int) {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
        var retained: [Record] = [], unavailable = 0
        for file in files {
            do { if let record = try load(file) { retained.append(record) } }
            catch let error as RemoteRPCError where error.code == "image_cache_invalid" { unavailable += 1 }
            catch is DecodingError { unavailable += 1 }
        }
        // A damaged historical image must not poison unrelated screenshots.
        // Keep counting its slot and worst-case bytes; never silently evict it.
        return (retained, unavailable)
    }
    func requireCapacity() throws {
        let retained = try inventory()
        guard retained.records.count + retained.unavailable < Self.maximumCount,
              retained.records.reduce(0, { $0 + $1.data.count }) + (retained.unavailable + 1) * RemoteImageGeometry.maxBytes <= Self.maximumBytes else {
            throw RemoteRPCError("image_storage_full", "Retained screenshot capacity is full; no screenshot was captured")
        }
    }
    func store(_ record: Record) throws {
        try requireCapacity()
        guard record.data.count <= RemoteImageGeometry.maxBytes else { throw RemoteRPCError("image_budget_exceeded", "Image exceeds cache budget") }
        try JSONEncoder().encode(record).write(to: url(record.client, record.run, record.image), options: [.atomic, .completeFileProtection])
    }
    func lookup(client: String, run: String, image: String, generation: Int) throws -> Record? {
        let file = url(client, run, image)
        guard FileManager.default.fileExists(atPath: file.path), let record = try load(file), record.generation == generation else { return nil }
        return record
    }
    func revoke(client: String) throws {
        for record in try inventory().records where record.client == client {
            try FileManager.default.removeItem(at: url(record.client, record.run, record.image))
        }
    }
}
