import CryptoKit
import Foundation

/// Identity of a cached artifact.
///
/// A key pins the exact version of a remote file (`fileSize` +
/// `modifiedTimestamp`, since a NAS path alone can be reused after the file
/// changes) plus the display `variant` of the payload, so a full-resolution
/// original and a downsampled decode of the same file coexist as separate
/// entries.
public struct CacheKey: Hashable, Sendable {
    /// Stable identifier of the source the file came from,
    /// e.g. `"smb://host/share"`.
    public let sourceID: String
    /// Source-relative absolute path of the file.
    public let path: String
    /// Byte size of the remote file, as reported by the source.
    public let fileSize: Int64
    /// Modification time of the remote file, as reported by the source.
    public let modifiedTimestamp: Date
    /// Display variant of the payload, e.g. `"raw"` or `"2048px"`.
    public let variant: String

    public init(sourceID: String, path: String, fileSize: Int64, modifiedTimestamp: Date, variant: String) {
        self.sourceID = sourceID
        self.path = path
        self.fileSize = fileSize
        self.modifiedTimestamp = modifiedTimestamp
        self.variant = variant
    }

    /// Stable on-disk file name: lowercase hex SHA-256 over the canonical
    /// key string. Fields are joined with U+001F (unit separator) so no
    /// field content can shift the field boundaries.
    public var fileName: String {
        let canonical = [
            sourceID,
            path,
            String(fileSize),
            String(modifiedTimestamp.timeIntervalSince1970),
            variant,
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
