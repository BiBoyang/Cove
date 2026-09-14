import AppKit
import CacheKit
import CoreGraphics
import Foundation
import ImagePipeline
import SourceKit
import Testing
@testable import Cove

/// TASK-video-thumbnails: the video-cover pipeline's pure seams — BGRA→CGImage
/// packing, thumbnail payload shape, the shared key contract, the writer→reader
/// round-trip over a real CacheStore, and the home card's icon fallback.
@Suite("Video thumbnails")
struct VideoThumbnailTests {
    // MARK: - BGRA → CGImage

    /// Builds a `width × height` BGRA buffer whose pixel (x, y) is
    /// (r, g, b) = (x * 10, y * 10, 128), alpha 255 — every pixel distinct.
    /// Row padding (when `stride` exceeds `width * 4`) keeps `paddingFill`,
    /// so tests can prove padding bytes never leak into the image.
    private func syntheticFrame(
        width: Int, height: Int, stride: Int? = nil, paddingFill: UInt8 = 0
    ) -> BGRAVideoFrame {
        let rowBytes = stride ?? width * 4
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            base.initialize(repeating: paddingFill, count: rowBytes * height)
            for y in 0..<height {
                let row = base + y * rowBytes
                for x in 0..<width {
                    let pixel = row + x * 4
                    pixel[0] = UInt8(clamping: 255)          // B
                    pixel[1] = UInt8(clamping: y * 10)       // G
                    pixel[2] = UInt8(clamping: x * 10)       // R
                    pixel[3] = 255                            // A
                }
            }
        }
        return BGRAVideoFrame(data: data, width: width, height: height, stride: rowBytes)
    }

    private func pixelBytes(of image: CGImage) -> [UInt8] {
        let cfData = image.dataProvider!.data!
        let pointer = CFDataGetBytePtr(cfData)!
        return Array(UnsafeBufferPointer(start: pointer, count: CFDataGetLength(cfData)))
    }

    @Test("BGRA rows pack into a CGImage byte-for-byte, channels intact")
    func bgraPacking() throws {
        // 4 wide × 2 tall with a padded stride (6 pixels worth of bytes per
        // row) — proves stride math, not just the tight case.
        let frame = syntheticFrame(width: 4, height: 2, stride: 24)
        let image = try #require(VideoThumbnailStore.cgImage(from: frame))

        #expect(image.width == 4)
        #expect(image.height == 2)
        #expect(image.bytesPerRow == 24)
        let bytes = pixelBytes(of: image)
        // Row 0 (offset 0): pixel (0,0) = B255 G0 R0; pixel (3,0) = R30.
        #expect(Array(bytes[0..<4]) == [255, 0, 0, 255])
        #expect(Array(bytes[12..<16]) == [255, 0, 30, 255])
        // Row 1 (offset 24, the padded stride): pixel (0,1) = G10;
        // pixel (3,1) = G10 R30.
        #expect(Array(bytes[24..<28]) == [255, 10, 0, 255])
        #expect(Array(bytes[36..<40]) == [255, 10, 30, 255])
    }

    @Test("degenerate frames are refused, not packed")
    func bgraPackingRejectsDegenerate() {
        // Buffer too small for the declared stride × height.
        #expect(VideoThumbnailStore.cgImage(from: syntheticFrame(width: 4, height: 2)) != nil)
        let truncated = BGRAVideoFrame(data: Data(count: 10), width: 4, height: 2, stride: 16)
        #expect(VideoThumbnailStore.cgImage(from: truncated) == nil)
        // Stride narrower than a pixel row.
        let narrow = BGRAVideoFrame(data: Data(count: 32), width: 4, height: 2, stride: 8)
        #expect(VideoThumbnailStore.cgImage(from: narrow) == nil)
        // Zero-sized image.
        let empty = BGRAVideoFrame(data: Data(), width: 0, height: 0, stride: 0)
        #expect(VideoThumbnailStore.cgImage(from: empty) == nil)
    }

    /// A non-16-byte-aligned stride (Amendment 1 hardening): rows are
    /// copied one at a time against the context's own bytesPerRow, so the
    /// pack survives CG padding the requested stride up, and row padding
    /// is never read. Every pixel distinct, so a single skewed row fails.
    @Test("a non-16-aligned stride packs pixel-perfect, padding unread")
    func nonAlignedStridePacking() throws {
        // 61 px × 4 B = 244 bytes per row — not a 16-byte multiple.
        let tight = try #require(VideoThumbnailStore.cgImage(from: syntheticFrame(width: 61, height: 3)))
        #expect(tight.width == 61)
        #expect(tight.height == 3)
        let tightBytes = pixelBytes(of: tight)
        for y in 0..<3 {
            for x in 0..<61 {
                let offset = y * tight.bytesPerRow + x * 4
                #expect(
                    Array(tightBytes[offset..<offset + 4])
                        == [255, UInt8(clamping: y * 10), UInt8(clamping: x * 10), 255]
                )
            }
        }

        // Padded variant: 8 garbage bytes after each row's real pixels.
        let paddedStride = 61 * 4 + 8
        let padded = try #require(VideoThumbnailStore.cgImage(
            from: syntheticFrame(width: 61, height: 2, stride: paddedStride, paddingFill: 0x7F)
        ))
        let paddedBytes = pixelBytes(of: padded)
        for y in 0..<2 {
            for x in 0..<61 {
                let offset = y * padded.bytesPerRow + x * 4
                #expect(
                    Array(paddedBytes[offset..<offset + 4])
                        == [255, UInt8(clamping: y * 10), UInt8(clamping: x * 10), 255]
                )
            }
        }
    }

    // MARK: - Screenshot-raw reply node parsing

    /// Builds a `screenshot-raw` reply map node from the given entries
    /// (nil = key absent), runs `MPVPlayerCore.bgraFrame(fromScreenshotReply:)`
    /// on it, then frees the synthetic C-side memory — the parser copies
    /// everything it keeps, so a scoped lifetime is enough.
    private func parseReplyNode(
        w: Int64?, h: Int64?, stride: Int64?, format: String?, data: Data?
    ) -> BGRAVideoFrame? {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var heap: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            heap.forEach { free($0) }
        }
        func track(_ pointer: UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar> {
            cStrings.append(pointer)
            return pointer
        }
        var keys: [UnsafeMutablePointer<CChar>?] = []
        var values: [mpv_node] = []
        func add(_ key: String, _ value: mpv_node) {
            keys.append(track(strdup(key)!))
            values.append(value)
        }
        func addInt(_ key: String, _ value: Int64) {
            var node = mpv_node()
            node.format = MPV_FORMAT_INT64
            node.u.int64 = value
            add(key, node)
        }
        func addString(_ key: String, _ value: String) {
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = track(strdup(value)!)
            add(key, node)
        }
        func addData(_ key: String, _ payload: Data) {
            let byteArray = UnsafeMutablePointer<mpv_byte_array>.allocate(capacity: 1)
            heap.append(UnsafeMutableRawPointer(byteArray))
            let buffer = malloc(max(payload.count, 1))!
            heap.append(buffer)
            payload.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: payload.count)
            byteArray.pointee.data = buffer
            byteArray.pointee.size = payload.count
            var node = mpv_node()
            node.format = MPV_FORMAT_BYTE_ARRAY
            node.u.ba = byteArray
            add(key, node)
        }

        if let w { addInt("w", w) }
        if let h { addInt("h", h) }
        if let stride { addInt("stride", stride) }
        if let format { addString("format", format) }
        if let data { addData("data", data) }

        let keyArray = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            .allocate(capacity: max(keys.count, 1))
        let valueArray = UnsafeMutablePointer<mpv_node>.allocate(capacity: max(values.count, 1))
        heap.append(UnsafeMutableRawPointer(keyArray))
        heap.append(UnsafeMutableRawPointer(valueArray))
        for (index, key) in keys.enumerated() { keyArray[index] = key }
        for (index, value) in values.enumerated() { valueArray[index] = value }

        let list = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
        heap.append(UnsafeMutableRawPointer(list))
        list.pointee.num = Int32(values.count)
        list.pointee.keys = keyArray
        list.pointee.values = valueArray

        var node = mpv_node()
        node.format = MPV_FORMAT_NODE_MAP
        node.u.list = list
        return MPVPlayerCore.bgraFrame(fromScreenshotReply: node)
    }

    @Test("a screenshot-raw reply node parses into a copied-out BGRA frame")
    func replyNodeParses() throws {
        let payload = Data((0..<16).map { $0 * 7 })
        let frame = try #require(parseReplyNode(
            w: 2, h: 2, stride: 8, format: "bgra", data: payload
        ))
        #expect(frame.width == 2)
        #expect(frame.height == 2)
        #expect(frame.stride == 8)
        #expect(frame.data == payload)
    }

    @Test("malformed screenshot-raw replies are refused")
    func replyNodeRefusesMalformed() {
        let payload = Data(repeating: 0, count: 16)
        // Wrong pixel format.
        #expect(parseReplyNode(w: 2, h: 2, stride: 8, format: "rgba", data: payload) == nil)
        // Each required key missing.
        #expect(parseReplyNode(w: nil, h: 2, stride: 8, format: "bgra", data: payload) == nil)
        #expect(parseReplyNode(w: 2, h: nil, stride: 8, format: "bgra", data: payload) == nil)
        #expect(parseReplyNode(w: 2, h: 2, stride: nil, format: "bgra", data: payload) == nil)
        #expect(parseReplyNode(w: 2, h: 2, stride: 8, format: "bgra", data: nil) == nil)
        // Buffer shorter than stride × height.
        #expect(parseReplyNode(w: 2, h: 2, stride: 8, format: "bgra", data: Data(repeating: 0, count: 12)) == nil)
        // Degenerate dimensions.
        #expect(parseReplyNode(w: 0, h: 2, stride: 8, format: "bgra", data: payload) == nil)
    }

    // MARK: - Payload shape

    private func solidImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    @Test("payload center-crops to a square and never exceeds the pixel budget")
    func payloadShape() throws {
        // Wide source: crop keeps 60 of 100 → 60×60 (≤320, no upscale).
        let wide = try #require(solidImage(width: 100, height: 60))
        let widePayload = try #require(VideoThumbnailStore.thumbnailPayload(from: wide))
        let wideDecoded = try #require(ImagePipeline.decode(widePayload, maxPixelSize: 320))
        #expect(wideDecoded.width == 60)
        #expect(wideDecoded.height == 60)

        // Large square source: downsampled to exactly 320.
        let large = try #require(solidImage(width: 720, height: 720))
        let largePayload = try #require(VideoThumbnailStore.thumbnailPayload(from: large))
        let largeDecoded = try #require(ImagePipeline.decode(largePayload, maxPixelSize: 320))
        #expect(largeDecoded.width == 320)
        #expect(largeDecoded.height == 320)
    }

    // MARK: - Key contract

    @Test("the key pins the file version and refuses missing facts")
    func keyContract() {
        let facts = VideoThumbnailStore.cacheKey(
            sourceID: "smb://nas/media", path: "/movies/a.mp4",
            fileSize: 100, modified: Date(timeIntervalSince1970: 500)
        )
        #expect(facts != nil)
        #expect(facts?.variant == "vthumb320")

        // Missing either fact: no key, icon fallback (never a guess).
        #expect(VideoThumbnailStore.cacheKey(
            sourceID: "smb://nas/media", path: "/a.mp4", fileSize: nil, modified: Date()
        ) == nil)
        #expect(VideoThumbnailStore.cacheKey(
            sourceID: "smb://nas/media", path: "/a.mp4", fileSize: 1, modified: nil
        ) == nil)
    }

    @Test("player-written key == card-read key (write/read consistency)")
    @MainActor
    func writeReadKeyConsistency() throws {
        // The writer side: the item the player opened, annotated into the
        // store, then persisted with a save.
        let item = ContentItem(
            name: "a.mp4", path: "/movies/a.mp4", isDirectory: false,
            size: 4096, modifiedDate: Date(timeIntervalSince1970: 1_730_000_000)
        )
        let key = "smb://nas/media|/movies/a.mp4"
        let suiteName = "VideoThumbnailTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackProgressStore(defaults: defaults)
        store.setFileFacts(size: item.size, modified: item.modifiedDate, forKey: key)
        store.savePosition(90, forKey: key, duration: 300)

        // The reader side: the record parsed into a card entry.
        let record = try #require(store.allEntries().first { $0.key == key })
        let entry = try #require(RecentWatchEntry.parse(record))

        let writeKey = VideoThumbnailStore.cacheKey(
            sourceID: "smb://nas/media", path: item.path,
            fileSize: item.size, modified: item.modifiedDate
        )
        let readKey = VideoThumbnailStore.cacheKey(
            sourceID: entry.sourceID, path: entry.path,
            fileSize: entry.fileSize, modified: entry.modifiedDate
        )
        #expect(writeKey?.fileName == readKey?.fileName)
    }

    // MARK: - Writer → reader round-trip

    private func entry(
        fileSize: Int64?, modified: Date?
    ) -> RecentWatchEntry {
        RecentWatchEntry(
            key: "vault://|/movies/a.mp4",
            source: .vault,
            sourceID: "vault://",
            path: "/movies/a.mp4",
            directoryPath: "/movies",
            fileName: "a.mp4",
            position: 60,
            duration: 300,
            fileSize: fileSize,
            modifiedDate: modified,
            lastWatched: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    @Test("a stored cover is found by the reader; misses degrade to nil", .timeLimit(.minutes(1)))
    func writerReaderRoundTrip() async throws {
        let cache = makeTestCache()
        let modified = Date(timeIntervalSince1970: 1_730_000_000)
        let writerKey = VideoThumbnailStore.cacheKey(
            sourceID: "vault://", path: "/movies/a.mp4", fileSize: 2048, modified: modified
        )

        // The player side stores a captured frame; the encode runs detached,
        // so wait for the pool to warm.
        let writer = VideoThumbnailWriter(cache: cache)
        writer.store(
            frame: syntheticFrame(width: 60, height: 60), sourceID: "vault://",
            path: "/movies/a.mp4", fileSize: 2048, modified: modified
        )
        let deadline = ContinuousClock.now + .seconds(10)
        while !(writerKey.map { cache.contains(forKey: $0, pool: .display) } ?? false) {
            if ContinuousClock.now > deadline {
                Issue.record("writer never warmed the display pool")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        // Facts on the record: direct hit.
        let reader = RecentWatchThumbnailReader(cache: cache)
        let hit = await reader.thumbnail(for: entry(fileSize: 2048, modified: modified))
        #expect(hit != nil)
        #expect(min(hit!.width, hit!.height) == 60)

        // Facts missing but the stat seam knows them: backfilled hit.
        let statReader = RecentWatchThumbnailReader(cache: cache) { _ in
            ContentItem(
                name: "a.mp4", path: "/movies/a.mp4", isDirectory: false,
                size: 2048, modifiedDate: modified
            )
        }
        let backfilled = await statReader.thumbnail(for: entry(fileSize: nil, modified: nil))
        #expect(backfilled != nil)

        // No facts anywhere: icon fallback, no key is guessed.
        let blind = await reader.thumbnail(for: entry(fileSize: nil, modified: nil))
        #expect(blind == nil)

        // Different file version: different key, honest miss.
        let stale = await reader.thumbnail(for: entry(fileSize: 4096, modified: modified))
        #expect(stale == nil)

        // Facts present but nothing was ever captured: icon fallback.
        let untouched = await reader.thumbnail(
            for: entry(fileSize: 999_999, modified: Date(timeIntervalSince1970: 9))
        )
        #expect(untouched == nil)
    }
}

/// The card's icon fallback and cover fade-in (DoD: "卡片无图回退图标").
@Suite("Recent watch card cover")
@MainActor
struct RecentWatchCardCoverTests {
    private func makeEntry(fileSize: Int64?) -> RecentWatchEntry {
        RecentWatchEntry(
            key: "vault://|/a.mp4",
            source: .vault,
            sourceID: "vault://",
            path: "/a.mp4",
            directoryPath: "/",
            fileName: "a.mp4",
            position: 30,
            duration: 60,
            fileSize: fileSize,
            modifiedDate: fileSize == nil ? nil : Date(timeIntervalSince1970: 1_730_000_000),
            lastWatched: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    /// Depth-first search for the card's image well.
    private func firstImageView(in view: NSView) -> NSImageView? {
        if let imageView = view as? NSImageView { return imageView }
        for subview in view.subviews {
            if let found = firstImageView(in: subview) { return found }
        }
        return nil
    }

    @Test("without a provider the card keeps the film icon")
    func filmIconWithoutProvider() {
        let card = RecentWatchCardItem()
        card.configure(with: makeEntry(fileSize: nil), thumbnailProvider: nil)
        _ = card.view // loadView

        let icon = firstImageView(in: card.view)
        #expect(icon != nil)
        #expect(icon?.image != nil)
        // The tinted symbol stays (the cover would have cleared the tint).
        #expect(icon?.contentTintColor == CoveStyle.badgeTintVideo)
    }

    @Test("a cover miss keeps the icon; a hit swaps it in", .timeLimit(.minutes(1)))
    func coverSwap() async throws {
        let card = RecentWatchCardItem()

        // Miss (provider without the cover): icon survives.
        let missProvider = RecentWatchThumbnailReader(cache: makeTestCache())
        card.configure(with: makeEntry(fileSize: nil), thumbnailProvider: missProvider)
        try await Task.sleep(for: .milliseconds(150))
        var icon = firstImageView(in: card.view)
        #expect(icon?.contentTintColor == CoveStyle.badgeTintVideo)

        // Hit: a known image fades in over the symbol.
        let cover = solidCover()
        struct HitProvider: RecentWatchThumbnailProviding {
            let cover: CGImage
            func thumbnail(for entry: RecentWatchEntry) async -> CGImage? { cover }
        }
        card.configure(with: makeEntry(fileSize: 2048), thumbnailProvider: HitProvider(cover: cover))
        try await Task.sleep(for: .milliseconds(150))
        icon = firstImageView(in: card.view)
        #expect(icon?.contentTintColor == nil)
        #expect(icon?.image?.size == NSSize(width: 8, height: 8))
    }

    /// An 8×8 solid-red CGImage standing in for a captured cover.
    private func solidCover() -> CGImage {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }
}
