import CacheKit
import ComicKit
import Foundation
import ReaderKit
import SourceKit

/// Cache identity and original-data adapter for one Reader page.
///
/// The UI-facing page model lives in ReaderKit; these fields stay in the App
/// media layer because cache keys are an application policy, not Reader UI.
struct ReaderCachePage: Sendable, Hashable {
    let page: ReaderPage
    let cachePath: String
    let cacheFileSize: Int64
    let cacheModified: Date?
}

/// App-level Reader content adapter for directory files and CBZ entries.
///
/// ReaderKit owns the document/page contract. This adapter owns SourceKit,
/// ComicKit, and the original-pool cache policy used to obtain source bytes.
struct ReaderContent: Sendable, ReaderPageSource {
    let document: ReaderDocument
    let cachePages: [ReaderCachePage]
    let pageData: @Sendable (Int) async throws -> Data

    var pages: [ReaderPage] { document.pages }

    func loadOriginalData(at index: Int) async throws -> Data {
        try await pageData(index)
    }
}

extension ReaderContent {
    /// Original-pool layering shared by both modes: a hit returns cached
    /// bytes; a miss reads via `fileReader` and best-effort stores the
    /// payload under the file's "raw" key.
    private static func originalBytes(
        for item: ContentItem,
        fileReader: @Sendable (String) async throws -> Data,
        cache: CacheStore,
        sourceID: String
    ) async throws -> Data {
        let key = CacheKey.sourceFile(
            sourceID: sourceID, path: item.path, fileSize: item.size,
            modified: item.modifiedDate, variant: CacheKey.rawVariant
        )
        if let cached = try? cache.data(forKey: key, pool: .original) {
            return cached
        }
        try Task.checkCancellation()
        let data = try await fileReader(item.path)
        try Task.checkCancellation()
        try? cache.store(data, forKey: key, pool: .original)
        return data
    }

    /// Directory mode: `items` are the directory's image files in display
    /// order; each page's original payload is its own file.
    static func directory(
        items: [ContentItem],
        fileReader: @escaping @Sendable (String) async throws -> Data,
        cache: CacheStore,
        sourceID: String
    ) -> ReaderContent {
        let cachePages = items.map {
            ReaderCachePage(
                page: ReaderPage(id: $0.path, title: $0.name),
                cachePath: $0.path,
                cacheFileSize: $0.size,
                cacheModified: $0.modifiedDate
            )
        }
        let document = ReaderDocument(pages: cachePages.map(\.page))
        return ReaderContent(document: document, cachePages: cachePages) { index in
            try await originalBytes(
                for: items[index], fileReader: fileReader, cache: cache, sourceID: sourceID
            )
        }
    }

    /// CBZ mode: the whole archive is fetched once (original pool → NAS),
    /// its image entries become the pages in natural order, and page bytes
    /// are extracted from the shared in-memory `ComicArchive`.
    static func comic(
        item: ContentItem,
        fileReader: @escaping @Sendable (String) async throws -> Data,
        cache: CacheStore,
        sourceID: String
    ) async throws -> ReaderContent {
        let data = try await originalBytes(
            for: item, fileReader: fileReader, cache: cache, sourceID: sourceID
        )
        try Task.checkCancellation()
        let archive = try ComicArchive(data: data)
        let entries = archive.imageEntries
        let cachePages = entries.map { entry in
            ReaderCachePage(
                page: ReaderPage(id: "\(item.path)!\(entry)", title: (entry as NSString).lastPathComponent),
                cachePath: "\(item.path)!\(entry)",
                cacheFileSize: item.size,
                cacheModified: item.modifiedDate
            )
        }
        let document = ReaderDocument(pages: cachePages.map(\.page))
        return ReaderContent(document: document, cachePages: cachePages) { index in
            try archive.extractImage(named: entries[index])
        }
    }
}
