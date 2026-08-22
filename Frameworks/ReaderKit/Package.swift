// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReaderKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReaderKit", targets: ["ReaderKit"]),
    ],
    targets: [
        .target(name: "ReaderKit"),
        .testTarget(name: "ReaderKitTests", dependencies: ["ReaderKit"]),
    ]
)
