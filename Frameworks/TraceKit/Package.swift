// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TraceKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TraceKit", targets: ["TraceKit"]),
    ],
    targets: [
        .target(name: "TraceKit"),
        .testTarget(name: "TraceKitTests", dependencies: ["TraceKit"]),
    ]
)
