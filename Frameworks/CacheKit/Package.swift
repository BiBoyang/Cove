// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CacheKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CacheKit", targets: ["CacheKit"]),
    ],
    dependencies: [
        .package(path: "../TraceKit"),
    ],
    targets: [
        .target(
            name: "CacheKit",
            dependencies: [.product(name: "TraceKit", package: "TraceKit")]
        ),
        .testTarget(name: "CacheKitTests", dependencies: ["CacheKit"]),
    ]
)
