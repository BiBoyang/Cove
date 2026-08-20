import Foundation

/// Errors surfaced by a `ContentSource`.
///
/// Distinct cases exist so the UI can tell a connection problem apart from
/// an authentication problem or a missing path.
public enum SourceError: Error, Sendable, Equatable {
    /// An operation was requested before `connect()` succeeded.
    case notConnected
    /// The server is unreachable or refused the connection.
    case connectionFailed(String)
    /// The server rejected the credentials.
    case authenticationFailed
    /// The requested path (or share) does not exist on the server.
    case pathNotFound(String)
    /// The credentials are valid but lack permission for this path.
    case permissionDenied(String)
    /// Anything else; the associated value carries the details.
    case operationFailed(String)
}

extension SourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "No active connection."
        case .connectionFailed(let detail):
            return "Connection failed: \(detail)"
        case .authenticationFailed:
            return "Authentication failed: wrong username or password."
        case .pathNotFound(let path):
            return "Path not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .operationFailed(let detail):
            return detail
        }
    }
}

/// A browsable, readable content source (SMB share now; more later).
public protocol ContentSource: Sendable {
    /// Stable identifier, suitable as a cache key.
    /// The SMB implementation uses `"smb://host/share"`.
    var sourceID: String { get }

    /// Establishes the session. Must be called before `list`/`read`.
    func connect() async throws

    /// Lists the entries of the directory at `path` (share-relative, `/`-rooted).
    func list(at path: String) async throws -> [ContentItem]

    /// Attributes of the single item at `path` (share-relative, `/`-rooted).
    func metadata(at path: String) async throws -> ContentItem

    /// Reads the bytes of the file at `path` in `range`. Ranges extending
    /// past EOF are truncated to the actual file content.
    func read(at path: String, range: Range<Int64>) async throws -> Data

    /// Tears down the session. Idempotent, never throws.
    func disconnect() async
}

public extension ContentSource {
    /// Whole-file read, expressed as one open-ended ranged read.
    func read(at path: String) async throws -> Data {
        try await read(at: path, range: 0..<Int64.max)
    }
}
