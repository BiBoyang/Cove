import AMSMB2
import Foundation

/// Client-level timeouts (seconds) handed to AMSMB2's `SMB2Manager.timeout`.
enum SMBTimeout {
    /// Connect / share-enumeration phase: fail fast on unreachable hosts
    /// instead of riding out AMSMB2's 60s default.
    static let connect: TimeInterval = 15
    /// Steady-state operations (list/metadata/read): AMSMB2's default, so
    /// slow links and large files are not cut off by the connect budget.
    static let read: TimeInterval = 60
}

/// `ContentSource` implementation backed by AMSMB2 (SMB2/SMB3).
///
/// An actor: `SMB2Manager` is not `Sendable`, so every call that touches the
/// client is serialized on the actor instead of behind a manual lock. Note
/// that AMSMB2 4.x already ships async/await variants of its (callback-first)
/// API, which is what the methods below call.
public actor SMBSource: ContentSource {
    public let host: String
    public let share: String

    private let username: String
    private let password: String

    private var client: SMB2Manager?

    public init(host: String, share: String, username: String, password: String) {
        self.host = host
        self.share = share
        self.username = username
        self.password = password
    }

    /// Stable cache-key identifier, e.g. `"smb://nas.local/media"`.
    /// Computed from immutable `let`s, so it stays nonisolated.
    public nonisolated var sourceID: String {
        "smb://\(host)/\(share)"
    }

    public func connect() async throws {
        guard let url = URL(string: "smb://\(host)") else {
            throw SourceError.connectionFailed("invalid host: \(host)")
        }
        let credential = URLCredential(user: username, password: password, persistence: .none)
        do {
            // A fresh client per attempt: a failed libsmb2 context is
            // destroyed, so retrying on the same manager is not safe.
            self.client = try await TransientRetry.run {
                guard let client = SMB2Manager(url: url, credential: credential) else {
                    throw SourceError.connectionFailed("could not create SMB client for \(host)")
                }
                client.timeout = SMBTimeout.connect
                try await client.connectShare(name: share)
                client.timeout = SMBTimeout.read
                return client
            }
        } catch let error as SourceError {
            throw error
        } catch {
            throw SMBErrorMapper.connectError(error, host: host, resource: share)
        }
    }

    public func disconnect() async {
        guard let client else { return }
        self.client = nil
        // Graceful: AMSMB2 waits for its queued operations to finish before
        // tearing down. Being actor-isolated, this also runs after any
        // already-enqueued calls on this source.
        try? await client.disconnectShare(gracefully: true)
    }

    public func list(at path: String) async throws -> [ContentItem] {
        let client = try requireClient()
        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await client.contentsOfDirectory(atPath: path)
        } catch {
            throw SMBErrorMapper.pathError(error, path: path, operation: "list")
        }
        return Self.contentItems(from: entries, base: path)
    }

    /// Maps AMSMB2's resource-key dictionaries to content items. Builds
    /// each path from the raw entry name, never AMSMB2's `.pathKey`: that
    /// one goes through Foundation URL APIs, which normalize the name to
    /// NFD — and a precomposed (NFC) name on the server then fails to read
    /// back with "path not found".
    static func contentItems(from entries: [[URLResourceKey: Any]], base path: String) -> [ContentItem] {
        entries.compactMap { entry in
            guard let name = entry[.nameKey] as? String else { return nil }
            let isDirectory = (entry[.isDirectoryKey] as? Bool) ?? false
            let size = (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            let modified = entry[.contentModificationDateKey] as? Date
            let fullPath = Self.joinPath(base: path, name: name)
            return ContentItem(
                name: name,
                path: fullPath,
                isDirectory: isDirectory,
                size: size,
                modifiedDate: modified
            )
        }
    }

    public func metadata(at path: String) async throws -> ContentItem {
        let client = try requireClient()
        let attributes: [URLResourceKey: Any]
        do {
            attributes = try await client.attributesOfItem(atPath: path)
        } catch {
            throw SMBErrorMapper.pathError(error, path: path, operation: "metadata")
        }
        return Self.contentItem(from: attributes, path: path)
    }

    public func read(at path: String, range: Range<Int64>) async throws -> Data {
        let client = try requireClient()
        do {
            // AMSMB2 stats the file first and clamps the range to its size,
            // so an open-ended upper bound (the whole-file default
            // `0..<Int64.max`) is safe here.
            return try await client.contents(atPath: path, range: range)
        } catch {
            throw SMBErrorMapper.pathError(error, path: path, operation: "read")
        }
    }

    // MARK: - Internals

    private func requireClient() throws -> SMB2Manager {
        guard let client else { throw SourceError.notConnected }
        return client
    }

    /// Maps URL resource attributes onto a `ContentItem`. Internal and pure
    /// so the field mapping is unit-testable without a server.
    static func contentItem(from attributes: [URLResourceKey: Any], path: String) -> ContentItem {
        let name = (attributes[.nameKey] as? String) ?? (path as NSString).lastPathComponent
        return ContentItem(
            name: name,
            path: path,
            isDirectory: (attributes[.isDirectoryKey] as? Bool) ?? false,
            size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0,
            modifiedDate: attributes[.contentModificationDateKey] as? Date
        )
    }

    private static func joinPath(base: String, name: String) -> String {
        if base.isEmpty || base == "/" { return "/" + name }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }
}
