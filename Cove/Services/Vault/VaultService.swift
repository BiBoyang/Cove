import Foundation
import SourceKit
import TraceKit

/// The local vault: permanent whole-file copies downloaded from SMB shares.
///
/// Semantic boundary (task decision): the vault is ownership, not cache —
/// vault files never enter the original pool, are never evicted, and
/// deletion only ever touches the local copy. Downloads are atomic per
/// file (write temp, then rename over the destination), report progress,
/// and are cancellable with no partial files left behind.
@MainActor
final class VaultService {
    /// Progress snapshot for one download run.
    struct DownloadProgress: Equatable, Sendable {
        var completed: Int
        var total: Int
        /// Name of the file currently being downloaded.
        var currentFile: String
    }

    /// Outcome of a finished download run.
    struct DownloadResult: Equatable, Sendable {
        /// Files actually downloaded (new or changed).
        var downloaded: Int
        /// Files skipped because size and mtime already matched.
        var skipped: Int
        /// Remote paths that failed to download (the run continued).
        var failedPaths: [String]
        /// True when the BFS hit a cap and the tree was only partially
        /// walked.
        var truncated: Bool
    }

    /// Runaway-tree guards, same spirit as PreheatKit's FolderEnumerator
    /// (but every file type is collected, not just images).
    static let defaultMaxFiles = 5000
    static let defaultMaxDirectories = 1000

    /// Bytes per ranged read during a download; bounds memory regardless
    /// of file size.
    static let downloadChunkSize: Int64 = 8 * 1024 * 1024

    private let settings: SettingsService?
    private let rootOverride: URL?
    private var cachedRoot: URL?
    private let logger = TraceLogger(category: "Vault")

    init(settings: SettingsService) {
        self.settings = settings
        self.rootOverride = nil
        // A changed vault location takes effect for the next access.
        settings.addChangeObserver { [weak self] in
            self?.cachedRoot = nil
        }
    }

    /// Test seam: a fixed root with no settings round-trip.
    init(root: URL) {
        self.settings = nil
        self.rootOverride = root
    }

    /// The vault root: the user-chosen directory (via security-scoped
    /// bookmark) or the default container location. The directory itself
    /// is created lazily by downloads.
    var rootURL: URL {
        if let rootOverride { return rootOverride }
        if let cachedRoot { return cachedRoot }
        let resolved = Self.resolveRoot(bookmark: settings?.vaultRootBookmark)
        cachedRoot = resolved
        return resolved
    }

    /// The root path as shown in Preferences.
    var displayPath: String { rootURL.path }

