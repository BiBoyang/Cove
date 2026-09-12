import Foundation
import SourceKit
import TraceKit

/// Pure discovery of the external-subtitle sidecar set for one video, from
/// a directory-listing snapshot (the browser's full listing at open time —
/// the player playlist itself is videos-only and cannot serve this).
///
/// Match rule: the video name without its extension (`base`), plus an
/// optional language tag (`Movie.chi.srt`, `Movie_zh.ass`, `Movie-eng.srt`),
/// plus `.srt` or `.ass` (extension case-insensitive). No recursion — the
/// input is one directory's listing. Ordering: exact `base.<ext>` matches
/// first, the rest in natural name order.
enum SubtitleDiscovery {
    /// Sidecar extensions to mount (plain and styled subtitles).
    private static let extensions: Set<String> = ["srt", "ass"]
    /// Separators accepted between `base` and a language tag.
    private static let separators: Set<Character> = [".", "-", "_", " "]
    /// Language-tag length in characters: "zh", "chi", "chs", "eng",
    /// "big5", "中字"… Alphanumerics allowed, but at least one letter is
    /// required — "Movie-2.srt" is an episode number, not a language, and
    /// must not match.
    private static let tagLengths = 1...8

    private enum MatchKind {
        case exact
        case tagged
    }

    /// The siblings (any type) that are external subtitles of `videoName`,
    /// in mount order; empty when the directory has none.
    static func matches(videoName: String, siblings: [ContentItem]) -> [ContentItem] {
        let base = (videoName as NSString).deletingPathExtension
        guard !base.isEmpty else { return [] }
        var exact: [ContentItem] = []
        var tagged: [ContentItem] = []
        for item in siblings where !item.isDirectory {
            switch classify(name: item.name, base: base) {
            case .exact: exact.append(item)
            case .tagged: tagged.append(item)
            case nil: break
            }
        }
        exact.sort { NaturalSort.areInIncreasingOrder($0.name, $1.name) }
        tagged.sort { NaturalSort.areInIncreasingOrder($0.name, $1.name) }
        return exact + tagged
    }

    /// Whether `name` is `base` (exact) or `base` + separator + language
    /// tag (tagged) followed by a subtitle extension.
    private static func classify(name: String, base: String) -> MatchKind? {
        let nsName = name as NSString
        guard extensions.contains(nsName.pathExtension.lowercased()) else { return nil }
        let loweredStem = nsName.deletingPathExtension.lowercased()
        let loweredBase = base.lowercased()
        guard loweredStem.hasPrefix(loweredBase) else { return nil }
        let remainder = loweredStem.dropFirst(loweredBase.count)
        guard let separator = remainder.first, separators.contains(separator) else {
            return remainder.isEmpty ? .exact : nil
        }
        let tag = remainder.dropFirst()
        guard tagLengths.contains(tag.count),
              tag.allSatisfy({ $0.isLetter || $0.isNumber }),
              tag.contains(where: \.isLetter) else { return nil }
        return .tagged
    }
}

/// Stages external subtitles for one playback session: each discovered
/// remote file is pulled through the injected ranged reader in a single
/// capped read (the reader contract truncates at EOF, so one read is the
/// whole file) and written into the session's temp directory, ready for
/// mpv's `sub-add`.
///
/// Everything here is best-effort. A per-file failure is logged and
/// skipped — subtitles are an enhancement, never a playback blocker — and
/// task cancellation (session replaced or window closed) stops staging
/// between files.
struct ExternalSubtitleLoader: Sendable {
    typealias RangedReader = VideoStreamBridge.RangedReader

    /// Root of the per-session staging tree under the process temp dir;
    /// the system purges NSTemporaryDirectory eventually as a backstop.
    private static let rootName = "CoveSubtitles"

    private static let logger = TraceLogger(category: "PlayerSubs")

    /// Hard cap on one staged subtitle. Real SRT/ASS files are orders of
    /// magnitude smaller; a file at exactly the cap is almost certainly
    /// truncated — logged, staged anyway, playback unblocked.
    static let maxBytes: Int64 = 32 * 1024 * 1024

    private let reader: RangedReader

    init(reader: @escaping RangedReader) {
        self.reader = reader
    }

    /// Creates this session's staging directory,
    /// `<tmp>/CoveSubtitles/<uuid>/`. Nil (logged) when the filesystem
    /// refuses, in which case the session simply runs without sidecars.
    static func makeSessionDirectory() -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(rootName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            logger.error("subtitle session directory unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes a session directory; tolerant of one that is already gone.
    static func removeSessionDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.notice("subtitle session directory cleanup skipped: \(error.localizedDescription)")
        }
    }

    /// Pulls every item into `directory` and returns the local file URLs in
    /// input order, skipping per-file failures. Cancellation between files
    /// stops the loop and discards whatever the cancelled fetch returned.
    func stage(_ items: [ContentItem], into directory: URL) async -> [URL] {
        var staged: [URL] = []
        var usedNames = Set<String>()
        for item in items {
            guard !Task.isCancelled else { break }
            do {
                let data = try await reader(item.path, 0..<Self.maxBytes)
                guard !Task.isCancelled else { break }
                guard !data.isEmpty else {
                    Self.logger.notice("skipping empty subtitle sidecar", privacy: .private)
                    continue
                }
                if data.count >= Int(Self.maxBytes) {
                    Self.logger.notice("subtitle sidecar at the size cap, likely truncated", privacy: .private)
                }
                staged.append(try Self.write(data, from: item, into: directory, usedNames: &usedNames))
            } catch {
                Self.logger.error("subtitle sidecar fetch failed: \(error.localizedDescription)", privacy: .private)
            }
        }
        return staged
    }

    /// Writes `data` under the item's (path-component-sanitized) file name.
    /// Listing names are unique on the source share, but the local temp
    /// directory is usually case-insensitive — "a.srt" and "a.SRT" would
    /// collide into one file — so colliding names get an index suffix.
    private static func write(
        _ data: Data,
        from item: ContentItem,
        into directory: URL,
        usedNames: inout Set<String>
    ) throws -> URL {
        let original = (item.name as NSString).lastPathComponent
        let stem = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var name = original
        var counter = 2
        while usedNames.contains(name.lowercased()) {
            name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        usedNames.insert(name.lowercased())
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
