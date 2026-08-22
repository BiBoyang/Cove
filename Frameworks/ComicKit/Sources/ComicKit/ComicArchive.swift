import Foundation
import SourceKit
import Synchronization
import ZIPFoundation

/// Ways opening or reading a comic archive can fail, beyond the raw
/// ZIPFoundation errors thrown by entry extraction.
public enum ComicArchiveError: Error, Sendable, Equatable {
    /// The bytes are not a readable ZIP archive.
    case unreadableArchive
    /// The archive contains no image entries.
    case noImageEntries
    /// A previously listed entry is gone (should not happen for a fixed archive).
    case entryNotFound(String)
}

extension ComicArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadableArchive:
            return "The file is not a readable ZIP archive."
        case .noImageEntries:
            return "The archive contains no readable images."
        case .entryNotFound(let path):
            return "Entry not found in the archive: \(path)"
        }
    }
}

/// A CBZ comic archive held in memory: the image-entry list plus thread-safe
/// per-entry extraction.
///
/// ZIPFoundation's `Archive` is a mutable class (extraction seeks a shared
/// in-memory file cursor) and is neither `Sendable` nor thread-safe, so all
/// access is serialized through a mutex here. Callers dispatch extraction to
/// background threads themselves; this type is safe to share between them.
///
/// Only regular-file entries whose names classify as images (SourceKit's
/// extension table) are exposed, in natural page order; directory entries
/// and macOS metadata noise (`__MACOSX`, `._*` AppleDouble files) are hidden.
public final class ComicArchive: Sendable {
    /// Guarded non-Sendable state: the archive and its entries by path.
    private struct State {
        let archive: Archive
        let entriesByPath: [String: Entry]
    }

    private let state: Mutex<State>
    /// Image entry paths in display order (natural page sort).
    public let imageEntries: [String]

    /// Opens an in-memory archive over `data` (the whole CBZ file) and
    /// indexes its image entries. `data` is retained by the archive.
    ///
    /// - Throws: `ComicArchiveError.unreadableArchive` when `data` is not a
    ///   ZIP archive, `.noImageEntries` when it contains no images.
    public init(data: Data) throws {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw ComicArchiveError.unreadableArchive
        }
        var images: [String] = []
        var entriesByPath: [String: Entry] = [:]
        for entry in archive where entry.type == .file {
            let path = entry.path
            guard Self.isImageEntry(path) else { continue }
            images.append(path)
            entriesByPath[path] = entry
        }
        images.sort(by: NaturalSort.areInIncreasingOrder)
        guard !images.isEmpty else { throw ComicArchiveError.noImageEntries }
        state = Mutex(State(archive: archive, entriesByPath: entriesByPath))
        imageEntries = images
    }

    /// Extracts the uncompressed bytes of the image entry at `path` (one of
    /// `imageEntries`). Serialized against other extractions; call from a
    /// background thread.
    public func extractImage(named path: String) throws -> Data {
        try state.withLock { state in
            guard let entry = state.entriesByPath[path] else {
                throw ComicArchiveError.entryNotFound(path)
            }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            _ = try state.archive.extract(entry) { chunk in
                data.append(chunk)
            }
            return data
        }
    }

    /// Image classification by extension (SourceKit's table), minus macOS
    /// metadata noise that Mac-created archives carry along.
    static func isImageEntry(_ path: String) -> Bool {
        if path.hasPrefix("__MACOSX/") { return false }
        if (path as NSString).lastPathComponent.hasPrefix("._") { return false }
        return ContentItem.FileType(classifying: path) == .image
    }
}
