import AppKit
import SnapKit

/// Pinned bottom bar of the servers sidebar: the two fixed destinations
/// (本地仓库 / 设置) as rows under a hairline separator — immovable by
/// server count, scrolling, window resize, or fullscreen. Feature-private
/// per AGENTS.md rule 14.
@MainActor
final class SidebarBottomBar: NSView {
    var onOpenVault: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let vaultRow = SidebarDestinationRowView(
        symbol: "externaldrive.fill", title: "本地仓库", tint: CoveStyle.accentGold
    )
    private let settingsRow = SidebarDestinationRowView(
        symbol: "gearshape", title: "设置", tint: .labelColor
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let separator = NSBox()
        separator.boxType = .separator

        addSubview(separator)
        addSubview(vaultRow)
        addSubview(settingsRow)

        vaultRow.onTap = { [weak self] in self?.onOpenVault?() }
        settingsRow.onTap = { [weak self] in self?.onOpenSettings?() }

        separator.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
        }
        vaultRow.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(separator.snp.bottom).offset(CoveStyle.space4)
            make.height.equalTo(CoveStyle.rowSidebar)
        }
        settingsRow.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(vaultRow.snp.bottom)
            make.height.equalTo(CoveStyle.rowSidebar)
            make.bottom.equalToSuperview().offset(-CoveStyle.space4)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Highlights the row of the on-screen destination; `.none` (a server
    /// pane) clears both.
    func setActiveDestination(_ destination: SidebarDestination) {
        vaultRow.setActive(destination == .vault)
        settingsRow.setActive(destination == .settings)
    }
}

/// One destination row of the bottom bar: monochrome symbol + title over
/// a rounded selection capsule, visually matching the table's rows.
/// Click-to-activate (System-Settings style destination rows).
@MainActor
private final class SidebarDestinationRowView: NSView {
    var onTap: (() -> Void)?
    private var isActive = false

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(symbol: String, title: String, tint: NSColor) {
        super.init(frame: .zero)

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .regular))
        iconView.contentTintColor = tint

        titleLabel.font = CoveStyle.bodyFont
        titleLabel.textColor = .labelColor

        addSubview(iconView)
        addSubview(titleLabel)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(CoveStyle.space6)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(CoveStyle.symbolLarge)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(CoveStyle.space8)
            make.trailing.lessThanOrEqualToSuperview().offset(-CoveStyle.space4)
            make.centerY.equalToSuperview()
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        // Emphasized text on the capsule, like a selected source-list row;
        // the symbol keeps its identity tint (gold drive, plain gear).
        titleLabel.textColor = active ? .alternateSelectedControlTextColor : .labelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: CoveStyle.space4, dy: 0),
                xRadius: CoveStyle.radiusRowSelection,
                yRadius: CoveStyle.radiusRowSelection
            ).fill()
        }
        super.draw(dirtyRect)
    }

    // The row is a plain view, so expose it as a pressable button to
    // accessibility (role, label, and the activation action).
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { titleLabel.stringValue }

    func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    @objc private func handleClick() {
        onTap?()
    }
}
