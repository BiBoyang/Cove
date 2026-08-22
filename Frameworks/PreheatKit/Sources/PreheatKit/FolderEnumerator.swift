import Foundation
import SourceKit
import TraceKit

/// Breadth-first recursive collector for preheating — backs both the
/// "preheat folder" setting and the browser's "preheat this folder"
/// button.
///
/// Lives in PreheatKit (not the app target) so the traversal policy —
/// image-only, hidden-file filtering, explosion caps — is unit-testable
/// without a window server.
public enum FolderEnumerator {
    /// Hard cap on collected image files; guards against runaway trees.
    public static let defaultMaxFiles = 5000
    /// Hard cap on visited directories; a huge tree of irrelevant folders
    /// must not keep the connection busy forever.
    public static let defaultMaxDirectories = 1000

    /// Lists only `directory` itself — no recursion — returning image items
    /// in listing order. Noise entries (SourceKit's `isNoise`) are skipped.
    /// The browser's "preheat this folder" button uses `collectImages`
    /// instead; this single-level variant stays for callers that must not
    /// recurse.
    ///
    /// An unreadable `directory` throws, since the user explicitly asked
    /// for that folder.
    public static func listImages(
        source: any ContentSource,
        directory: String
    ) async throws -> [ContentItem] {
        let path = directory.hasPrefix("/") ? directory : "/" + directory
        let entries = try await source.list(at: path)
        return entries.filter { !$0.isNoise && !$0.isDirectory && $0.fileType == .image }
    }

    /// Lists `root` and every subdirectory breadth-first, returning image
    /// items in discovery order. Noise entries (SourceKit's `isNoise`, the
    /// same rule the browser uses) are skipped.
    ///
    /// An unreadable subdirectory is skipped (logged); an unreadable `root`
    /// throws, since the user explicitly asked for that folder.
    public static func collectImages(
        source: any ContentSource,
        root: String,
        maxFiles: Int = defaultMaxFiles,
        maxDirectories: Int = defaultMaxDirectories
    ) async throws -> [ContentItem] {
        let logger = TraceLogger(category: "preheat.folders")
        let rootPath = root.hasPrefix("/") ? root : "/" + root
        var images: [ContentItem] = []
        var pendingDirectories: [String] = [rootPath]
        var visitedDirectories = 0

        while !pendingDirectories.isEmpty,
              images.count < maxFiles,
              visitedDirectories < maxDirectories {
            try Task.checkCancellation()
            let path = pendingDirectories.removeFirst()
            visitedDirectories += 1
            let entries: [ContentItem]
            do {
                entries = try await source.list(at: path)
            } catch {
                if path == rootPath { throw error }
                // Cancellation (e.g. a cancelled `source.list`) must not be
                // swallowed as an unreadable directory — otherwise a cancel
                // landing on the last pending directory would end the
                // traversal with silently truncated partial results.
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                logger.error(
                    "Skipping unreadable directory \(path): \(error.localizedDescription)",
                    privacy: .private
                )
                continue
            }
            for entry in entries where !entry.isNoise {
                if entry.isDirectory {
                    pendingDirectories.append(entry.path)
                } else if entry.fileType == .image {
                    images.append(entry)
                    if images.count >= maxFiles { break }
                }
            }
        }
        return images
    }
}
