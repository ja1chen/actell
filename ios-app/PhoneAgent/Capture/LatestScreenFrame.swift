import Foundation
import CoreVideo
import CoreMedia
import CoreImage
import ImageIO

struct CaptureStamp: Sendable, Equatable {
    let sequence: UInt64
    let uptime: TimeInterval
    let presentationSeconds: Double
    let width: Int
    let height: Int
    let videoOrientation: UInt32
}

struct CaptureDiagnostics: Sendable {
    let active: Bool
    let received: Int
    let accepted: Int
    let sequence: UInt64?
    let age: TimeInterval?
    let rejected: [String: Int]
    let orientationMetadata: String?
    var summary: String {
        let counts = rejected.keys.sorted().map { "\($0)=\(rejected[$0]!)" }.joined(separator: ",")
        return "capture active=\(active) samples=\(received) accepted=\(accepted) sequence=\(sequence.map(String.init) ?? "none") age=\(age.map { String(format: "%.2fs", $0) } ?? "none") rejected=[\(counts)] orientation=[\(orientationMetadata ?? "unread")]"
    }
}

enum CaptureSampleMetadata {
    struct VideoOrientation {
        let value: UInt32?
        let rejection: String?
        let diagnostic: String
    }

    /// CoreMedia has separate buffer-level and per-sample attachment stores.
    /// Read the same public SCK key in both; never infer orientation from the
    /// PhoneAgent scene, dimensions, another frame, or an assumed portrait value.
    static func videoOrientation(in buffer: CMSampleBuffer, key: String) -> VideoOrientation {
        let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[String: Any]])?.first
        let sampleValue = info?[key]
        let bufferValue = CMGetAttachment(buffer, key: key as CFString, attachmentModeOut: nil)
        let sampleOrientation = orientation(sampleValue), bufferOrientation = orientation(bufferValue)
        let shape = "sample=\(describe(sampleValue)) buffer=\(describe(bufferValue))"
        if sampleValue == nil && bufferValue == nil {
            return VideoOrientation(value: nil, rejection: "missingVideoOrientation", diagnostic: shape)
        }
        if (sampleValue != nil && sampleOrientation == nil) || (bufferValue != nil && bufferOrientation == nil) {
            return VideoOrientation(value: nil, rejection: "invalidVideoOrientation", diagnostic: shape)
        }
        if let sampleOrientation, let bufferOrientation, sampleOrientation != bufferOrientation {
            return VideoOrientation(value: nil, rejection: "conflictingVideoOrientation", diagnostic: shape)
        }
        let source = bufferOrientation != nil ? (sampleOrientation != nil ? "both" : "buffer") : "sample"
        return VideoOrientation(value: bufferOrientation ?? sampleOrientation, rejection: nil,
                                diagnostic: "\(shape) source=\(source)")
    }

    // Only type labels and numeric orientation values. Never dump attachment
    // dictionaries, arbitrary strings, screen pixels, or system identifiers.
    private static func describe(_ value: Any?) -> String {
        guard let value else { return "absent" }
        if let value = value as? CGImagePropertyOrientation { return "enum:\(value.rawValue)" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
            return "number:\(String(format: "%.6g", number.doubleValue))"
        }
        if value is String { return "string" }
        if value is Data { return "data" }
        if value is [Any] { return "array" }
        if value is NSDictionary { return "dictionary" }
        return "unsupportedType"
    }

    static func orientation(_ value: Any?) -> UInt32? {
        if let value = value as? CGImagePropertyOrientation { return value.rawValue }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue, (1...8).contains(number.doubleValue) else { return nil }
        return number.uint32Value
    }
}

