import CoreGraphics
import Foundation
import ImageIO
import SourceKit
import UniformTypeIdentifiers
import XCTest

/// In-memory `ContentSource`: serves fixed payloads, records read order,
/// optionally delays each read so timing-sensitive tests stay deterministic.
actor MockSource: ContentSource {
    let sourceID = "mock://preheat"

    private var files: [String: Data]
    private var listings: [String: [ContentItem]]
    private let readDelayNanoseconds: UInt64
    private(set) var readPaths: [String] = []

    init(
        files: [String: Data] = [:],
        listings: [String: [ContentItem]] = [:],
        readDelayNanoseconds: UInt64 = 0
    ) {
        self.files = files
        self.listings = listings
        self.readDelayNanoseconds = readDelayNanoseconds
    }

    var readCount: Int { readPaths.count }

    func connect() async throws {}
    func disconnect() async {}

    func list(at path: String) async throws -> [ContentItem] {
        guard let entries = listings[path] else { throw SourceError.pathNotFound(path) }
        return entries
    }

    func metadata(at path: String) async throws -> ContentItem {
        guard let data = files[path] else { throw SourceError.pathNotFound(path) }
        return ContentItem(
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: false,
            size: Int64(data.count),
            modifiedDate: nil
        )
    }

    func read(at path: String, range: Range<Int64>) async throws -> Data {
        if readDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: readDelayNanoseconds)
        }
        guard let data = files[path] else { throw SourceError.pathNotFound(path) }
        readPaths.append(path)
        return data
    }
}

/// Renders a solid-color PNG of the given pixel size — the same factory
/// style as ImagePipelineTests.
func makePNG(width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
    let ctx = try XCTUnwrap(context, file: file, line: line)
    ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    let image = try XCTUnwrap(ctx.makeImage(), file: file, line: line)
    let buffer = NSMutableData()
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil),
        file: file,
        line: line
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination), file: file, line: line)
    return buffer as Data
}
