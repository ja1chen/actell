// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ProviderKit", platforms: [.macOS(.v13), .iOS(.v16)], products: [
    .library(name: "ProviderCore", targets: ["ProviderCore"]),
    .library(name: "OpenAIAdapter", targets: ["OpenAIAdapter"])
], dependencies: [.package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.5.2")], targets: [
    .target(name: "ProviderCore"),
    .target(name: "OpenAIAdapter", dependencies: ["ProviderCore", .product(name: "OpenAI", package: "OpenAI")]),
    .testTarget(name: "ProviderKitTests", dependencies: ["ProviderCore", "OpenAIAdapter"])
])
