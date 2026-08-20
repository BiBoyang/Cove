// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeychainKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KeychainKit", targets: ["KeychainKit"]),
    ],
    targets: [
        .target(name: "KeychainKit"),
        .testTarget(name: "KeychainKitTests", dependencies: ["KeychainKit"]),
    ]
)
