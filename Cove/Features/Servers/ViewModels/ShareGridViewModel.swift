import Foundation
import SourceKit

@MainActor
final class ShareGridViewModel {
    /// What the grid shows when there are no share cards on screen.
    /// Pure values, no platform types (AGENTS.md rule 16).
    struct Placeholder: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// Actual in-flight work: renders a spinner.
            case loading
            /// Empty/guidance state: renders the named symbol.
            case info(symbol: String)
            /// Recoverable failure: renders the symbol plus a retry button.
            case failure(symbol: String)
        }
        /// Optional action button on the placeholder; the view controller
        /// maps it to the matching coordinator intent.
        enum Action: Sendable, Equatable {
            case retry
            case addServer
        }
        let kind: Kind
        let title: String
        let message: String
        let action: Action?
    }

    /// One card's content: the share itself plus the locally recorded
    /// "last opened" line. Pure values, no platform types (rule 16).
    struct ShareCardInfo: Equatable, Sendable {
        let share: SMBShareInfo
        /// Text of the "last opened" line; nil hides the line.
        let lastOpenedText: String?

        /// Comment line text; an empty server remark hides the line.
        var comment: String? {
            share.comment.isEmpty ? nil : share.comment
        }

        /// Relative text in the system language (RelativeDateTimeFormatter).
        /// A record newer than `now` (clock skew, migrated defaults) clamps
        /// to now so the line never announces a future open.
        static func relativeText(for date: Date, relativeTo now: Date) -> String {
            RelativeDateTimeFormatter().localizedString(for: min(date, now), relativeTo: now)
        }
    }

    struct State: Sendable {
        let cards: [ShareCardInfo]
        let placeholder: Placeholder?
    }

    private(set) var state = State(
        cards: [],
        placeholder: Placeholder(
            kind: .info(symbol: "externaldrive"),
            title: "双击左侧服务器以连接",
            message: "",
            action: nil
        )
    )

    var onStateChange: ((State) -> Void)? {
        didSet { onStateChange?(state) }
    }

    /// Reads the locally recorded open timestamp for a share; injected so
    /// tests can substitute an in-memory lookup.
    private let lastOpened: @MainActor (UUID, String) -> Date?

    /// Assembly context of the cards on screen: `refreshCards()` re-runs
    /// assembly against the records lookup so relative times stay fresh.
    private var displayedShares: [SMBShareInfo] = []
    private var displayedServerID: UUID?

    init(
        lastOpened: @escaping @MainActor (UUID, String) -> Date? = { _, _ in nil }
    ) {
        self.lastOpened = lastOpened
    }

    /// Idle guidance for the no-server-selected state. The grid pane no
    /// longer hosts the idle page (the home destination does, Amendment 2),
    /// but the placeholder stays part of the grid's pure state vocabulary.
    func showIdlePlaceholder() {
        showPlaceholder(
            Placeholder(
                kind: .info(symbol: "externaldrive"),
                title: "双击左侧服务器以连接",
                message: "",
                action: nil
            )
        )
    }

    /// First-run guidance: no servers configured at all, so the placeholder
    /// earns a primary "add server" action instead of pointing at an empty
    /// sidebar.
    func showEmptyServerGuidance() {
        showPlaceholder(Placeholder(
            kind: .info(symbol: "server.rack"),
            title: "还没有添加服务器",
            message: "添加一台 NAS，浏览它的共享文件夹。",
            action: .addServer
        ))
    }

    func showLoading() {
        showPlaceholder(Placeholder(
            kind: .loading,
            title: "正在获取共享列表…",
            message: "",
            action: nil
        ))
    }

    /// Share enumeration failed. The placeholder carries the retry affordance
    /// (and the remote-endpoint hint when the server has one), so no modal
    /// alert fires alongside it.
    func showEnumerationFailure(canSwitchToRemote: Bool) {
        showPlaceholder(Placeholder(
            kind: .failure(symbol: "exclamationmark.triangle"),
            title: "获取共享列表失败",
            message: canSwitchToRemote
                ? "请检查网络后重试。\n该服务器已配置远程地址，也可右键服务器切换后重试。"
                : "请检查网络后重试。",
            action: .retry
        ))
    }

    func display(shares: [SMBShareInfo], serverID: UUID) {
        displayedShares = shares
        displayedServerID = serverID
        update(
            cards: assembleCards(),
            placeholder: shares.isEmpty
                ? Placeholder(
                    kind: .info(symbol: "folder"),
                    title: "该服务器没有可用共享",
                    message: "",
                    action: nil
                )
                : nil
        )
    }

    /// Re-assembles the visible cards: the grid reappears after an open,
    /// and the "last opened" lines must reflect the record just written.
    /// A placeholder state owns no cards, so refreshing there is a no-op.
    func refreshCards() {
        guard displayedServerID != nil, !displayedShares.isEmpty else { return }
        update(cards: assembleCards(), placeholder: nil)
    }

    private func assembleCards() -> [ShareCardInfo] {
        let now = Date()
        return displayedShares.map { share in
            let opened = displayedServerID.flatMap { lastOpened($0, share.name) }
            return ShareCardInfo(
                share: share,
                lastOpenedText: opened.map { ShareCardInfo.relativeText(for: $0, relativeTo: now) }
            )
        }
    }

    /// Placeholder states own no cards; the assembly context is dropped so
    /// a later refresh cannot revive stale content.
    private func showPlaceholder(_ placeholder: Placeholder) {
        displayedShares = []
        displayedServerID = nil
        update(cards: [], placeholder: placeholder)
    }

    private func update(cards: [ShareCardInfo], placeholder: Placeholder?) {
        state = State(cards: cards, placeholder: placeholder)
        onStateChange?(state)
    }
}
