import Foundation
import SourceKit

/// Where a recent watch lives, parsed out of the record's sourceID
/// (decision 2). Only SMB entries carry the host/share pair the deep
/// link needs to reconnect; the vault is a local source.
enum RecentWatchSource: Equatable, Sendable {
    case smb(host: String, share: String)
    case vault
}

/// One card of the home page's continue-watching grid: a parsed
/// playback-progress record (decision 2). Pure values, no platform types
/// (AGENTS.md rule 16) — the view renders it, the coordinator deep-links
/// it. Lives beside `HomeViewModel` so the model, its parsing, and the
/// state that carries it review as one unit.
struct RecentWatchEntry: Equatable, Sendable {
    /// Full store key ("sourceID|path"); cleanup removes by this key.
    let key: String
    let source: RecentWatchSource
    /// Cache-key identity of the record's source, compared against the
    /// live session so an already-connected share is reused (decision 4).
    let sourceID: String
    /// Video path within its source, e.g. "/movies/a.mp4".
    let path: String
    /// Parent directory; the deep link navigates here before opening.
    let directoryPath: String
    let fileName: String
    /// Resume point in seconds.
    let position: Double
    /// Total seconds; nil on pre-duration records — the card then shows
    /// no progress bar, only the timecode (decision 1).
    let duration: Double?
    let lastWatched: Date

    var isVault: Bool {
        if case .vault = source { return true }
        return false
    }

    /// Watched fraction 0…1 for the mini progress bar; nil without a
    /// usable duration (the decision-1 degradation).
    var progressFraction: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    /// "已看至 h:mm:ss · N天前" (decision 3). The timecode reuses the
    /// player's formatter and the relative part the share card's, so the
    /// home cards speak exactly like the rest of the app; `now` is
    /// injected to keep tests deterministic. MainActor-bound because the
    /// reused formatters live on MainActor types; every caller (card
    /// item, VM tests) already is.
    @MainActor func subtitleText(relativeTo now: Date) -> String {
        let timecode = PlayerViewModel.formatTime(position)
        let relative = ShareGridViewModel.ShareCardInfo.relativeText(for: lastWatched, relativeTo: now)
        return "已看至 \(timecode) · \(relative)"
    }

    /// Parses one stored record; nil for malformed keys (decision 2
    /// skips them): no "|" separator, empty path or file name, unknown
    /// source scheme, or an SMB sourceID without a share segment.
    static func parse(_ record: PlaybackProgressEntry) -> RecentWatchEntry? {
        // The sourceID can never contain "|" (SMB hosts/shares and the
        // vault scheme are pipe-free), so the first one splits cleanly.
        guard let separator = record.key.firstIndex(of: "|") else { return nil }
        let sourceID = String(record.key[..<separator])
        let path = String(record.key[record.key.index(after: separator)...])
        guard !path.isEmpty else { return nil }
        let fileName = (path as NSString).lastPathComponent
        guard !fileName.isEmpty, fileName != "/" else { return nil }
        var directoryPath = (path as NSString).deletingLastPathComponent
        if directoryPath.isEmpty { directoryPath = "/" }

        let source: RecentWatchSource
        if sourceID.hasPrefix("vault://") {
            source = .vault
        } else if sourceID.hasPrefix("smb://") {
            let rest = sourceID.dropFirst("smb://".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let host = String(rest[..<slash])
            let share = String(rest[rest.index(after: slash)...])
            guard !host.isEmpty, !share.isEmpty else { return nil }
            source = .smb(host: host, share: share)
        } else {
            return nil
        }

        return RecentWatchEntry(
            key: record.key,
            source: source,
            sourceID: sourceID,
            path: path,
            directoryPath: directoryPath,
            fileName: fileName,
            position: record.position,
            duration: record.duration,
            lastWatched: record.lastWatched
        )
    }

    /// The recent-watches list: parsed records with malformed keys
    /// skipped, most recently watched first, capped (decision 2; the
    /// home page passes the wider Amendment-2 cap).
    static func recentList(from records: [PlaybackProgressEntry], cap: Int = 10) -> [RecentWatchEntry] {
        let parsed = records.compactMap(parse)
        return Array(parsed.sorted { $0.lastWatched > $1.lastWatched }.prefix(cap))
    }
}

/// The home destination's state: the continue-watching grid (Amendment 2
/// decision 1). One `refresh()` re-reads both injected lookups, so every
/// arrival re-parses records written during the session and deep-link
/// cleanups land immediately.
@MainActor
final class HomeViewModel {
    /// What the page shows when the grid has no cards. Two levels
    /// (Amendment 2 decision 2): zero configured servers is first-run
    /// guidance with an add action; servers without any watch records is
    /// plain guidance. Pure values, no platform types (rule 16).
    struct Placeholder: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// No servers configured at all: add-server guidance.
            case noServers
            /// Servers exist but nothing has been watched yet.
            case noRecords
        }
        /// Optional action button on the placeholder; the view controller
        /// maps it to the matching coordinator intent.
        enum Action: Sendable, Equatable {
            case addServer
        }
        let kind: Kind
        let title: String
        let message: String
        let action: Action?
    }

    struct State: Sendable, Equatable {
        let entries: [RecentWatchEntry]
        /// Nil while entries fill the grid.
        let placeholder: Placeholder?
    }

    /// The home grid's capacity (Amendment 2 decision 4): the page is the
    /// grid, so it widens the parsing default of 10.
    static let recentCap = 30

    private(set) var state = State(entries: [], placeholder: nil)

    var onStateChange: ((State) -> Void)? {
        didSet { onStateChange?(state) }
    }

    /// Raw resume records behind the grid; injected so tests can
    /// substitute in-memory records (same discipline as the share grid's
    /// `lastOpened` seam).
    private let recentWatchRecords: @MainActor () -> [PlaybackProgressEntry]
    /// Live server-config count for the empty-state judgment; read fresh
    /// on every refresh so an add or remove re-levels the empty state on
    /// the next arrival.
    private let serverCount: @MainActor () -> Int

    init(
        recentWatchRecords: @escaping @MainActor () -> [PlaybackProgressEntry] = { [] },
        serverCount: @escaping @MainActor () -> Int = { 0 }
    ) {
        self.recentWatchRecords = recentWatchRecords
        self.serverCount = serverCount
    }

    /// Re-parses the records and re-judges the two-level empty state.
    /// Every arrival at the page (start, the sidebar's home row, server
    /// removal) and every deep-link cleanup funnels through here, so
    /// freshly written records appear and pruned ones drop off
    /// immediately.
    func refresh() {
        let entries = RecentWatchEntry.recentList(from: recentWatchRecords(), cap: Self.recentCap)
        state = State(entries: entries, placeholder: emptyState(for: entries))
        onStateChange?(state)
    }

    private func emptyState(for entries: [RecentWatchEntry]) -> Placeholder? {
        guard entries.isEmpty else { return nil }
        if serverCount() == 0 {
            return Placeholder(
                kind: .noServers,
                title: "还没有添加服务器",
                message: "添加一台 NAS，浏览它的共享文件夹。",
                action: .addServer
            )
        }
        return Placeholder(
            kind: .noRecords,
            title: "还没有播放记录",
            message: "双击左侧服务器以连接，看过的视频会出现在这里。",
            action: nil
        )
    }
}
