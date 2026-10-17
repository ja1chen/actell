import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// The v2 transform is deliberately limited to a full decoded visible raster.
/// No guessed UIKit scale, physical orientation, clean aperture or letterbox.
struct RemoteImageGeometry: Equatable, Sendable {
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
        // endpoints through the existing Wire.normalized dimension-1 mapping.
        func map(_ p: Int, _ original: Int, _ delivered: Int) -> Int {
            (2 * p * (original - 1) + delivered - 1) / (2 * (delivered - 1))
        }
        return (map(x, originalWidth, deliveredWidth), map(y, originalHeight, deliveredHeight))
    }
}

struct RemoteThumbnail {
    let data: Data
    let geometry: RemoteImageGeometry

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
                    return Self(data: buffer as Data, geometry: geometry)
                }
            }
            edge = edge * 3 / 4
        }
        throw RemoteRPCError("image_budget_exceeded", "Cannot encode screenshot within the thumbnail budget")
    }
}
