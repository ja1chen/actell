import Foundation
import UIKit

actor DemoBridge: DeviceBridge {
    private var count = 0
    private var stopped = false
    private var currentID: String?
    func approvalContext(imageID: String) throws -> String {
        guard !stopped, currentID == imageID else { throw AppError.stopped }
        return "synthetic-demo"
    }
    func authorizeTaskInput(imageID: String) throws {
        _ = try approvalContext(imageID: imageID)
    }
    func screenshot() async throws -> FrameImage {
        try Task.checkCancellation(); guard !stopped else { throw AppError.stopped }
        let value = count
        let png = await MainActor.run { () -> Data in
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844), format: format)
            return renderer.pngData { context in
                UIColor(red: 0.04, green: 0.09, blue: 0.14, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
                let white: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: UIColor.white]
                let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.lightGray]
                ("OFFLINE DEMO" as NSString).draw(at: CGPoint(x: 30, y: 80), withAttributes: white)
                ("Synthetic screen · no device control" as NSString).draw(at: CGPoint(x: 30, y: 130), withAttributes: small)
                UIColor.systemTeal.setFill(); UIBezierPath(roundedRect: CGRect(x: 45, y: 330, width: 300, height: 100), cornerRadius: 22).fill()
                ("Demo taps: \(value)" as NSString).draw(at: CGPoint(x: 75, y: 365), withAttributes: white)
                ("Nothing leaves this device in demo mode" as NSString).draw(in: CGRect(x: 30, y: 680, width: 330, height: 80), withAttributes: small)
            }
        }
        try Task.checkCancellation(); guard !stopped else { throw AppError.stopped }
        let id = UUID().uuidString; currentID = id
        return FrameImage(id: id, png: png, width: 390, height: 844, capturedAt: Date(), isDemo: true)
    }
    func tap(x: Int, y: Int, imageID: String) async throws {
        try Task.checkCancellation()
        guard !stopped, currentID == imageID else { throw AppError.stopped }
        count += 1; currentID = nil
    }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {
        try Task.checkCancellation()
        guard !stopped, currentID == imageID else { throw AppError.stopped }
        currentID = nil
    }
    func stop() async { stopped = true; currentID = nil }
}