    private static func resolveRoot(bookmark: Data?) -> URL {
        let logger = TraceLogger(category: "Vault")
        if let bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            ) {
                // Access is kept for the process lifetime; the grant is
                // cheap and the vault root is used repeatedly.
                _ = url.startAccessingSecurityScopedResource()
                if isStale {
                    logger.notice("Vault bookmark is stale; re-saving is the Preferences row's job", privacy: .public)
                }
                return url
            }
            logger.error("Vault bookmark failed to resolve; falling back to the default root", privacy: .public)
        }
        return defaultRootURL
    }

    /// `~/Library/Application Support/Cove/Vault` — inside the sandbox
    /// container, so it needs no user-selected-file permission.
    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cove/Vault", isDirectory: true)
    }

    /// Maps a remote item to its vault location:
    /// `<root>/<sanitized server label>/<share>/<remote path>`, so same-named
    /// shares or files on different servers never collide.
    func localURL(serverLabel: String, share: String, path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return rootURL
            .appendingPathComponent(Self.sanitize(serverLabel), isDirectory: true)
            .appendingPathComponent(share, isDirectory: true)
            .appendingPathComponent(trimmed)
    }

    /// HFS/APFS-hostile characters in a path component become "-".
    static func sanitize(_ component: String) -> String {
        let cleaned = component
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    /// Deletes the local copy at a vault-relative path (as produced by
    /// `LocalFileSource` listings). Refuses anything outside the root.
    /// Never touches the NAS — the caller owns the user-facing wording.
    ///
    /// Note: the prefix guard does not resolve symlinks. The vault's
    /// content is written exclusively by this service, so a hostile link
    /// inside it is not a realistic threat (review note).
    func delete(vaultRelativePath path: String) throws {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        guard url.path.hasPrefix(rootPath + "/") else {
            throw SourceError.permissionDenied(path)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Downloads one remote item (file or directory, the latter BFS-recursive
    /// across all file types) into the vault. Unchanged files (same size and
    /// mtime) are skipped; changed files are replaced atomically.
    ///
    /// The remote side is injected as closures so the service stays
    /// source-agnostic; cancellation comes from the surrounding task and
    /// never leaves a partial destination file.
    func download(
        item: ContentItem,
        serverLabel: String,
        share: String,
        list: @Sendable (String) async throws -> [ContentItem],
        read: @Sendable (String, Range<Int64>) async throws -> Data,
        progress: (@MainActor (DownloadProgress) -> Void)? = nil
    ) async throws -> DownloadResult {
        let files: [ContentItem]
        var truncated = false
        if item.isDirectory {
            let collection = try await Self.collectFiles(
                root: item.path, list: list,
                maxFiles: Self.defaultMaxFiles, maxDirectories: Self.defaultMaxDirectories
            )
            files = collection.files
            truncated = collection.truncated
        } else {
            files = [item]
        }

        var result = DownloadResult(downloaded: 0, skipped: 0, failedPaths: [], truncated: truncated)
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            progress?(DownloadProgress(completed: index, total: files.count, currentFile: file.name))
            do {
                if try await downloadOne(file: file, serverLabel: serverLabel, share: share, read: read) {
                    result.downloaded += 1
                } else {
                    result.skipped += 1
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                logger.error("Vault download failed for \(file.path): \(error.localizedDescription)", privacy: .private)
                result.failedPaths.append(file.path)
            }
        }
        progress?(DownloadProgress(completed: files.count, total: files.count, currentFile: ""))
        return result
    }

    /// Returns true when the file was (re)downloaded, false when the local
    /// copy was already current.
    private func downloadOne(
        file: ContentItem,
        serverLabel: String,
        share: String,
        read: @Sendable (String, Range<Int64>) async throws -> Data
    ) async throws -> Bool {
        let destination = localURL(serverLabel: serverLabel, share: share, path: file.path)
        if isUnchanged(file: file, destination: destination) {
            return false
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Write-temp-then-rename: a cancelled or failed download never
        // leaves a partial file at the destination.
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).cove-tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        // Chunked copy: ranged reads appended to the temp file keep memory
        // at O(chunk) — vault content is mostly video, so a whole-file
        // read would spike gigabytes (review finding).
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            var offset: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await read(file.path, offset..<(offset + Self.downloadChunkSize))
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
                // A short chunk means the read ran into EOF.
                if Int64(chunk.count) < Self.downloadChunkSize { break }
            }
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        if let modified = file.modifiedDate {
            // Stamp the local copy with the remote mtime so the next run's
            // unchanged check compares equal timestamps.
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: temp.path
            )
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return true
    }

    private func isUnchanged(file: ContentItem, destination: URL) -> Bool {
        guard let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let localSize = values.fileSize else { return false }
        guard Int64(localSize) == file.size else { return false }
        // Without a remote mtime there is nothing reliable to compare —
        // treat as changed and refresh.
        guard let remoteModified = file.modifiedDate,
              let localModified = values.contentModificationDate else { return false }
        return localModified == remoteModified
    }

    /// BFS over every file under `root` (all types; noise skipped), in the
    /// FolderEnumerator style: root unreadable throws, an unreadable
    /// subdirectory is logged and skipped, cancellation propagates.
    private static func collectFiles(
        root: String,
        list: @Sendable (String) async throws -> [ContentItem],
        maxFiles: Int,
        maxDirectories: Int
    ) async throws -> (files: [ContentItem], truncated: Bool) {
        let rootPath = root.hasPrefix("/") ? root : "/" + root
        var files: [ContentItem] = []
        var pendingDirectories: [String] = [rootPath]
        var visitedDirectories = 0
        var truncated = false

        while !pendingDirectories.isEmpty {
            try Task.checkCancellation()
            if files.count >= maxFiles || visitedDirectories >= maxDirectories {
                truncated = true
                break
            }
            let path = pendingDirectories.removeFirst()
            visitedDirectories += 1
            let entries: [ContentItem]
            do {
                entries = try await list(path)
            } catch {
                if path == rootPath { throw error }
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                continue
            }
            for entry in entries where !entry.isNoise {
                if entry.isDirectory {
                    pendingDirectories.append(entry.path)
                } else {
                    files.append(entry)
                    if files.count >= maxFiles { break }
                }
            }
        }
        if !pendingDirectories.isEmpty { truncated = true }
        return (files, truncated)
    }
}
