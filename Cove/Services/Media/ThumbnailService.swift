import CacheKit
import CoreGraphics
import Foundation
import ImagePipeline
import SourceKit

protocol ThumbnailProviding: Sendable {
    func thumbnail(for item: ContentItem) async -> CGImage?
}

/// Media service loading real thumbnails for the browser's image rows.
///
/// Pipeline per image: a display-pool hit (variant `thumb160` — a square
/// center-crop at 160 px, the 40×40 badge @2x with headroom) decodes a small
/// JPEG straight to `CGImage`; on a miss the original bytes come from the
/// original pool or the NAS (and are stored into the original pool), get
/// downsampled + cropped off the main thread, and the result is re-encoded
/// into the display pool. The `thumb160` variant is deliberately unlike the
/// reader/preheat `w<width>` variants so the two pipelines never share
/// display entries; the original pool ("raw") IS shared with them.
///
/// The actor's executor keeps every cache/disk/decode step off the main
/// thread; the injected `readFile` hops straight onto the SMB actor, so
/// reads never queue behind main-thread UI work (same convention as the
/// reader). Network reads are capped at two concurrent (`readGate`) so a
/// folder full of rows cannot crowd out the reader's page loads; cache
/// hits bypass the gate.
/// Requests for the same image coalesce onto one in-flight task, and a
/// failed image is remembered for the session so reusing rows never
/// re-hammers the NAS with a file that cannot decode.
/// Minimal async semaphore: at most `limit` gated bodies run
/// concurrently. A released slot passes directly to the next waiter.
private actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            available = min(available + 1, limit)
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }

    func withGate<T>(_ body: () async throws -> T) async rethrows -> T {
        await wait()
        do {
            let value = try await body()
            signal()
            return value
        } catch {
            signal()
            throw error
        }
    }
}

actor ThumbnailService: ThumbnailProviding {
    /// Ways a thumbnail load can fail beyond the underlying source error.
    private enum LoadError: Error {
        /// Bytes were read but are not a decodable image.
        case undecodable
    }

    /// Display-pool variant name for browser thumbnails.
    static let displayVariant = "thumb160"
    /// Max pixel side of the decoded thumbnail before the center-crop.
    static let thumbnailPixelSize = 160
    /// JPEG quality for display-pool payloads; matches the reader.
    private static let displayJPEGQuality = 0.85

    private let readFile: @Sendable (String) async throws -> Data
    private let cache: CacheStore
    private let sourceID: String
    /// Caps concurrent network reads (cache layers bypass it).
    private let readGate = AsyncSemaphore(limit: 2)
    /// Coalescing index: display cache key → shared load task.
    private var inFlight: [CacheKey: Task<CGImage, Error>] = [:]
    /// Images that failed this session; never retried automatically.
    private var failed: Set<CacheKey> = []

    /// - Parameters:
    ///   - readFile: whole-file read on the current share, injected by the
    ///     coordinator so the service never touches the session layer.
    ///   - cache: the app-wide disk cache (CacheKit).
    ///   - sourceID: cache-key identity of the share, e.g. `smb://host/share`.
    init(
        readFile: @escaping @Sendable (String) async throws -> Data,
        cache: CacheStore,
        sourceID: String
    ) {
        self.readFile = readFile
        self.cache = cache
        self.sourceID = sourceID
    }

    /// Returns the thumbnail for `item`, or `nil` when it is undecodable or
    /// already failed this session. Callers are expected to be image rows.
    func thumbnail(for item: ContentItem) async -> CGImage? {
        let displayKey = CacheKey.sourceFile(
            sourceID: sourceID, path: item.path, fileSize: item.size,
            modified: item.modifiedDate, variant: Self.displayVariant
        )
        if failed.contains(displayKey) { return nil }
        if let task = inFlight[displayKey] {
            return try? await task.value
        }
        let readFile = readFile
        let cache = cache
        let readGate = readGate
        let task = Task.detached(priority: .utility) {
            try await Self.load(
                item: item, displayKey: displayKey,
                readFile: readFile, cache: cache, readGate: readGate
            )
        }
        inFlight[displayKey] = task
        do {
            let image = try await task.value
            inFlight.removeValue(forKey: displayKey)
            return image
        } catch {
            inFlight.removeValue(forKey: displayKey)
            // A cancelled waiter says nothing about the image; only real
            // failures are remembered. (The shared task itself is not
            // cancelled by one waiter's cancellation.)
            if !(error is CancellationError) {
                failed.insert(displayKey)
            }
            return nil
        }
    }

    /// display pool → original pool → network; each produced layer is
    /// stored back into its pool. Runs on a background executor.
    private static func load(
        item: ContentItem,
        displayKey: CacheKey,
        readFile: @Sendable (String) async throws -> Data,
        cache: CacheStore,
        readGate: AsyncSemaphore
    ) async throws -> CGImage {
        if let payload = try? cache.data(forKey: displayKey, pool: .display) {
            try Task.checkCancellation()
            if let image = ImagePipeline.decode(payload, maxPixelSize: thumbnailPixelSize) {
                return image
            }
            // Corrupt payload: fall through to the original layer.
        }

        let originalKey = CacheKey.sourceFile(
            sourceID: displayKey.sourceID, path: item.path, fileSize: item.size,
            modified: displayKey.modifiedTimestamp, variant: CacheKey.rawVariant
        )
        let original: Data
        if let cached = try? cache.data(forKey: originalKey, pool: .original) {
            original = cached
        } else {
            try Task.checkCancellation()
            original = try await readGate.withGate {
                try await readFile(item.path)
            }
            try Task.checkCancellation()
            try? cache.store(original, forKey: originalKey, pool: .original)
        }

        guard let decoded = ImagePipeline.decode(original, maxPixelSize: thumbnailPixelSize),
              let image = ImagePipeline.cropCenterSquare(decoded)
        else {
            throw LoadError.undecodable
        }
        try Task.checkCancellation()
        if let payload = ImagePipeline.encodeJPEG(image, quality: displayJPEGQuality) {
            try? cache.store(payload, forKey: displayKey, pool: .display)
        }
        return image
    }
}
