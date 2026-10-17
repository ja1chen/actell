// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import ImageIO
import CoreImage
import CoreVideo
import CNCMBackend
@testable import PhoneAgentNCM
final class NativeBackendTests: XCTestCase {
    @MainActor func testDisplayMetadataCropsDecodedFrameAndRejectsInvalidBounds() async throws {
        var bytes = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGgAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAggYWWVmkkyvAWgIAAAAMAgAAAAwCERAHBcrQiQAAAABYoAa8TgOUyUf/aKP+n1f6Aa0AIIx2H")!
        bytes[36] = 3
        bytes.insert(contentsOf: [62,0,0,0,94,0,0,0], at: 64)
        XCTAssertEqual(try NCMVideoSample(bytes).visibleSize, CGSize(width:62,height:94))
        let decoder = NCMVideoDecoder()
        try await decoder.consume(bytes)
        let output = try await decoder.jpeg(notBefore: .now.advanced(by: .seconds(-1)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(output) as CFData,nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(image.width,62); XCTAssertEqual(image.height,94)
        let firstGeometry = await decoder.currentGeometryToken()
        bytes[0] = 2; bytes[64] = 61
        try await decoder.consume(bytes)
        let changedGeometry = await decoder.currentGeometryToken()
        XCTAssertNotNil(changedGeometry)
        XCTAssertNotEqual(changedGeometry, firstGeometry, "Visible crop changes invalidate the geometry token")
        bytes[64] = 65
        XCTAssertThrowsError(try NCMVideoSample(bytes))
    }
    @MainActor func testPredictiveVideoFrameUpdatesScreenshotWithoutInputOrNewKeyframe() async throws {
        // Synthetic green IDR followed by blue P-frame, encoded with libx265.
        var first = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGwAAAEABDAH//wFgAAADAJAAAAMAAAMAHpKAkEIBAQFgAAADAJAAAAMAAAMAHqAggYWWSpJMrwFoCAAAAwAIAAADAAhARAHBcrQiQAAAABcoAa8TgOUyUf/ySo/+t9X+gGtACCMdhw==")!
        let second = Data(base64Encoded: "AgAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAAAAAEAAAABgAAAAGAAAACkAAAAHAAAAIAAAAEABDAH//wFgAAADAJAAAAMAAAMAHpKAkEIBAQFgAAADAJAAAAMAAAMAHqAggYWWSpJMrwFoCAAAAwAIAAADAAhARAHBcrQiQAAAABwCAdAJfik2BHDwBOmDhifhmQd71Nsf/55oTwLA")!
        let original = try NCMVideoSample(first)
        let nalOffset = 64 + original.parameters.reduce(0) { $0 + $1.count }
        first[nalOffset + 3] += 14
        first.append(contentsOf: [0,64,0,96,0,0,3,0,0,0,62,0,94,3])
        var size = UInt32(original.bytes.count + 14).littleEndian
        withUnsafeBytes(of: &size) { first.replaceSubrange(60..<64, with: $0) }
        XCTAssertFalse(try NCMVideoSample(second).sync)
        let decoder = NCMVideoDecoder()
        try await decoder.consume(first)
        let initial = try await decoder.jpeg(notBefore: .now.advanced(by: .seconds(-1)))
        let green = try XCTUnwrap(initial)
        let initialGeometry = await decoder.currentGeometryToken()
        XCTAssertNotNil(initialGeometry)
        let capturedGeometry = await decoder.capturedGeometryToken()
        XCTAssertEqual(capturedGeometry, initialGeometry)
        try await Task.sleep(for: .milliseconds(1100))
        try await decoder.consume(second)
        let updated = try await decoder.jpeg(notBefore: .now.advanced(by: .seconds(-1)))
        let blue = try XCTUnwrap(updated)
        let updatedGeometry = await decoder.currentGeometryToken()
        XCTAssertEqual(updatedGeometry, initialGeometry, "Animation changes pixels, not geometry")
        XCTAssertNotEqual(green, blue, "A P-frame must update the screenshot without input or another keyframe")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(blue as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width,62); XCTAssertEqual(image.height,94, "Content geometry persists when later P-frames omit the trailer")
        await decoder.reset()
        let resetGeometry = await decoder.currentGeometryToken()
        XCTAssertNil(resetGeometry, "A reset invalidates geometry before another frame")
    }
    func testSWContentsRectFooterHandlesEscapingAcrossSliceBoundary() throws {
        func escaped(_ raw: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [], zeros = 0
            for byte in raw {
                if zeros == 2, byte <= 3 { out.append(3); zeros = 0 }
                out.append(byte); zeros = byte == 0 ? zeros+1 : 0
            }
            return out
        }
        func sample(_ body: [UInt8]) -> Data {
            let nal: [UInt8] = [0x28,1] + escaped(body)
            let n = UInt32(nal.count).bigEndian
            var data = withUnsafeBytes(of:n) { Data($0) }; data.append(contentsOf:nal); return data
        }
        // Captured contentsRect payload: origin 0,0; 1179x2556; terminal flag 2.
        let footer: [UInt8] = [0,0,0,0,4,155,9,252,2]
        let bodies: [[UInt8]] = [[0xaa,0x80],[0xaa,0x80,0],[0xaa,0x80,0,0]]
        for body in bodies {
            let parsed = try NCMDisplayPicture(sample(body+footer),codedWidth:1184,codedHeight:2576)
            XCTAssertEqual(parsed.visibleWidth,1179); XCTAssertEqual(parsed.visibleHeight,2556)
            XCTAssertEqual(parsed.bytes,sample(body), "Slice bytes must survive footer removal, including emulation prevention across the boundary")
        }
        var bad = footer; bad[0] = 1
        let unchanged = sample([0xaa]+bad)
        let parsed = try NCMDisplayPicture(unchanged,codedWidth:1184,codedHeight:2576)
        XCTAssertNil(parsed.visibleWidth); XCTAssertEqual(parsed.bytes,unchanged)
        let landscape = try NCMDisplayPicture(sample([0xaa]+footer),codedWidth:2576,codedHeight:1184)
        XCTAssertNil(landscape.visibleWidth)
    }
    func testDisplayServiceTrailerDeclaresCanvasAndContentWithoutExternalScreenSize() throws {
        func picture(_ suffix: [UInt8]) -> Data {
            let nal: [UInt8] = [0x26, 1, 0xaa, 0xbb] + suffix
            let n = UInt32(nal.count).bigEndian
            var data = withUnsafeBytes(of: n) { Data($0) }; data.append(contentsOf: nal); return data
        }
        // Existing captured upstream fixture, previously hardcoded as a suffix to discard.
        let observed: [UInt8] = [0x04,0xf0,0x0a,0xc0,0,0,3,0,0,0x04,0xec,0x0a,0xb0,3]
        let parsed = try NCMDisplayPicture(picture(observed), codedWidth: 1264, codedHeight: 2752)
        XCTAssertEqual(parsed.visibleWidth,1260); XCTAssertEqual(parsed.visibleHeight,2736)
        XCTAssertEqual(parsed.bytes, Data([0,0,0,4,0x26,1,0xaa,0xbb]))
        let phone: [UInt8] = [0x04,0xa0,0x0a,0x10,0,0,3,0,0,0x04,0x9b,0x09,0xfc,3]
        let current = try NCMDisplayPicture(picture(phone), codedWidth: 1184, codedHeight: 2576)
        XCTAssertEqual(current.visibleWidth,1179); XCTAssertEqual(current.visibleHeight,2556)
        // A coincidental suffix from another canvas must remain untouched.
        let mismatch = try NCMDisplayPicture(picture(phone), codedWidth: 1280, codedHeight: 2592)
        XCTAssertNil(mismatch.visibleWidth); XCTAssertEqual(mismatch.bytes, picture(phone))
        var unknown = phone; unknown[4] = 1
        XCTAssertNil(try NCMDisplayPicture(picture(unknown), codedWidth: 1184, codedHeight: 2576).visibleWidth)
        XCTAssertThrowsError(try NCMDisplayPicture(Data([0,0,0,20,1]), codedWidth:1184, codedHeight:2576))
    }
    func testPreferredApertureOverridesFullFrameAndKeepsOffsets() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
            nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        let aperture = [kCVImageBufferCleanApertureWidthKey: 66,
                        kCVImageBufferCleanApertureHeightKey: 98,
                        kCVImageBufferCleanApertureHorizontalOffsetKey: -15,
                        kCVImageBufferCleanApertureVerticalOffsetKey: -9] as CFDictionary
        // Confirm offset interpretation against CoreVideo itself, then provide
        // only PreferredCleanAperture (ordinary clean rect remains full size).
        CVBufferSetAttachment(buffer, kCVImageBufferCleanApertureKey, aperture, .shouldPropagate)
        let expected = CVImageBufferGetCleanRect(buffer)
        XCTAssertEqual(expected, CGRect(x: 16, y: 24, width: 66, height: 98))
        CVBufferRemoveAttachment(buffer, kCVImageBufferCleanApertureKey)
        CVBufferSetAttachment(buffer, kCVImageBufferPreferredCleanApertureKey, aperture, .shouldPropagate)
        XCTAssertEqual(CVImageBufferGetCleanRect(buffer), CGRect(x: 0, y: 0, width: 128, height: 128))
        XCTAssertEqual(try NCMVideoImage.visibleRect(buffer: buffer, width: 128, height: 128,
            formatAperture: CGRect(x: 0, y: 0, width: 128, height: 128)), expected)
        // Invalid preferred geometry must never crop arbitrary pixels.
        CVBufferSetAttachment(buffer, kCVImageBufferPreferredCleanApertureKey,
            [kCVImageBufferCleanApertureWidthKey: 999, kCVImageBufferCleanApertureHeightKey: 98] as CFDictionary, .shouldPropagate)
        XCTAssertEqual(try NCMVideoImage.visibleRect(buffer: buffer, width: 128, height: 128),
            CGRect(x: 0, y: 0, width: 128, height: 128))
    }
    func testScreenshotCropsAlignedPaddingAndProducesOpaqueJPEG() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        let context = CIContext()
        let visible = CGRect(x: 0, y: 30, width: 66, height: 98)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: visible)
        context.render(green.composited(over: black), to: buffer)
        let rect = try NCMVideoImage.visibleRect(buffer: buffer, width: 66, height: 98)
        XCTAssertEqual(rect, visible)
        let jpeg = try NCMVideoImage.jpeg(buffer: buffer, rect: rect, context: context)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 66); XCTAssertEqual(image.height, 98)
        // All four corners must be actual picture pixels, not right/bottom allocation padding.
        var rgba = [UInt8](repeating: 0, count: 66 * 98 * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let bitmap = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 66, height: 98,
                bitsPerComponent: 8, bytesPerRow: 66 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: 66, height: 98))
        }
        for pixel in [0, 65, 97 * 66, 98 * 66 - 1] {
            XCTAssertGreaterThan(rgba[pixel * 4 + 1], 240)
            XCTAssertEqual(rgba[pixel * 4 + 3], 255)
        }
        XCTAssertThrowsError(try NCMVideoImage.visibleRect(buffer: buffer, width: 129, height: 98))
    }
    func testScreenshotRespectsDeclaredApertureOffset() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
            nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        let rect = try NCMVideoImage.visibleRect(buffer: buffer, width: 66, height: 98,
            formatAperture: CGRect(x: 16, y: 6, width: 66, height: 98))
        XCTAssertEqual(rect, CGRect(x: 16, y: 24, width: 66, height: 98))
    }
    func testScreenshotTimeoutReasonDistinguishesTransportAssemblyAndFreshness() {
        XCTAssertEqual(NCMVideoSnapshotFailure.timeoutCause(datagrams: 0, rtp: 0, frames: 0, overflows: 0), 8)
        XCTAssertEqual(NCMVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 0, frames: 0, overflows: 0), 9)
        XCTAssertEqual(NCMVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 4, frames: 0, overflows: 0), 10)
        XCTAssertEqual(NCMVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 4, frames: 1, overflows: 0), 11)
        XCTAssertEqual(NCMVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 4, frames: 1, overflows: 1), 12)
        XCTAssertEqual(NCMVideoSnapshotFailure.timeoutCause(datagrams: 4, rtp: 4, frames: 1, overflows: 1, initialOverflows: 1), 11, "Historical overload must not label a later screenshot failure")
    }
    @MainActor func testIdleSnapshotRequiresConfirmedSerialAndEpoch() async throws {
        let bytes = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGgAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAggYWWVmkkyvAWgIAAAAMAgAAAAwCERAHBcrQiQAAAABYoAa8TgOUyUf/aKP+n1f6Aa0AIIx2H")!
        let decoder = NCMVideoDecoder()
        try await decoder.consume(bytes)
        let began = ContinuousClock.now.advanced(by: .seconds(2))
        let unconfirmed = try await decoder.jpeg(notBefore: began)
        XCTAssertNil(unconfirmed, "A stale image alone does not prove a live static screen")
        let confirmed = try await decoder.jpeg(notBefore: began, confirmedEpoch: 1, confirmedSerial: 1)
        XCTAssertNotNil(confirmed, "Sender-confirmed complete picture stays valid while static")
        let behind = try await decoder.jpeg(notBefore: began, confirmedEpoch: 1, confirmedSerial: 2)
        XCTAssertNil(behind, "Decoder must catch up to the peer confirmation")
        let otherEpoch = try await decoder.jpeg(notBefore: began, confirmedEpoch: 2, confirmedSerial: 1)
        XCTAssertNil(otherEpoch, "Confirmation cannot cross a reset")
        await decoder.reset()
        let reset = try await decoder.jpeg(notBefore: began, confirmedEpoch: 1, confirmedSerial: 1)
        XCTAssertNil(reset, "Reset pixels cannot satisfy an earlier confirmation")
    }
    @MainActor func testHEVCConformanceCropProducesExactVisibleScreenshotDimensions() async throws {
        let decoder = NCMVideoDecoder()
        let began = ContinuousClock.now
        try await decoder.consume(Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEIAAABiAAAAGAAAACsAAAAHAAAAJwAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAkgackmWVmkkyvAWgIAAADAAgAAAMACEBEAcFytCJAAAAAIygBrxOA5TJR//JKj/631f6Aa0AIRUTVT4gVgwAAAwAHGETA")!)
        let output = try await decoder.jpeg(notBefore: began)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(output) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 66); XCTAssertEqual(image.height, 98)
    }
    @MainActor func testHEVCDecodeProducesJPEGAndResetRejectsPreviousFrame() async throws {
        // Synthetic 64x96 green frame, generated with FFmpeg/libx265; no device pixels.
        let bytes = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGgAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAggYWWVmkkyvAWgIAAAAMAgAAAAwCERAHBcrQiQAAAABYoAa8TgOUyUf/aKP+n1f6Aa0AIIx2H")!
        let sample = try NCMVideoSample(bytes)
        XCTAssertEqual(sample.width, 64); XCTAssertEqual(sample.height, 96)
        XCTAssertTrue(sample.sync)
        let decoder = NCMVideoDecoder()
        let began = ContinuousClock.now
        try await decoder.consume(bytes)
        let output = try await decoder.jpeg(notBefore: began)
        let jpeg = try XCTUnwrap(output)
        XCTAssertTrue(jpeg.starts(with: [0xff, 0xd8, 0xff]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 96)
        let future = try await decoder.jpeg(notBefore: ContinuousClock.now)
        XCTAssertNil(future, "a previous frame must not satisfy a later screenshot")
        await decoder.reset()
        let cleared = try await decoder.jpeg(notBefore: began)
        XCTAssertNil(cleared)
        var malformed = bytes; malformed.removeLast()
        XCTAssertThrowsError(try NCMVideoSample(malformed))
    }
    @MainActor func testLockdownGateIsIndependentOfRemotePairing() async {
        let client = NativeLockdownSession()
        do { try await client.connect(pairingRecord: Data("rp-record".utf8), expectedUDID: "PUBLIC-TEST", authorized: false); XCTFail("authorization gate") }
        catch { XCTAssertEqual(error as? NativeBackendError, .authorizationRequired) }
        do { try await client.stop(); XCTFail("idle session") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
        var handle: UInt64 = 55
        let invalid = Data("rp-record".utf8), udid = Data("PUBLIC-TEST".utf8)
        invalid.withUnsafeBytes { record in udid.withUnsafeBytes { peer in
            let r = ncm_bytes(data: record.bindMemory(to: UInt8.self).baseAddress, size: record.count)
            let u = ncm_bytes(data: peer.bindMemory(to: UInt8.self).baseAddress, size: peer.count)
            XCTAssertEqual(ncm_lockdown_start(1, 8, r, u, &handle), 1)
            XCTAssertEqual(handle, 0)
        }}
        client.close(); client.close()
    }
    @MainActor func testActualNativeABIAndMalformedIdentityBoundary() throws {
        XCTAssertEqual(NativeDeveloperServices.linkedABIVersion, 1)
        XCTAssertEqual(MemoryLayout<ncm_event>.size, 32)
        var handle: UInt64 = 44
        XCTAssertEqual(ncm_backend_start(nil, nil, &handle), 1)
        XCTAssertThrowsError(try AuthorizedRemoteIdentity(signingSeed: Data(), controllerID: "test", peerID: "test", peerPublicKey: Data(), alternateIRK: Data(), peerUDID: "test", peerModel: "test"))
        XCTAssertEqual(ncm_backend_submit(0, 1, 2, 0, 0), 3)
    }
    @MainActor func testIdleNativeWrapperDoesNotConnect() async {
        let client = NativeDeveloperServices()
        do { _ = try await client.listServices(); XCTFail("idle client") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
        client.close(); client.close()
    }
    @MainActor func testVerifyConsentGateRunsBeforeAnyInterfaceOrSocket() async throws {
        // Synthetic bytes only; no pairing record is generated or persisted.
        let identity = try AuthorizedRemoteIdentity(signingSeed: Data(repeating: 0x42, count: 32), controllerID: "SYNTHETIC", peerID: "SYNTHETIC", peerPublicKey: Data(repeating: 0x44, count: 32), alternateIRK: Data(repeating: 0x33, count: 16), peerUDID: "SYNTHETIC", peerModel: "SYNTHETIC")
        let discovery = try DiagnosticReply.decode(Data("{\"protocol\":\"ND1\",\"layer\":\"discovery\",\"result\":\"candidates\",\"authenticated\":false,\"generation\":7,\"endpoints\":[{\"index\":0,\"service\":\"remotepairing\",\"family\":4,\"port\":54321}]}\n".utf8))
        let client = NativeDeveloperServices()
        do { try await client.connect(identity: identity, authorization: .init(verifyExistingIdentity: false), discovery: discovery, endpoint: discovery.endpoints![0]); XCTFail("consent gate") }
        catch { XCTAssertEqual(error as? NativeBackendError, .authorizationRequired) }
    }
    #if NCM_OFFLINE_FIXTURES
    func testSkippedPredictiveFrameDoesNotReportDecodeSuccess() async throws {
        var bytes = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGgAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAggYWWVmkkyvAWgIAAAAMAgAAAAwCERAHBcrQiQAAAABYoAa8TgOUyUf/aKP+n1f6Aa0AIIx2H")!
        let decoder = NCMVideoDecoder()
        let decoded = try await decoder.consume(bytes)
        XCTAssertTrue(decoded)
        await decoder.reset()
        bytes.replaceSubrange(0..<8, with: withUnsafeBytes(of: UInt64(2).littleEndian) { Data($0) })
        bytes[36] = 0
        let skipped = try await decoder.consume(bytes)
        XCTAssertFalse(skipped, "Skipping a dependent frame must not clear a prior decoder failure")
        let image = try await decoder.jpeg(notBefore: .now.advanced(by: .seconds(-1)))
        XCTAssertNil(image)
    }

    @MainActor func testIdleVideoSnapshotsAcceptSenderConfirmedPictureButRejectSilentPeer() async throws {
        let bytes = Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGgAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAggYWWVmkkyvAWgIAAAAMAgAAAAwCERAHBcrQiQAAAABYoAa8TgOUyUf/aKP+n1f6Aa0AIIx2H")!
        let client = NativeDeveloperServices()
        try await client.connectVideoBurstFixture(bytes, continuous: false)
        defer { client.close() }
        try await client.startTouchMedia()
        let first = try await client.captureVideoJPEG()
        XCTAssertTrue(first.starts(with: [0xff, 0xd8, 0xff]))
        // The fixture sends no future pictures, only progress reports for
        // three seconds, then goes silent without closing authentication.
        try await Task.sleep(for: .milliseconds(100))
        let repeated = try await client.captureVideoJPEG()
        XCTAssertEqual(repeated, first)
        XCTAssertTrue(client.videoSnapshotDiagnostics?.contains("received=true") == true)
        try await Task.sleep(for: .milliseconds(1200))
        let idle = try await client.captureVideoJPEG()
        XCTAssertEqual(idle, first, "A picture older than one second remains valid with current sender confirmation")
        try await Task.sleep(for: .milliseconds(2100))
        do { _ = try await client.captureVideoJPEG(); XCTFail("A silent peer cannot validate cached pixels or trigger stream replacement") }
        catch { guard case NativeBackendError.screenshotFailure(stage: 20, cause: _) = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertTrue(client.videoSnapshotDiagnostics?.contains("timeout=true") == true)
        // A failed read leaves the same authenticated tunnel usable.
        try await client.checkDeveloperReadiness()
        try await client.stopTouchMedia()
    }

    @MainActor func testDemandScreenshotDecodesLatestNativeBurstAndCanReopenAfterRelease() async throws {
        let bytes=Data(base64Encoded: "AQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAACQXwEAAQAAAEAAAABgAAAAGAAAACkAAAAHAAAAGgAAAEABDAH//wFgAAADAJAAAAMAAAMAHpWYCUIBAQFgAAADAJAAAAMAAAMAHqAggYWWVmkkyvAWgIAAAAMAgAAAAwCERAHBcrQiQAAAABYoAa8TgOUyUf/aKP+n1f6Aa0AIIx2H")!
        let client=NativeDeveloperServices()
        try await client.connectVideoBurstFixture(bytes)
        defer { client.close() }
        for _ in 0..<2 {
            // 1000 keyframes + inter frames arrive before Swift consumes any video.
            try await client.startTouchMedia()
            let jpeg=try await client.captureVideoJPEG()
            XCTAssertTrue(jpeg.starts(with:[0xff,0xd8,0xff]))
            let source=try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData,nil))
            let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            XCTAssertEqual(image.width,64); XCTAssertEqual(image.height,96)
            let geometry = try XCTUnwrap(client.capturedVideoGeometryToken)
            try await client.validateVideoGeometry(geometry)
            do { try await client.validateVideoGeometry("invalid-token"); XCTFail("Invalid token must fail") }
            catch { XCTAssertEqual(error as? NativeInputGeometryError, NativeInputGeometryError(.invalidToken)) }
            try await client.validateVideoGeometry(geometry)
            // Only non-sync frames follow the initial keyframe. Repeated idle
            // screenshots after the old one-second expiry must still work.
            try await Task.sleep(for: .milliseconds(1200))
            let repeated = try await client.captureVideoJPEG()
            XCTAssertTrue(repeated.starts(with: [0xff,0xd8,0xff]))
            try await client.stopTouchMedia()
            try await client.checkDeveloperReadiness()
            do { _ = try await client.captureVideoJPEG(); XCTFail("Released media must not return cached pixels") }
            catch { XCTAssertEqual(error as? NativeBackendError,.closed) }
        }
    }
    @MainActor func testOwnedMediaReleaseRetainsNativeAuthenticationAndIsIdempotent() async throws {
        let client = NativeDeveloperServices()
        try await client.connectMediaFailureFixture()
        try await client.stopTouchMedia()
        try await client.stopTouchMedia()
        try await client.checkDeveloperReadiness()
        do { _ = try await client.captureVideoJPEG(); XCTFail("released media must not return an old image") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
        client.close()
    }
    @MainActor func testScreenshotServiceFailureRetainsNativeSessionWithoutReplayingInput() async throws {
        let client = NativeDeveloperServices()
        try await client.connectMediaFailureFixture()
        for _ in 0..<2 {
            do { _ = try await client.capturePNG(); XCTFail("expected screenshot connection failure") }
            catch { XCTAssertEqual(error as? NativeBackendError, .screenshotFailure(stage: 19, cause: 1)) }
            // Cross the same native handle after each explicitly requested capture.
            try await client.checkDeveloperReadiness()
        }
        do { _ = try await client.tapDelivery(x: 1, y: 1); XCTFail("expected uncertain delivery") }
        catch { XCTAssertEqual(error as? NativeBackendError, .protocolFailure(stage: 11, cause: 7)) }
        do { _ = try await client.listServices(); XCTFail("uncertain input must still close") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
        client.close()
    }
    @MainActor func testMediaPreparationFailureRetainsSessionButUncertainTouchClosesIt() async throws {
        let client = NativeDeveloperServices()
        try await client.connectMediaFailureFixture()
        do { try await client.startTouchMedia(); XCTFail("expected preparation timeout") }
        catch { XCTAssertEqual(error as? NativeBackendError, .touchPreparationFailure(stage: 15, cause: 2)) }
        // This crosses the same native handle after failure, not just a cached UI flag.
        try await client.checkDeveloperReadiness()
        do { _ = try await client.tapDelivery(x: 32768, y: 32768); XCTFail("expected uncertain delivery") }
        catch { XCTAssertEqual(error as? NativeBackendError, .protocolFailure(stage: 11, cause: 7)) }
        do { _ = try await client.listServices(); XCTFail("uncertain touch must close") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
        client.close()
    }
    @MainActor func testInputGeometryQueryTimeoutRetainsNativeSession() async throws {
        let client = NativeDeveloperServices()
        try await client.connectMediaFailureFixture()
        defer { client.close() }
        do { _ = try await client.inputDisplayGeometry(); XCTFail("Expected metadata timeout") }
        catch { XCTAssertEqual(error as? NativeInputGeometryError, NativeInputGeometryError(.metadataQuery, stage: 11, cause: 2)) }
        // Cross the native worker again, not merely its cached ready flag.
        try await client.checkDeveloperReadiness()
        do { try await client.validateVideoGeometry("synthetic|1"); XCTFail("No decoder") }
        catch { XCTAssertEqual(error as? NativeInputGeometryError, NativeInputGeometryError(.decoderUnavailable)) }
        try await client.checkDeveloperReadiness()
        client.closeWorkerFixture() // Worker can close while Swift still caches ready=true.
        do { try await client.validateVideoGeometry("synthetic|1"); XCTFail("Closed worker is fatal") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
    }
    @MainActor func testDragCrossesNativeABIAndUncertainDeliveryClosesSession() async throws {
        let client = NativeDeveloperServices()
        try await client.connectMediaFailureFixture()
        do { _ = try await client.dragDelivery(fromX: 0, fromY: 65535, toX: 65535, toY: 0, durationMS: 99); XCTFail("invalid duration") }
        catch { XCTAssertEqual(error as? NativeBackendError, .malformedEvent) }
        try await client.checkDeveloperReadiness()
        do { _ = try await client.dragDelivery(fromX: 0, fromY: 65535, toX: 65535, toY: 0, durationMS: 1000); XCTFail("uncertain drag") }
        catch { XCTAssertEqual(error as? NativeBackendError, .protocolFailure(stage: 11, cause: 7)) }
        do { _ = try await client.listServices(); XCTFail("uncertain drag must close") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
    }
    private final class Fixture {
        let process = Process()
        let output = Pipe()
        let port: UInt16
        init(hold: Bool) throws {
            guard let path = ProcessInfo.processInfo.environment["NCM_RELAY_FIXTURE"] else { throw XCTSkip("fixture executable absent") }
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = hold ? ["hold"] : []
            process.standardOutput = output
            try process.run()
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
            guard let parsed = UInt16(String(decoding: line, as: UTF8.self)) else { throw NativeBackendError.malformedEvent }
            port = parsed
        }
        func finish() -> String {
            process.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        deinit { if process.isRunning { process.terminate() } }
    }
    @MainActor func testSwiftRustRealCRelayPropagatesPairVerifyFailure() async throws {
        let fixture = try Fixture(hold: false), client = NativeDeveloperServices()
        do { try await client.connectLoopbackFixture(port: fixture.port); XCTFail("synthetic peer never authenticates") }
        catch { XCTAssertEqual(error as? NativeBackendError, .protocolFailure(stage: 3, cause: 1)) }
        let evidence = fixture.finish()
        XCTAssertEqual(fixture.process.terminationStatus, 0)
        XCTAssertTrue(evidence.contains("GREETING")); XCTAssertTrue(evidence.contains("VERIFY_M1")); XCTAssertTrue(evidence.contains("CLOSED"))
        do { _ = try await client.listServices(); XCTFail("failed generation reused") } catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
    }
    @MainActor func testSwiftCancellationClosesNativeWorkerAndCRelay() async throws {
        let fixture = try Fixture(hold: true), client = NativeDeveloperServices()
        let task = Task { @MainActor in try await client.connectLoopbackFixture(port: fixture.port) }
        // Await actual synthetic wire evidence; detached reader leaves MainActor
        // free for connect/poll, and no timing assumption decides cancellation.
        let read = Task.detached { () -> String in
            var line = Data()
            while let byte = try fixture.output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
            return String(decoding: line, as: UTF8.self)
        }
        let greeting = try await read.value
        XCTAssertEqual(greeting, "GREETING")
        task.cancel()
        do { try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let evidence = fixture.finish(); XCTAssertEqual(fixture.process.terminationStatus, 0); XCTAssertTrue(evidence.contains("CLOSED"))
        client.close()
    }
    #endif
}
