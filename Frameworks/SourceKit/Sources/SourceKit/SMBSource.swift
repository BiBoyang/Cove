import AMSMB2
import Foundation

/// `ContentSource` implementation backed by AMSMB2 (SMB2/SMB3).
///
/// `SMB2Manager` is not `Sendable`, so all access to the client is funneled
/// through `lock`; hence `@unchecked Sendable`. Note that AMSMB2 4.x already
/// ships async/await variants of its (callback-first) API, which is what the
/// methods below call.
public final class SMBSource: ContentSource, @unchecked Sendable {
    public let host: String
    public let share: String

    private let username: String
    private let password: String

    private let lock = NSLock()
    private var client: SMB2Manager?

    public init(host: String, share: String, username: String, password: String) {
        self.host = host
        self.share = share
        self.username = username
        self.password = password
    }

    public func connect() async throws {
        guard let url = URL(string: "smb://\(host)") else {
            throw SourceError.connectionFailed("invalid host: \(host)")
        }
        let credential = URLCredential(user: username, password: password, persistence: .none)
        guard let client = SMB2Manager(url: url, credential: credential) else {
            throw SourceError.connectionFailed("could not create SMB client for \(host)")
        }
        do {
            try await client.connectShare(name: share)
        } catch {
            throw SMBErrorMapper.connectError(error, host: host, resource: share)
        }
        lock.withLock { self.client = client }
    }

    public func disconnect() async {
        let client = lock.withLock { () -> SMB2Manager? in
            let client = self.client
            self.client = nil
            return client
        }

        guard let client else { return }
        try? await client.disconnectShare()
    }

    public func list(at path: String) async throws -> [ContentItem] {
        let client = try requireClient()
        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await client.contentsOfDirectory(atPath: path)
        } catch {
            throw SMBErrorMapper.pathError(error, path: path, operation: "list")
        }
        return entries.compactMap { entry in
            guard let name = entry[.nameKey] as? String else { return nil }
            let isDirectory = (entry[.isDirectoryKey] as? Bool) ?? false
            let size = (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            let modified = entry[.contentModificationDateKey] as? Date
            let fullPath = (entry[.pathKey] as? String) ?? Self.joinPath(base: path, name: name)
            return ContentItem(
                name: name,
                path: fullPath,
                isDirectory: isDirectory,
                size: size,
                modifiedDate: modified
            )
        }
    }

    public func read(at path: String) async throws -> Data {
        let client = try requireClient()
        do {
            return try await client.contents(atPath: path)
        } catch {
            throw SMBErrorMapper.pathError(error, path: path, operation: "read")
        }
    }

    /// Reads at most `maxLength` bytes starting at `offset`.
    ///
    /// Not part of `ContentSource` (the v0 protocol is whole-file only);
    /// exists for the `smb-spike` connectivity probe and future ranged reads.
    public func readRange(at path: String, offset: Int64 = 0, maxLength: Int) async throws -> Data {
        let client = try requireClient()
        guard maxLength > 0 else { return Data() }
        do {
            return try await client.contents(atPath: path, range: offset..<(offset + Int64(maxLength)))
        } catch {
            throw SMBErrorMapper.pathError(error, path: path, operation: "read")
        }
    }

    // MARK: - Internals

    private func requireClient() throws -> SMB2Manager {
        try lock.withLock {
            guard let client else { throw SourceError.notConnected }
            return client
        }
    }

    private static func joinPath(base: String, name: String) -> String {
        if base.isEmpty || base == "/" { return "/" + name }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }
}
