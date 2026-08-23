import Foundation

/// A `ContentSource` backed by a local directory tree — the vault.
///
/// The vault is a plain folder on disk; "connecting" just validates the
/// root. Paths are vault-relative and `/`-rooted exactly like SMB paths,
/// so the whole browse/read pipeline works unchanged. Reads never touch
/// the network, and listings filter the same `isNoise` entries the
/// browser hides anyway.
public struct LocalFileSource: ContentSource {
    /// The directory path `/` maps to.
    public let root: URL
    public let sourceID: String

    public init(root: URL, sourceID: String = "vault://") {
        self.root = root
        self.sourceID = sourceID
    }

    /// A not-yet-created vault root is valid: it lists as empty and is
    /// created by the first download. An existing non-directory root is a
    /// configuration error worth surfacing.
    public func connect() async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw SourceError.operationFailed("Vault root is not a directory: \(root.path)")
        }
    }

    public func disconnect() async {}

    public func list(at path: String) async throws -> [ContentItem] {
        let directory = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            // Browsing an empty vault (nothing downloaded yet) shows an
            // empty root rather than an error.
            if path == "/" { return [] }
            throw SourceError.pathNotFound(path)
        }
        guard isDirectory.boolValue else {
            throw SourceError.operationFailed("Not a directory: \(path)")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        )
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = values.name ?? url.lastPathComponent
            let itemIsDirectory = values.isDirectory ?? false
            let item = ContentItem(
                name: name,
                path: Self.join(path, name),
                isDirectory: itemIsDirectory,
                size: itemIsDirectory ? 0 : Int64(values.fileSize ?? 0),
                modifiedDate: values.contentModificationDate
            )
            return item.isNoise ? nil : item
        }
    }

    public func metadata(at path: String) async throws -> ContentItem {
        let url = try resolve(path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            throw SourceError.pathNotFound(path)
        }
        let isDirectory = values.isDirectory ?? false
        return ContentItem(
            name: values.name ?? url.lastPathComponent,
            path: path.hasPrefix("/") ? path : "/" + path,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : Int64(values.fileSize ?? 0),
            modifiedDate: values.contentModificationDate
        )
    }

    public func read(at path: String, range: Range<Int64>) async throws -> Data {
        let url = try resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SourceError.pathNotFound(path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, range.lowerBound)))
        // The protocol's whole-file read arrives as an open-ended range.
        if range.upperBound == Int64.max {
            return try handle.readToEnd() ?? Data()
        }
        return try handle.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
    }

    /// Resolves a vault-relative path against `root`, refusing anything
    /// that escapes the root (`..` components). The check does not resolve
    /// symlinks — acceptable because the vault's content is written
    /// exclusively by VaultService (review note).
    private func resolve(_ path: String) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = (trimmed.isEmpty ? root : root.appendingPathComponent(trimmed)).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw SourceError.permissionDenied(path)
        }
        return url
    }

    private static func join(_ path: String, _ name: String) -> String {
        path == "/" ? "/\(name)" : "\(path)/\(name)"
    }
}
