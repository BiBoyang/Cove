import AppKit
import SnapKit

/// Settings destination pane shown in the main area when the sidebar
/// "设置" row is selected. Step 1 is the skeleton placeholder; the four
/// sections (cache/preheat/reader/vault) migrate in from
/// PreferencesWindowController in Step 2, driven by PreferencesViewModel.
@MainActor
final class SettingsPaneViewController: NSViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        // Same warm dark content background as the other detail panes.
        root.wantsLayer = true
        root.layer?.backgroundColor = CoveStyle.libraryBackground.cgColor

        let placeholder = StatePlaceholderView(
            style: .symbol("gearshape"),
            title: "设置",
            message: "设置正在迁移到这里，可先从菜单栏「设置…」打开。"
        )
        root.addSubview(placeholder)
        placeholder.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        view = root
    }
}
