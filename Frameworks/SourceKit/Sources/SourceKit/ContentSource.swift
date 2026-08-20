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
    /// Establishes the session. Must be called before `list`/`read`.
    func connect() async throws

    /// Lists the entries of the directory at `path` (share-relative, `/`-rooted).
    func list(at path: String) async throws -> [ContentItem]

    /// Reads the whole file at `path`. Ranged reads are intentionally not
    /// part of v0.
    func read(at path: String) async throws -> Data

    /// Tears down the session. Idempotent, never throws.
    func disconnect() async
}
