// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let archive = ProcessInfo.processInfo.environment["COREDEVICE_BACKEND_ARCHIVE_DIR"] ?? root.appendingPathComponent(".build/coredevice-rust/aarch64-apple-darwin/release").path
let fixtures = ProcessInfo.processInfo.environment["COREDEVICE_OFFLINE_FIXTURES"] == "1"
let package = Package(name: "CoreDeviceBackend", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "CoreDeviceBackend", targets: ["CoreDeviceBackend"])],
    targets: [
        .target(name: "CCoreDeviceBackend", publicHeadersPath: "include", cSettings: fixtures ? [.define("COREDEVICE_OFFLINE_FIXTURES")] : [], linkerSettings: [.unsafeFlags(["-L", archive]), .linkedLibrary("coredevice_backend"), .linkedFramework("Security"), .linkedFramework("SystemConfiguration")]),
        .target(name: "CoreDeviceBackend", dependencies: ["CCoreDeviceBackend"], swiftSettings: fixtures ? [.define("COREDEVICE_OFFLINE_FIXTURES"), .unsafeFlags(["-Xcc", "-DCOREDEVICE_OFFLINE_FIXTURES"])] : []),
        .testTarget(name: "CoreDeviceBackendTests", dependencies: ["CoreDeviceBackend", "CCoreDeviceBackend"], swiftSettings: fixtures ? [.define("COREDEVICE_OFFLINE_FIXTURES"), .unsafeFlags(["-Xcc", "-DCOREDEVICE_OFFLINE_FIXTURES"])] : [])])
