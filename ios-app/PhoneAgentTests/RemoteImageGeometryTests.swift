import XCTest
import UIKit
import ImageIO
@testable import PhoneAgent

final class RemoteImageGeometryTests: XCTestCase {
    func testPortraitLandscapeAndFractionalScaleVectors() throws {
        for (ow, oh, dw, dh) in [(1179, 2556, 590, 1280), (2556, 1179, 1280, 590), (1001, 777, 701, 544)] {
            let g = try RemoteImageGeometry(revision: "r", originalWidth: ow, originalHeight: oh, deliveredWidth: dw, deliveredHeight: dh)
            let origin = try g.originalPoint(x: 0, y: 0)
            XCTAssertEqual(origin.x, 0); XCTAssertEqual(origin.y, 0)
            let end = try g.originalPoint(x: dw - 1, y: dh - 1)
            XCTAssertEqual(end.x, ow - 1); XCTAssertEqual(end.y, oh - 1)
            XCTAssertEqual(try Wire.normalized(pixel: end.x, dimension: ow), 65535)
            XCTAssertEqual(try Wire.normalized(pixel: end.y, dimension: oh), 65535)
            let center = try g.originalPoint(x: dw / 2, y: dh / 2)
            XCTAssertEqual(center.x, Int((Double(dw / 2) * Double(ow - 1) / Double(dw - 1)).rounded()))
            XCTAssertEqual(center.y, Int((Double(dh / 2) * Double(oh - 1) / Double(dh - 1)).rounded()))
            for (x, y) in [(-1, 0), (0, -1), (dw, 0), (0, dh), (Int.max, Int.max)] {
                XCTAssertThrowsError(try g.originalPoint(x: x, y: y))
            }
        }
    }
    func testRejectsInvalidAndUpscaledGeometry() {
        XCTAssertThrowsError(try RemoteImageGeometry(revision: "r", originalWidth: 1, originalHeight: 30, deliveredWidth: 1, deliveredHeight: 20))
        XCTAssertThrowsError(try RemoteImageGeometry(revision: "r", originalWidth: 10, originalHeight: 20, deliveredWidth: 11, deliveredHeight: 20))
        XCTAssertThrowsError(try RemoteImageGeometry(revision: "", originalWidth: 10, originalHeight: 20, deliveredWidth: 10, deliveredHeight: 20))
    }
    @MainActor func testThumbnailBudgetRasterDimensionsAndImmutableOriginal() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 1179, height: 2556), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1179, height: 2556))
        }
        let frame = FrameImage(id: "fixture", png: bytes, width: 1179, height: 2556, capturedAt: Date(), isDemo: false)
        let thumbnail = try RemoteThumbnail.make(frame: frame)
        XCTAssertLessThanOrEqual(thumbnail.data.count, 256 * 1024)
        XCTAssertTrue(thumbnail.data.starts(with: [0xff, 0xd8, 0xff]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail.data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, thumbnail.geometry.deliveredWidth)
        XCTAssertEqual(decoded.height, thumbnail.geometry.deliveredHeight)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1280)
        XCTAssertEqual(thumbnail.geometry.originalWidth, 1179)
        XCTAssertEqual(frame.png, bytes)
        XCTAssertEqual(thumbnail.geometry.wire["device_orientation"] as? String, "unknown")
        let wrong = FrameImage(id: "wrong", png: bytes, width: 1184, height: 2576, capturedAt: Date(), isDemo: false)
        XCTAssertThrowsError(try RemoteThumbnail.make(frame: wrong))
    }
}
