// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CommandKit",
    platforms: [.iOS(.v15)],
    products: [.library(name: "CommandKit", targets: ["CommandKit"])],
    targets: [
        .binaryTarget(name: "ios_system", url: "https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_system.xcframework.zip", checksum: "c9c6dc4cde45cc271ccc8bd0553ce4d3149eced1f0ee3d9e0ce01885d93526e6"),
        .binaryTarget(name: "files", url: "https://github.com/holzschu/ios_system/releases/download/v3.0.6/files.xcframework.zip", checksum: "5db63958f686cc79f107bafd0d50feff32fb2b64d0dd976478c5dd405f7600b0"),
        .binaryTarget(name: "text", url: "https://github.com/holzschu/ios_system/releases/download/v3.0.6/text.xcframework.zip", checksum: "9eef16c23ddaa03d5f28ce2183737b1dbdcfb06e6dc46035a404d9e0f3828604"),
        .binaryTarget(name: "shell", url: "https://github.com/holzschu/ios_system/releases/download/v3.0.6/shell.xcframework.zip", checksum: "89da3b8bd7f83e42a2311aeac54c38acc7a2f9c2fc0d0d27f75897b393cdfec2"),
        .target(name: "CCommandBridge", dependencies: ["ios_system", "files", "text", "shell"], publicHeadersPath: "include"),
        .target(name: "CommandKit", dependencies: ["CCommandBridge"]),
        .testTarget(name: "CommandKitTests", dependencies: ["CommandKit"])
    ]
)