// One retained pixel buffer, no per-frame Task or PNG backlog. All access is locked.
final class LatestScreenFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var frame: (CVPixelBuffer, CaptureStamp, Date)?
    private var accepting = false
    private var epoch = UUID()
    private var samples = 0
    private var accepted = 0
    private var rejected: [String: Int] = [:]
    private var orientationMetadata: String?
    private let context = CIContext(options: [.cacheIntermediates: false])

    @discardableResult func begin() -> UUID {
        lock.withLock {
            epoch = UUID(); accepting = true; frame = nil
            samples = 0; accepted = 0; rejected = [:]; orientationMetadata = nil
            return epoch
        }
    }
    func invalidate(epoch expected: UUID? = nil) {
        lock.withLock {
            guard expected == nil || expected == epoch else { return }
            accepting = false; frame = nil; epoch = UUID()
        }
    }
    func put(_ pixel: CVPixelBuffer, orientation: UInt32, presentationSeconds: Double,
             epoch expected: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            guard accepting, epoch == expected, (1...8).contains(orientation), presentationSeconds.isFinite else { return }
            sequence += 1
            accepted += 1
            frame = (pixel, CaptureStamp(sequence: sequence, uptime: now,
                presentationSeconds: presentationSeconds, width: CVPixelBufferGetWidth(pixel),
                height: CVPixelBufferGetHeight(pixel), videoOrientation: orientation), Date())
        }
    }
    // Reasons are fixed local labels, never raw attachments or image contents.
    func recordSample(epoch expected: UUID, rejection: String? = nil, orientation: String? = nil) {
        lock.withLock {
            guard epoch == expected else { return }
            samples += 1
            if let rejection { rejected[rejection, default: 0] += 1 }
            if let orientation { orientationMetadata = orientation }
        }
    }
    func diagnostics(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CaptureDiagnostics {
        lock.withLock { CaptureDiagnostics(active: accepting, received: samples, accepted: accepted,
            sequence: frame?.1.sequence, age: frame.map { max(0, now - $0.1.uptime) }, rejected: rejected,
            orientationMetadata: orientationMetadata) }
    }
    /// Capture authorization exists before the first frame. Input callers retain
    /// the stricter sessionID/requireSession checks below.
    func captureSessionID() throws -> UUID {
        try lock.withLock { guard accepting else { throw AppError.stopped }; return epoch }
    }
    func requireCaptureSession(_ expected: UUID) throws {
        try lock.withLock { guard accepting, epoch == expected else { throw AppError.stopped } }
    }
    func waitForFrame(epoch expected: UUID, timeout: TimeInterval = 5,
                      notBefore: TimeInterval = 0, check: @Sendable () throws -> Void = {}) async throws -> FrameImage {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try Task.checkCancellation(); try check(); try requireCaptureSession(expected)
            if let stamp = try? latestStamp(), stamp.uptime > notBefore {
                let result = try encoded(notBefore: notBefore)
                try requireCaptureSession(expected); try Task.checkCancellation(); try check()
                return result
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw AppError.unavailable(String(localized: "Timed out waiting for a valid captured image. \(diagnostics().summary). Copy the diagnostic log to check reception."))
    }
    func latestStamp() throws -> CaptureStamp {
        try lock.withLock {
            guard accepting, let stamp = frame?.1 else {
                throw AppError.unavailable(String(localized: "Screen capture stopped or has not provided an image. Input is disabled."))
            }
            return stamp
        }
    }
    func sessionID() throws -> UUID {
        try lock.withLock {
            guard accepting, frame != nil else { throw AppError.stopped }
            return epoch
        }
    }
    func requireSession(_ expected: UUID) throws {
        try withSession(expected) {}
    }
    func withSession(_ expected: UUID, _ action: () -> Void) throws {
        try lock.withLock {
            guard accepting, epoch == expected, frame != nil else { throw AppError.stopped }
            action()
        }
    }
    func encoded(after sequence: UInt64 = 0, notBefore uptime: TimeInterval = 0,
                 maxDimension: Int = 1280) throws -> FrameImage {
        let snapshot = try lock.withLock { () throws -> (CVPixelBuffer, CaptureStamp, Date, UUID) in
            guard accepting, let (pixel, stamp, date) = frame,
                  stamp.sequence > sequence, stamp.uptime > uptime else { throw AppError.unavailable(String(localized: "Waiting for a new image after the action")) }
            return (pixel, stamp, date, epoch)
        }
        let (pixel, stamp, date, capturedEpoch) = snapshot
        var image = CIImage(cvPixelBuffer: pixel).oriented(forExifOrientation: Int32(stamp.videoOrientation))
        let scale = min(1, CGFloat(max(1, maxDimension)) / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(image, from: image.extent.integral) else {
            throw AppError.unavailable(String(localized: "Could not encode the captured image"))
        }
        let data = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw AppError.unavailable(String(localized: "PNG encoding unavailable")) }
        CGImageDestinationAddImage(png, cgImage, nil)
        guard CGImageDestinationFinalize(png) else { throw AppError.unavailable(String(localized: "PNG encoding failed")) }
        try lock.withLock {
            guard accepting, epoch == capturedEpoch else { throw AppError.stopped }
        }
        return FrameImage(id: "sck-\(capturedEpoch.uuidString)-\(stamp.sequence)", png: data as Data,
                          width: cgImage.width, height: cgImage.height, capturedAt: date, isDemo: false, capture: stamp)
    }
}
