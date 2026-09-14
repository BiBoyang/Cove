import CacheKit
import CoreGraphics
import Foundation
import ImagePipeline
import SourceKit
import TraceKit

// MARK: - Capture payload

/// One raw frame as returned by mpv's `screenshot-raw` command: tightly
/// defined BGRA rows (stride bytes apart) of a `width × height` image.
/// Pure values, no platform types (AGENTS.md rule 16) — the player core
/// copies the bytes out of the mpv reply node before they expire.
struct BGRAVideoFrame: Equatable, Sendable {
    /// BGRA pixel rows, `stride * height` bytes at minimum.
    let data: Data
    let width: Int
    let height: Int
    /// Bytes per row; at least `width * 4`, possibly padded.
    let stride: Int
}

// MARK: - Shared key contract

/// The single formula both sides of the video-thumbnail pipeline use, so a
/// frame stored by the player and a card lookup computed from the resume
/// record can never disagree (TASK-video-thumbnails decision: write path =
/// capture during playback, read path = display-pool lookup only).
enum VideoThumbnailStore {
    /// Display-pool variant: a square center-crop at 320 px (the home card's
    /// cover plus headroom for a future browser-row downsample). Deliberately
    /// unlike `thumb160` so image and video pipelines never share entries.
    static let variant = "vthumb320"
    /// Largest pixel side of a stored thumbnail.
    static let pixelSize = 320
    /// JPEG quality for the display-pool payload; matches the image pipeline.
    static let jpegQuality = 0.85

    /// Cache key pinning the exact watched file version. Nil when the file
    /// facts are unknown — the caller then degrades to the icon instead of
    /// guessing at a key that can never hit.
    static func cacheKey(
        sourceID: String, path: String, fileSize: Int64?, modified: Date?
    ) -> CacheKey? {
        guard let fileSize, let modified else { return nil }
        return CacheKey.sourceFile(
            sourceID: sourceID, path: path, fileSize: fileSize,
            modified: modified, variant: variant
        )
    }

    /// Packs raw BGRA rows into a `CGImage` using CoreGraphics only (no new
    /// framework, no encoder — the FFmpeg forest ships none). Nil on a
    /// degenerate frame whose buffers cannot describe `width × height`
    /// pixels (TASK-video-thumbnails Step 5: synthetic-buffer tested).
    static func cgImage(from frame: BGRAVideoFrame) -> CGImage? {
        guard frame.width > 0, frame.height > 0,
              frame.stride >= frame.width * 4,
              frame.data.count >= frame.stride * frame.height
        else { return nil }
        guard let context = CGContext(
            data: nil,
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bytesPerRow: frame.stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // little-endian 32-bit + premultiplied-first is exactly BGRA, so a
        // plain byte copy lands the channels where CG expects them. Rows go
        // across one at a time against the context's own bytesPerRow:
        // CGContext may pad the requested stride up for alignment, and a
        // flat copy sized by the frame's stride would skew every row after
        // the first (mpv strides need not match CG's alignment). Padding
        // bytes are never read, so garbage there is harmless.
        guard let target = context.data else { return nil }
        let contextStride = context.bytesPerRow
        frame.data.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return }
            if contextStride == frame.stride {
                _ = memcpy(target, source, frame.stride * frame.height)
                return
            }
            let destination = target.assumingMemoryBound(to: UInt8.self)
            let sourceBytes = source.assumingMemoryBound(to: UInt8.self)
            for row in 0..<frame.height {
                _ = memcpy(
                    destination + row * contextStride,
                    sourceBytes + row * frame.stride,
                    frame.width * 4
                )
            }
        }
        return context.makeImage()
    }

    /// Reduces a captured frame to the stored payload: square center-crop
    /// (ImagePipeline), downscale to at most `pixelSize`, JPEG-encode.
    /// Nil when any step refuses the image.
    static func thumbnailPayload(from image: CGImage) -> Data? {
        guard let square = ImagePipeline.cropCenterSquare(image) else { return nil }
        let final: CGImage
        if square.width > pixelSize {
            final = downscale(square, to: pixelSize) ?? square
        } else {
            final = square
        }
        return ImagePipeline.encodeJPEG(final, quality: jpegQuality)
    }

    /// Straight CG draw into a `pixelSize` square (CoreGraphics only).
    private static func downscale(_ image: CGImage, to side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}

