// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The app-service launch receipt, not confirmation of visible foreground UI.
/// Private executable paths and audit tokens stay inside the native backend.
public struct NativeApplicationLaunch: Codable, Equatable, Sendable {
    public let bundleID: String
    public let pid: Int32

    public init(bundleID: String, pid: Int32) {
        self.bundleID = bundleID
        self.pid = pid
    }
    private enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", pid }

    static func decode(_ data: Data, expectedBundleID: String) throws -> Self {
        guard data.count <= 1024, let receipt = try? JSONDecoder().decode(Self.self, from: data),
              receipt.pid > 0, receipt.bundleID == expectedBundleID else { throw NativeBackendError.malformedEvent }
        return receipt
    }
}
