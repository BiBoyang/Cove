import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImagePipeline

private extension Int {
    /// Little-endian 4-byte field, as BMP headers store them.
    var littleEndianBytes: [UInt8] {
        let value = UInt32(bitPattern: Int32(self))
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}

final class ImagePipelineTests: XCTestCase {
    // MARK: - Test image factory

    /// Renders a solid two-tone RGB image of the given pixel size.
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        let ctx = try XCTUnwrap(context)
        ctx.setFillColor(red: 0.1, green: 0.3, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Encodes an image as PNG/JPEG, optionally tagging an EXIF orientation.
    private func encode(_ image: CGImage, type: UTType, orientation: Int? = nil) throws -> Data {
        let buffer = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil)
        )
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    // MARK: - decode

    func testDecodeDownsamplesToMaxPixelSize() throws {
        let png = try encode(makeImage(width: 2000, height: 3000), type: .png)
        let thumb = try XCTUnwrap(ImagePipeline.decode(png, maxPixelSize: 1000))
        XCTAssertEqual(max(thumb.width, thumb.height), 1000)
        // 2:3 aspect ratio preserved within rounding.
        XCTAssertEqual(Double(thumb.width) / Double(thumb.height), 2.0 / 3.0, accuracy: 0.01)
    }

    func testDecodeDownsamplesJPEG() throws {
        let jpeg = try encode(makeImage(width: 2000, height: 3000), type: .jpeg)
        let thumb = try XCTUnwrap(ImagePipeline.decode(jpeg, maxPixelSize: 500))
        XCTAssertEqual(max(thumb.width, thumb.height), 500)
        XCTAssertEqual(Double(thumb.width) / Double(thumb.height), 2.0 / 3.0, accuracy: 0.01)
    }

    func testDecodeNeverUpscales() throws {
        let png = try encode(makeImage(width: 120, height: 80), type: .png)
        let thumb = try XCTUnwrap(ImagePipeline.decode(png, maxPixelSize: 1000))
        XCTAssertEqual(thumb.width, 120)
        XCTAssertEqual(thumb.height, 80)
    }

    func testDecodeRejectsUndecodableData() {
        XCTAssertNil(ImagePipeline.decode(Data("not an image".utf8), maxPixelSize: 100))
        XCTAssertNil(ImagePipeline.decode(Data(), maxPixelSize: 100))
        XCTAssertNil(ImagePipeline.decode(Data((0..<255).map { UInt8($0) }), maxPixelSize: 100))
    }

    func testDecodeRejectsNonPositiveMaxPixelSize() throws {
        let png = try encode(makeImage(width: 10, height: 10), type: .png)
        XCTAssertNil(ImagePipeline.decode(png, maxPixelSize: 0))
        XCTAssertNil(ImagePipeline.decode(png, maxPixelSize: -1))
    }

    func testDecodeAppliesEXIFOrientation() throws {
        // Stored landscape 3000x2000, EXIF orientation 6: displayed portrait.
        let jpeg = try encode(makeImage(width: 3000, height: 2000), type: .jpeg, orientation: 6)
        let decoded = try XCTUnwrap(ImagePipeline.decode(jpeg, maxPixelSize: 4096))
        XCTAssertEqual(decoded.width, 2000)
        XCTAssertEqual(decoded.height, 3000)
    }

    func testDecodeAppliesEXIFOrientationWhileDownsampling() throws {
        let jpeg = try encode(makeImage(width: 3000, height: 2000), type: .jpeg, orientation: 6)
        let decoded = try XCTUnwrap(ImagePipeline.decode(jpeg, maxPixelSize: 1000))
        XCTAssertEqual(max(decoded.width, decoded.height), 1000)
        XCTAssertLessThan(decoded.width, decoded.height)
    }

    // MARK: - displayDimensions

    func testDisplayDimensionsMatchesDecodeOutput() throws {
        // Stored landscape, EXIF orientation 6: displayed portrait. The
        // display probe must agree with what decode() produces so layout
        // aspect ratios never need correction after decode.
        let jpeg = try encode(makeImage(width: 3000, height: 2000), type: .jpeg, orientation: 6)
        let probed = try XCTUnwrap(ImagePipeline.displayDimensions(of: jpeg))
        XCTAssertEqual(probed, CGSize(width: 2000, height: 3000))
    }

    func testDisplayDimensionsUntaggedImageKeepsStoredSize() throws {
        let png = try encode(makeImage(width: 2000, height: 3000), type: .png)
        let probed = try XCTUnwrap(ImagePipeline.displayDimensions(of: png))
        XCTAssertEqual(probed, CGSize(width: 2000, height: 3000))
    }

    func testDisplayDimensionsRejectsUndecodableData() {
        XCTAssertNil(ImagePipeline.displayDimensions(of: Data("junk".utf8)))
        XCTAssertNil(ImagePipeline.displayDimensions(of: Data()))
    }

