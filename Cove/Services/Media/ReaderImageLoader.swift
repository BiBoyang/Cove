import CacheKit
import CoreGraphics
import Foundation
import ImagePipeline
import ReaderKit
import TraceKit

struct ReaderLoadedImage: Sendable {
    let image: CGImage
    let size: CGSize
}

protocol ReaderPageLoading: Sendable {
    func load(pageAt index: Int) async throws -> ReaderLoadedImage
}

/// Sendable display-pipeline adapter shared by Reader views.
///
/// The ReaderKit page/source contract stays independent of cache policy;
/// this App media layer combines it with CacheKit and ImagePipeline.
struct ReaderImageLoader: ReaderPageLoading {
    private static let displayPayloadDecodeCap = 16384
    private static let displayJPEGQuality = 0.85

    let cache: CacheStore
    let sourceID: String
    let targetWidth: Int
    let logger: TraceLogger
    let content: ReaderContent

    func load(pageAt index: Int) async throws -> ReaderLoadedImage {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            logger.debug(
                "load finish index=\(index) duration=\(CFAbsoluteTimeGetCurrent() - startedAt)"
            )
        }
        let displayKey = self.displayKey(pageAt: index)
        if let payload = try? cache.data(forKey: displayKey, pool: .display) {
            try Task.checkCancellation()
            if let image = ImagePipeline.decode(payload, maxPixelSize: Self.displayPayloadDecodeCap) {
                logger.debug("load display-hit index=\(index) variant=w\(targetWidth)")
                return ReaderLoadedImage(image: image, size: CGSize(width: image.width, height: image.height))
            }
            logger.debug("load display-corrupt index=\(index) variant=w\(targetWidth)")
        } else {
            logger.debug("load display-miss index=\(index) variant=w\(targetWidth)")
        }

        let original = try await content.loadOriginalData(at: index)
        try Task.checkCancellation()

        guard let displaySize = ImagePipeline.displayDimensions(of: original) else {
            throw ReaderLoadError.undecodable
        }
        let budget = ImagePipeline.maxPixelSize(forDisplaySize: displaySize, targetWidth: targetWidth)
        guard let image = ImagePipeline.decode(original, maxPixelSize: budget) else {
            throw ReaderLoadError.undecodable
        }
        try Task.checkCancellation()
        if let payload = ImagePipeline.encodeJPEG(image, quality: Self.displayJPEGQuality) {
            try? cache.store(payload, forKey: displayKey, pool: .display)
        }
        return ReaderLoadedImage(image: image, size: CGSize(width: image.width, height: image.height))
    }

    /// Best-effort pre-decode of one page into the display pool.
    ///
    /// A page whose display variant already exists is skipped *before*
    /// any decoding: `load`'s display-hit path still decodes the stored
    /// payload for display, which would spend exactly the CPU this warm
    /// exists to save. Errors are swallowed — the page's real load, when
    /// the user reaches it, is what surfaces them.
    func warm(pageAt index: Int) async {
        guard content.cachePages.indices.contains(index) else { return }
        if let payload = try? cache.data(forKey: displayKey(pageAt: index), pool: .display) {
            logger.debug("warm skip index=\(index) variant=w\(targetWidth) bytes=\(payload.count)")
            return
        }
        _ = try? await load(pageAt: index)
    }

    /// The page's display-pool identity, shared by `load` and `warm` so
    /// the two can never drift apart.
    private func displayKey(pageAt index: Int) -> CacheKey {
        let page = content.cachePages[index]
        return CacheKey.sourceFile(
            sourceID: sourceID, path: page.cachePath, fileSize: page.cacheFileSize,
            modified: page.cacheModified, variant: CacheKey.displayWidthVariant(targetWidth)
        )
    }
}
