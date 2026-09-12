import AppKit
import SnapKit

/// Pinned bottom bar of the servers sidebar: the two fixed destinations
/// (本地仓库 / 设置) as rows under a hairline separator, with the vault's
/// pinned folders as extra rows between them — immovable by server count,
/// scrolling, window resize, or fullscreen. Feature-private per
/// AGENTS.md rule 14.
@MainActor
final class SidebarBottomBar: NSView {
    var onOpenVault: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Pin row intents, forwarded by `ServerListViewController` to the
    /// library coordinator; the bar never touches storage itself.
    var onOpenPin: ((_ path: String) -> Void)?
    var onSetAlias: ((_ path: String) -> Void)?
    var onRemovePin: ((_ path: String) -> Void)?

    private let vaultRow = SidebarDestinationRowView(
        symbol: "externaldrive.fill", title: "本地仓库", tint: CoveStyle.accentGold
    )
    private let settingsRow = SidebarDestinationRowView(
        symbol: "gearshape", title: "设置", tint: .labelColor
    )
    /// Pin rows live in a zero-height container between the vault and
    /// settings rows, so with no pins the bar lays out exactly as before.
    private let pinsArea = NSView()
    private var pinRows: [SidebarPinRowView] = []
    private var pinsAreaHeight: Constraint!
    /// The pin path whose right-click menu is being built.
    private var pinMenuTargetPath: String?
    private let pinMenu = NSMenu()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let separator = NSBox()
        separator.boxType = .separator

        addSubview(separator)
        addSubview(vaultRow)
        addSubview(pinsArea)
        addSubview(settingsRow)

        vaultRow.onTap = { [weak self] in self?.onOpenVault?() }
        settingsRow.onTap = { [weak self] in self?.onOpenSettings?() }
        pinMenu.delegate = self

        separator.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
        }
        vaultRow.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(separator.snp.bottom).offset(CoveStyle.space4)
            make.height.equalTo(CoveStyle.rowSidebar)
        }
        pinsArea.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(vaultRow.snp.bottom)
            self.pinsAreaHeight = make.height.equalTo(0).constraint
        }
        settingsRow.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(pinsArea.snp.bottom)
            make.height.equalTo(CoveStyle.rowSidebar)
            make.bottom.equalToSuperview().offset(-CoveStyle.space4)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var lastDestination: SidebarDestination = .none
    private var activePinPath: String?

    /// Highlights the row of the on-screen destination; `.none` (a server
    /// pane) clears the destination rows.
    func setActiveDestination(_ destination: SidebarDestination) {
        lastDestination = destination
        syncRows()
    }

    /// The "current pin" capsule (2026-09-12 acceptance: a pin click must
    /// show feedback). While inside a pinned subtree the pin row carries
    /// the capsule and the vault root row yields — one bar capsule at
    /// most, extending the single-highlight invariant.
    func setActivePin(_ path: String?) {
        activePinPath = path
        syncRows()
    }

    private func syncRows() {
        vaultRow.setActive(lastDestination == .vault && activePinPath == nil)
        settingsRow.setActive(lastDestination == .settings)
        for row in pinRows { row.setActive(row.pinPath == activePinPath) }
    }

    /// Replaces the pinned-folder rows between the vault and settings
    /// rows. An empty list collapses the area to zero, restoring the
    /// original two-row bar exactly.
    func setPins(_ pins: [VaultPinRow]) {
        pinRows.forEach { $0.removeFromSuperview() }
        pinRows = pins.map { pin in
            let row = SidebarPinRowView(pin: pin)
            row.onTap = { [weak self] in self?.onOpenPin?(pin.path) }
            row.onRightClick = { [weak self] in self?.pinMenuTargetPath = $0 }
            row.menu = pinMenu
            pinsArea.addSubview(row)
            return row
        }
        for (index, row) in pinRows.enumerated() {
            row.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
                make.height.equalTo(CoveStyle.rowSidebar)
                if index == 0 {
                    make.top.equalToSuperview()
                } else {
                    make.top.equalTo(pinRows[index - 1].snp.bottom)
                }
            }
        }
        pinsAreaHeight.update(offset: CGFloat(pinRows.count) * CoveStyle.rowSidebar)
        // Rebuilt rows start inactive; re-apply the current capsule.
        syncRows()
    }

    @objc private func handlePinMenuSetAlias(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onSetAlias?(path)
    }

    @objc private func handlePinMenuRemove(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onRemovePin?(path)
    }
}

extension SidebarBottomBar: NSMenuDelegate {
    /// Rebuilds the pin row's right-click menu on demand: rename or
    /// remove. Both stay available on greyed rows (a missing target must
    /// remain manually removable, never auto-pruned).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let path = pinMenuTargetPath else { return }
        let aliasItem = NSMenuItem(
            title: "设置别名…", action: #selector(handlePinMenuSetAlias(_:)), keyEquivalent: ""
        )
        aliasItem.target = self
        aliasItem.representedObject = path
        let removeItem = NSMenuItem(
            title: "从侧栏移除", action: #selector(handlePinMenuRemove(_:)), keyEquivalent: ""
        )
        removeItem.target = self
        removeItem.representedObject = path
        menu.addItem(aliasItem)
        menu.addItem(removeItem)
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

/// One pinned-folder row: neutral folder symbol + display name, no
/// selection capsule (pins are jump shortcuts, not destinations). A
/// missing target greys the row out but keeps it — and its right-click
/// menu — alive until the user removes the pin manually.
@MainActor
private final class SidebarPinRowView: NSView {
    let pinPath: String
    private let isAvailable: Bool
    private let contentColor: NSColor
    private var isActive = false
    var onTap: (() -> Void)?
    /// Records the row's path as the right-click menu's target before the
    /// menu pops (the bar's single `pinMenu` serves every row).
    var onRightClick: ((_ path: String) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(pin: VaultPinRow) {
        self.pinPath = pin.path
        self.isAvailable = pin.isAvailable
        // Neutral white folder (decision 2, 2026-09-12): labelColor reads
        // white on the sidebar's dark vibrancy, exactly like the settings
        // row's gear; gold stays reserved for the vault root row.
        self.contentColor = pin.isAvailable ? .labelColor : .tertiaryLabelColor
        super.init(frame: .zero)

        let contentColor = self.contentColor
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .regular))
        iconView.contentTintColor = contentColor

        titleLabel.font = CoveStyle.bodyFont
        titleLabel.textColor = contentColor
        titleLabel.stringValue = pin.title
        titleLabel.lineBreakMode = .byTruncatingMiddle
        // Truncate instead of widening: the plain-view bar propagates an
        // over-long title's intrinsic width up to the split view and
        // would drag the sidebar wider (2026-09-12 acceptance bug).
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The tooltip always shows the real vault-relative path, so
        // same-named folders stay distinguishable (decision 1).
        toolTip = pin.path

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

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(pinPath)
        super.rightMouseDown(with: event)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        titleLabel.textColor = active ? .alternateSelectedControlTextColor : contentColor
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

    // Same button-role accessibility contract as the destination rows.
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { titleLabel.stringValue }

    func accessibilityActivate() -> Bool {
        guard isAvailable else { return false }
        onTap?()
        return true
    }

    @objc private func handleClick() {
        guard isAvailable else { return }
        onTap?()
    }
}
