// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComicKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ComicKit", targets: ["ComicKit"]),
    ],
    dependencies: [
        .package(path: "../SourceKit"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.20"),
    ],
    targets: [
        // The ONLY target in the repo allowed to import ZIPFoundation.
        .target(
            name: "ComicKit",
            dependencies: [
                .product(name: "SourceKit", package: "SourceKit"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "ComicKitTests",
            dependencies: [
                "ComicKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
