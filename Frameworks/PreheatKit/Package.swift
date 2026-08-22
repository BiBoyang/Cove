// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreheatKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PreheatKit", targets: ["PreheatKit"]),
    ],
    dependencies: [
        .package(path: "../SourceKit"),
        .package(path: "../CacheKit"),
        .package(path: "../ImagePipeline"),
        .package(path: "../TraceKit"),
    ],
    targets: [
        // Schedules "fetch ahead into the disk cache" work. ImagePipeline is
        // needed for the downsample+JPEG-encode half of every job.
        .target(
            name: "PreheatKit",
            dependencies: [
                .product(name: "SourceKit", package: "SourceKit"),
                .product(name: "CacheKit", package: "CacheKit"),
                .product(name: "ImagePipeline", package: "ImagePipeline"),
                .product(name: "TraceKit", package: "TraceKit"),
            ]
        ),
        .testTarget(
            name: "PreheatKitTests",
            dependencies: [
                "PreheatKit",
                .product(name: "SourceKit", package: "SourceKit"),
                .product(name: "CacheKit", package: "CacheKit"),
            ]
        ),
    ]
)