// MARK: - Write side (player capture → display pool)

/// Persists captured frames as `vthumb320` JPEGs in CacheKit's display pool.
/// Video bytes never enter any pool (LibraryCoordinator's red line) — only
/// this produced JPEG does, exactly like the browser image thumbnails.
///
/// The heavy steps (byte pack, crop, downscale, encode, disk write) all run
/// on a detached utility task so the MainActor-bound player core only pays
/// for handing over the already-copied frame.
struct VideoThumbnailWriter: Sendable {
    private let cache: CacheStore
    private let logger = TraceLogger(category: "VideoThumbnail")

    init(cache: CacheStore) {
        self.cache = cache
    }

    /// Stores one frame; a missing key (unknown file facts) or any failure
    /// is logged and dropped — a missing cover degrades to the film icon,
    /// never an error surface.
    func store(
        frame: BGRAVideoFrame, sourceID: String, path: String,
        fileSize: Int64, modified: Date?
    ) {
        guard let key = VideoThumbnailStore.cacheKey(
            sourceID: sourceID, path: path, fileSize: fileSize, modified: modified
        ) else { return }
        let cache = cache
        let logger = logger
        Task.detached(priority: .utility) {
            guard let image = VideoThumbnailStore.cgImage(from: frame),
                  let payload = VideoThumbnailStore.thumbnailPayload(from: image)
            else {
                logger.error("video thumbnail encode failed")
                return
            }
            do {
                try cache.store(payload, forKey: key, pool: .display)
            } catch {
                logger.error("video thumbnail store failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Read side (home cards ← display pool)

/// Read-only thumbnail lookup for the home page's continue-watching cards.
/// Protocol mirrors `ThumbnailProviding` so the view drives loads the same
/// way the browser rows do (rule 12's cell-reuse exception).
protocol RecentWatchThumbnailProviding: Sendable {
    /// The stored cover for `entry`, or nil — a nil never generates work:
    /// no pool miss is served from the network or the player (route C:
    /// covers only exist for videos the player captured while watching).
    func thumbnail(for entry: RecentWatchEntry) async -> CGImage?
}

/// Looks covers up in the display pool. For legacy records written before
/// the store kept file facts, an injected `stat` may supply them — bounded
/// by the grid's card count and by what it can reach without opening any
/// new connection (vault = local stat; SMB = the live session's share only).
actor RecentWatchThumbnailReader: RecentWatchThumbnailProviding {
    private let cache: CacheStore
    /// Best-effort facts for a record missing them; nil = unknown, keep
    /// the icon.
    private let stat: @Sendable (RecentWatchEntry) async -> ContentItem?

    init(
        cache: CacheStore,
        stat: @escaping @Sendable (RecentWatchEntry) async -> ContentItem? = { _ in nil }
    ) {
        self.cache = cache
        self.stat = stat
    }

    func thumbnail(for entry: RecentWatchEntry) async -> CGImage? {
        var size = entry.fileSize
        var modified = entry.modifiedDate
        if size == nil || modified == nil, let item = await stat(entry) {
            if size == nil { size = item.size }
            if modified == nil { modified = item.modifiedDate }
        }
        guard let size, let modified,
              let key = VideoThumbnailStore.cacheKey(
                  sourceID: entry.sourceID, path: entry.path,
                  fileSize: size, modified: modified
              ),
              let payload = try? cache.data(forKey: key, pool: .display)
        else { return nil }
        return ImagePipeline.decode(payload, maxPixelSize: VideoThumbnailStore.pixelSize)
    }
}