    // MARK: - Source-pixel gate

    /// Builds a minimal BMP whose header declares `width` x `height` with
    /// almost no pixel data behind it. ImageIO's BMP plugin answers
    /// property queries from the header alone (unlike PNG, which inflates
    /// IDAT first) — which is exactly the path the source-pixel gate reads,
    /// so a bomb-sized fixture costs a few dozen bytes.
    private func makeHeaderOnlyBMP(width: Int, height: Int) -> Data {
        var bmp = Data([0x42, 0x4D]) // "BM"
        bmp.append(contentsOf: (54 + 16).littleEndianBytes) // file size
        bmp.append(contentsOf: [0, 0, 0, 0]) // reserved
        bmp.append(contentsOf: 54.littleEndianBytes) // pixel data offset
        bmp.append(contentsOf: 40.littleEndianBytes) // BITMAPINFOHEADER size
        bmp.append(contentsOf: width.littleEndianBytes)
        bmp.append(contentsOf: height.littleEndianBytes)
        bmp.append(contentsOf: [1, 0]) // planes
        bmp.append(contentsOf: [24, 0]) // bits per pixel
        bmp.append(contentsOf: [UInt8](repeating: 0, count: 24)) // rest of header
        bmp.append(contentsOf: [UInt8](repeating: 0, count: 16)) // token pixels
        return bmp
    }

    func testHeaderOnlyBMPFixtureExposesDeclaredDimensions() {
        // Pins the fixture: the dimensions must be readable without a
        // decodable payload, or the rejection tests below prove nothing.
        let bmp = makeHeaderOnlyBMP(width: 40000, height: 30000)
        XCTAssertEqual(ImagePipeline.displayDimensions(of: bmp), CGSize(width: 40000, height: 30000))
    }

    func testDecodeRejectsSourceAbovePixelCap() {
        // 40000 x 30000 = 1.2 Gpx, far above the 256 Mpx cap.
        let bmp = makeHeaderOnlyBMP(width: 40000, height: 30000)
        XCTAssertNil(ImagePipeline.decode(bmp, maxPixelSize: 1000))
    }

    func testDecodeRejectsBombJustAbovePixelCap() {
        // 30000 x 30000 = 900 Mpx > 256 Mpx: the task-card example.
        let bmp = makeHeaderOnlyBMP(width: 30000, height: 30000)
        XCTAssertNil(ImagePipeline.decode(bmp, maxPixelSize: 1000))
    }

    // MARK: - maxPixelSize guards

    func testMaxPixelSizeClampsNonPositiveTargetWidth() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertGreaterThanOrEqual(ImagePipeline.maxPixelSize(forDisplaySize: size, targetWidth: 0), 1)
        XCTAssertGreaterThanOrEqual(ImagePipeline.maxPixelSize(forDisplaySize: size, targetWidth: -1), 1)
        XCTAssertGreaterThanOrEqual(ImagePipeline.maxPixelSize(forDisplaySize: .zero, targetWidth: 0), 1)
    }

    // MARK: - cropCenterSquare

    func testCropCenterSquareLandscape() throws {
        let cropped = try XCTUnwrap(ImagePipeline.cropCenterSquare(makeImage(width: 200, height: 100)))
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 100)
    }

    func testCropCenterSquarePortrait() throws {
        let cropped = try XCTUnwrap(ImagePipeline.cropCenterSquare(makeImage(width: 100, height: 200)))
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 100)
    }

    func testCropCenterSquareKeepsSquareImage() throws {
        let image = try makeImage(width: 64, height: 64)
        let cropped = try XCTUnwrap(ImagePipeline.cropCenterSquare(image))
        XCTAssertEqual(cropped.width, 64)
        XCTAssertEqual(cropped.height, 64)
    }

    // MARK: - encodeJPEG

    func testEncodeJPEGRoundTrips() throws {
        let image = try makeImage(width: 640, height: 480)
        let data = try XCTUnwrap(ImagePipeline.encodeJPEG(image, quality: 0.85))
        // The payload must be a decodable JPEG at the same pixel size.
        let decoded = try XCTUnwrap(ImagePipeline.decode(data, maxPixelSize: 4096))
        XCTAssertEqual(decoded.width, 640)
        XCTAssertEqual(decoded.height, 480)
        // JPEG magic bytes.
        XCTAssertEqual([data[0], data[1]], [0xFF, 0xD8])
    }

    func testEncodeJPEGClampsQuality() throws {
        let image = try makeImage(width: 64, height: 64)
        XCTAssertNotNil(ImagePipeline.encodeJPEG(image, quality: -1))
        XCTAssertNotNil(ImagePipeline.encodeJPEG(image, quality: 2))
    }
}
