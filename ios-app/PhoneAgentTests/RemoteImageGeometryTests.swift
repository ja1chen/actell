import XCTest
import UIKit
import ImageIO
@testable import PhoneAgent

final class RemoteImageGeometryTests: XCTestCase {
    func testCacheAcceptsEquivalentFileURLRepresentationsAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = try XCTUnwrap(URL(string: "ImageResults/", relativeTo: root))
        let cache = try RemoteImageResultCache(directory: relative)
        let geometry = try RemoteImageGeometry(revision: "r", originalWidth: 10, originalHeight: 20, deliveredWidth: 10, deliveredHeight: 20)
        try cache.store(.init(client: "owner", run: "run", image: "image", generation: 1,
            capturedAt: Date(), width: 10, height: 20, geometry: geometry, data: Data([1, 2, 3])))
        XCTAssertNoThrow(try cache.requireCapacity()) // Enumerated URLs differ from URLs with a base.
        let restarted = try RemoteImageResultCache(directory: URL(fileURLWithPath: relative.path, isDirectory: true))
        XCTAssertEqual(try restarted.lookup(client: "owner", run: "run", image: "image", generation: 1)?.data, Data([1, 2, 3]))
        XCTAssertNil(try restarted.lookup(client: "other", run: "run", image: "image", generation: 1))
    }

    func testDamagedHistoricalImageDoesNotBlockOtherImagesButStillConsumesCapacity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try RemoteImageResultCache(directory: directory)
        let geometry = try RemoteImageGeometry(revision: "r", originalWidth: 10, originalHeight: 20, deliveredWidth: 10, deliveredHeight: 20)
        try cache.store(.init(client: "owner", run: "run", image: "old", generation: 1,
            capturedAt: Date(), width: 10, height: 20, geometry: geometry, data: Data([1])))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var damaged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        damaged["sha256"] = "wrong"
        let damagedData = try JSONSerialization.data(withJSONObject: damaged)
        try damagedData.write(to: file)
        let restarted = try RemoteImageResultCache(directory: directory)
        XCTAssertThrowsError(try restarted.lookup(client: "owner", run: "run", image: "old", generation: 1))
        try restarted.store(.init(client: "owner", run: "run", image: "new", generation: 2,
            capturedAt: Date(), width: 10, height: 20, geometry: geometry, data: Data([2])))
        XCTAssertEqual(try restarted.lookup(client: "owner", run: "run", image: "new", generation: 2)?.data, Data([2]))
        for index in 0..<62 { try Data("broken".utf8).write(to: directory.appendingPathComponent("broken-\(index).json")) }
        XCTAssertThrowsError(try restarted.requireCapacity())
        XCTAssertEqual(try Data(contentsOf: file), damagedData)
    }

    func testIndependentCoordinatesAndHistoricalImageRetention() throws {
        let snapshot = InputDisplaySnapshot(context: "session", token: "geometry", sampledAt: Date())
        XCTAssertEqual(try snapshot.normalized(0), 0)
        XCTAssertEqual(try snapshot.normalized(500), 32768)
        XCTAssertEqual(try snapshot.normalized(1000), 65535)
        XCTAssertThrowsError(try snapshot.normalized(-1))
        XCTAssertThrowsError(try snapshot.normalized(1001))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = Date(timeIntervalSince1970: 1000)
        var now = capture
        let geometry = try RemoteImageGeometry(revision: "r", originalWidth: 10, originalHeight: 20, deliveredWidth: 10, deliveredHeight: 20)
        let cache = try RemoteImageResultCache(directory: directory, now: { now })
        for id in ["first", "second"] {
            try cache.store(.init(client: "owner", run: "closed-run", image: id, generation: 1, capturedAt: capture, width: 10, height: 20, geometry: geometry, data: Data([1, 2, 3])))
        }
        now = capture.addingTimeInterval(61)
        let restarted = try RemoteImageResultCache(directory: directory, now: { now })
        XCTAssertNotNil(try restarted.lookup(client: "owner", run: "closed-run", image: "first", generation: 1))
        XCTAssertNil(try restarted.lookup(client: "other", run: "closed-run", image: "first", generation: 1))
        XCTAssertNil(try restarted.lookup(client: "owner", run: "closed-run", image: "first", generation: 2))
        now = capture.addingTimeInterval(1799)
        XCTAssertNotNil(try restarted.lookup(client: "owner", run: "closed-run", image: "first", generation: 1))
        now = capture.addingTimeInterval(1800)
        XCTAssertNil(try restarted.lookup(client: "owner", run: "closed-run", image: "first", generation: 1))
    }
    func testImageCapacityDoesNotEvictUnexpiredResultsAndRevocationCleans() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try RemoteImageResultCache(directory: directory)
        let geometry = try RemoteImageGeometry(revision: "r", originalWidth: 10, originalHeight: 20, deliveredWidth: 10, deliveredHeight: 20)
        for index in 0..<64 {
            try cache.store(.init(client: "owner", run: "run", image: String(index), generation: index, capturedAt: Date(), width: 10, height: 20, geometry: geometry, data: Data([1])))
        }
        XCTAssertThrowsError(try cache.requireCapacity())
        XCTAssertNotNil(try cache.lookup(client: "owner", run: "run", image: "0", generation: 0))
        try cache.revoke(client: "owner")
        XCTAssertNil(try cache.lookup(client: "owner", run: "run", image: "0", generation: 0))
        XCTAssertNoThrow(try cache.requireCapacity())
    }
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
