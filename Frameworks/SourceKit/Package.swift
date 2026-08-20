// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SourceKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SourceKit", targets: ["SourceKit"]),
        .executable(name: "smb-spike", targets: ["smb-spike"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amosavian/AMSMB2", from: "4.0.3"),
    ],
    targets: [
        // The ONLY target in the repo allowed to import AMSMB2.
        .target(
            name: "SourceKit",
            dependencies: [.product(name: "AMSMB2", package: "AMSMB2")]
        ),
        .executableTarget(
            name: "smb-spike",
            dependencies: ["SourceKit"]
        ),
        .testTarget(
            name: "SourceKitTests",
            dependencies: ["SourceKit"]
        ),
    ]
)
