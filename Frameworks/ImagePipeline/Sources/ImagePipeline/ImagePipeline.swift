import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes image data into display-ready `CGImage`s.
///
/// All entry points are synchronous and CPU-bound — callers are expected to
/// dispatch them off the main thread (the reader layer above does this).
public enum ImagePipeline {
    /// Hard cap on the decoded largest side, applied by
    /// `maxPixelSize(forDisplaySize:targetWidth:)`.
    public static let maxDecodedPixelSize = 12288

    /// Largest-side decode budget that lands the decoded image
    /// `targetWidth` pixels wide for any aspect ratio. Shared by the reader
    /// and the preheat scheduler, so preheated payloads have exactly the
    /// dimensions the reader would have produced itself.
    public static func maxPixelSize(forDisplaySize size: CGSize, targetWidth: Int) -> Int {
        guard size.width > 0, size.height > 0 else { return targetWidth }
        let budget = (Double(targetWidth) * Double(size.height) / Double(size.width)).rounded(.up)
        return min(max(Int(budget), targetWidth), maxDecodedPixelSize)
    }

    /// Decodes `data` into a `CGImage` whose largest side is at most
    /// `maxPixelSize` pixels.
    ///
    /// The payload is always re-decoded from the full image
    /// (`kCGImageSourceCreateThumbnailFromImageAlways`) so a low-quality
    /// embedded thumbnail can never leak through, downsampled during decode
    /// rather than after, and rotated/mirrored according to its EXIF
    /// orientation (`kCGImageSourceCreateThumbnailWithTransform`). Never
    /// upscales: images smaller than `maxPixelSize` come back at native size.
    ///
    /// - Returns: `nil` when `data` is not a decodable image or
    ///   `maxPixelSize` is not positive.
    public static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [
            // No image-level caching: CacheKit owns caching, and the decode
            // result is returned immediately anyway.
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Force the decode to happen here, on the caller's (background)
            // thread, instead of lazily on whichever thread renders first.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// Reports the pixel dimensions of the image in `data` as they will
    /// appear after `decode` applies the EXIF orientation — i.e. width and
    /// height are swapped for orientations 5–8. Use this for layout so
    /// placeholder aspect ratios match the decoded image exactly.
    ///
    /// - Returns: `nil` when `data` is not a readable image or the header
    ///   lacks dimension information.
    public static func displayDimensions(of data: Data) -> CGSize? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // Orientations 5–8 transpose the image (90°/270° rotations).
        if (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    /// Crops the largest centered square out of `image`. Already-square
    /// images come back unchanged. Used by the browser thumbnail pipeline,
    /// which stores square center-crop variants so the row view can fill its
    /// badge without its own cropping logic.
    ///
    /// - Returns: `nil` when the crop fails (degenerate image).
    public static func cropCenterSquare(_ image: CGImage) -> CGImage? {
        let side = min(image.width, image.height)
        guard side > 0 else { return nil }
        if side == image.width, side == image.height { return image }
        let rect = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        return image.cropping(to: rect)
    }

    /// Re-encodes an image as JPEG data. Used to persist downsampled display
    /// variants in CacheKit's display pool, so a cache hit decodes a small
    /// payload instead of the full original.
    ///
    /// `quality` is clamped to `0...1`.
    ///
    /// - Returns: `nil` when the image cannot be encoded.
    public static func encodeJPEG(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1),
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
