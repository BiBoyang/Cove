import Foundation
import SourceKit
import TraceKit

/// Observable resolution state of the vault root
/// (TASK-dev-bookmark-resilience): a stored bookmark that fails to resolve
/// is NOT the same as having no bookmark. The former surfaces in
/// Preferences as a re-pick hint; the root still falls back to the default
/// container location meanwhile (recovery semantics unchanged).
enum VaultRootStatus: Equatable, Sendable {
    /// No bookmark stored; the default container root is in use.
    case defaultRoot
    /// The stored bookmark resolved; the user-chosen root is in use.
    case bookmarkResolved
    /// A stored bookmark failed to resolve; the default root is in use
    /// until the user re-picks the location.
    case bookmarkInvalid

    /// Pure classification so the "bookmark present but failed" vs "no
    /// bookmark" distinction is unit-testable without the real bookmark API.
    static func classify(bookmark: Data?, resolvedURL: URL?) -> VaultRootStatus {
        guard bookmark != nil else { return .defaultRoot }
        return resolvedURL != nil ? .bookmarkResolved : .bookmarkInvalid
    }
}

/// The local vault: permanent whole-file copies downloaded from SMB shares.
///
/// Semantic boundary (task decision): the vault is ownership, not cache —
/// vault files are never evicted, and deletion only ever touches the local
/// copy. Downloads are atomic per file (write temp, then rename over the
/// destination), report progress, and are cancellable with no partial files
/// left behind. Browsing thumbnails copy bytes through the cache pools
/// (BUG-5, 2026-09-07); the vault files themselves stay outside cache
/// management.
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
    private var cachedStatus: VaultRootStatus = .defaultRoot
    /// Fired on the main actor whenever the resolved root may have changed.
    /// The settings observer runs on any settings write, not only vault-root
    /// ones; re-checks triggered from here (≤8 sync stats for pin targets)
    /// are cheap enough that over-firing is harmless.
    var onVaultRootChanged: (@MainActor () -> Void)?
    private let logger = TraceLogger(category: "Vault")

    init(settings: SettingsService) {
        self.settings = settings
        self.rootOverride = nil
        // A changed vault location takes effect for the next access.
        settings.addChangeObserver { [weak self] in
            self?.cachedRoot = nil
            self?.onVaultRootChanged?()
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
        cachedRoot = resolved.url
        cachedStatus = resolved.status
        return resolved.url
    }

    /// The root path as shown in Preferences.
    var displayPath: String { rootURL.path }

    /// The root resolution state, for the Preferences re-pick hint. Reading
    /// it resolves the root if that has not happened yet, so it can never
    /// lag behind the stored bookmark.
    var rootStatus: VaultRootStatus {
        if rootOverride != nil { return .defaultRoot }
        _ = rootURL
        return cachedStatus
    }

    private static func resolveRoot(bookmark: Data?) -> (url: URL, status: VaultRootStatus) {
        let logger = TraceLogger(category: "Vault")
        guard let bookmark else {
            return (defaultRootURL, .defaultRoot)
        }
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        )
        let status = VaultRootStatus.classify(bookmark: bookmark, resolvedURL: url)
        guard let url else {
            logger.error("Vault bookmark failed to resolve; falling back to the default root", privacy: .public)
            return (defaultRootURL, status)
        }
        // Access is kept for the process lifetime; the grant is
        // cheap and the vault root is used repeatedly.
        _ = url.startAccessingSecurityScopedResource()
        if isStale {
            logger.notice("Vault bookmark is stale; re-saving is the Preferences row's job", privacy: .public)
        }
        return (url, status)
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

    /// True when a vault-relative pinned folder exists on disk (a pin can
    /// only point at directories). One synchronous stat per pin target;
    /// never mutates anything — a missing target greys the sidebar row
    /// instead of removing it, and the same root-prefix guard as
    /// `delete(vaultRelativePath:)` keeps stored paths inside the vault.
    func pinTargetExists(relativePath path: String) -> Bool {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty else { return false }
        let rootPath = rootURL.standardizedFileURL.path
        let url = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        guard url.path.hasPrefix(rootPath + "/") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
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
