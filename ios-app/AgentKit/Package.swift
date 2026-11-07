// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AgentKit", targets: ["AgentKit"])],
    dependencies: [.package(path: "../ProviderKit")],
    targets: [
        .target(name: "AgentKit", dependencies: [.product(name: "ProviderCore", package: "ProviderKit")]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit", .product(name: "ProviderCore", package: "ProviderKit")])
    ]
)
