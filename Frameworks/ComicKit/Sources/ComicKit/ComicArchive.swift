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
    /// An entry's uncompressed size exceeds the safety cap — either its ZIP
    /// header declares more than the cap, or the actual decompressed bytes
    /// ran past it mid-extraction (a declared-small zip bomb). Untrusted
    /// network input must never be able to trap or exhaust memory here.
    case entryTooLarge(String)
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
        case .entryTooLarge(let path):
            return "Entry exceeds the maximum supported size: \(path)"
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
/// and noise entries (dot-prefixed files, `__MACOSX` folders) are hidden.
public final class ComicArchive: Sendable {
    /// Guarded non-Sendable state: the archive and its entries by path.
    private struct State {
        let archive: Archive
        let entriesByPath: [String: Entry]
    }

    /// Hard cap on one entry's uncompressed bytes (512 MiB). CBZ files
    /// arrive over SMB and are untrusted: a high-resolution page stays under
    /// ~50 MB, and even extreme scans fit in a tenth of this — the cap only
    /// exists to stop malformed headers and zip bombs from trapping or
    /// exhausting memory. Absurd pixel dimensions are rejected downstream by
    /// ImagePipeline's source-pixel gate before decode.
    public static let maxEntryUncompressedBytes: UInt64 = 512 * 1024 * 1024

    /// Test hook: when set, replaces `maxEntryUncompressedBytes` so the
    /// extraction-time (running total) guard is exercisable without
    /// decompressing real hundreds of megabytes. Mutex-guarded because a
    /// bare mutable static is rejected by Swift 6 concurrency checks.
    private static let entrySizeCapOverride = Mutex<UInt64?>(nil)
    static func setEntrySizeCapOverrideForTesting(_ value: UInt64?) {
        entrySizeCapOverride.withLock { $0 = value }
    }
    /// The cap extraction actually enforces.
    static var effectiveMaxEntryUncompressedBytes: UInt64 {
        entrySizeCapOverride.withLock { $0 } ?? maxEntryUncompressedBytes
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
            // Malformed archives can carry the same name twice; first wins
            // so the page never shows up twice in display order.
            guard entriesByPath[path] == nil else { continue }
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
    ///
    /// The declared size is untrusted ZIP input: it is compared in the
    /// UInt64 domain before any `Int` conversion (a header claiming more
    /// than `Int.max` would otherwise trap), and the running total is
    /// checked chunk by chunk so a small declared size cannot hide a bomb.
    public func extractImage(named path: String) throws -> Data {
        try state.withLock { state in
            guard let entry = state.entriesByPath[path] else {
                throw ComicArchiveError.entryNotFound(path)
            }
            let cap = Self.effectiveMaxEntryUncompressedBytes
            guard entry.uncompressedSize <= cap else {
                throw ComicArchiveError.entryTooLarge(path)
            }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            var total: UInt64 = 0
            _ = try state.archive.extract(entry) { chunk in
                total += UInt64(chunk.count)
                guard total <= cap else {
                    throw ComicArchiveError.entryTooLarge(path)
                }
                data.append(chunk)
            }
            return data
        }
    }

    /// Image classification by extension (SourceKit's table), minus macOS
    /// metadata noise that Mac-created archives carry along.
    static func isImageEntry(_ path: String) -> Bool {
        if ContentItem.isNoise(path: path) { return false }
        return ContentItem.FileType(classifying: path) == .image
    }
}
