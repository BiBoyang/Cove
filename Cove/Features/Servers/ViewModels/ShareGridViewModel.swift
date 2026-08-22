import Foundation
import SourceKit

@MainActor
final class ShareGridViewModel {
    struct State: Sendable {
        let shares: [SMBShareInfo]
        let placeholder: String?
    }

    private(set) var state = State(shares: [], placeholder: "双击左侧服务器以连接")

    var onStateChange: ((State) -> Void)? {
        didSet { onStateChange?(state) }
    }

    func showPlaceholder(_ text: String) {
        update(shares: [], placeholder: text)
    }

    func showLoading() {
        showPlaceholder("正在获取共享列表…")
    }

    func display(shares: [SMBShareInfo]) {
        update(
            shares: shares,
            placeholder: shares.isEmpty ? "该服务器没有可用共享" : nil
        )
    }

    private func update(shares: [SMBShareInfo], placeholder: String?) {
        state = State(shares: shares, placeholder: placeholder)
        onStateChange?(state)
    }
}
