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

    struct State: Sendable {
        let shares: [SMBShareInfo]
        let placeholder: Placeholder?
    }

    private(set) var state = State(
        shares: [],
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

    /// Idle guidance shown whenever no server is selected.
    func showIdlePlaceholder() {
        update(
            shares: [],
            placeholder: Placeholder(
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
        update(
            shares: [],
            placeholder: Placeholder(
                kind: .info(symbol: "server.rack"),
                title: "还没有添加服务器",
                message: "添加一台 NAS，浏览它的共享文件夹。",
                action: .addServer
            )
        )
    }

    func showLoading() {
        update(
            shares: [],
            placeholder: Placeholder(
                kind: .loading,
                title: "正在获取共享列表…",
                message: "",
                action: nil
            )
        )
    }

    /// Share enumeration failed. The placeholder carries the retry affordance
    /// (and the remote-endpoint hint when the server has one), so no modal
    /// alert fires alongside it.
    func showEnumerationFailure(canSwitchToRemote: Bool) {
        update(
            shares: [],
            placeholder: Placeholder(
                kind: .failure(symbol: "exclamationmark.triangle"),
                title: "获取共享列表失败",
                message: canSwitchToRemote
                    ? "请检查网络后重试。\n该服务器已配置远程地址，也可右键服务器切换后重试。"
                    : "请检查网络后重试。",
                action: .retry
            )
        )
    }

    func display(shares: [SMBShareInfo]) {
        update(
            shares: shares,
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

    private func update(shares: [SMBShareInfo], placeholder: Placeholder?) {
        state = State(shares: shares, placeholder: placeholder)
        onStateChange?(state)
    }
}
