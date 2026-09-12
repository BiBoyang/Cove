import AppKit
import SnapKit

/// Servers feature sidebar: the persisted server list plus an add button.
/// Row 0 is a section header; servers start at row 1. The vault and
/// settings destinations live in a bottom bar pinned under the table.
/// Pure UI — events are forwarded to `MainWindowController` via closures.
@MainActor
final class ServerListViewController: NSViewController {
    private let viewModel: ServerListViewModel

    var onAddServer: (() -> Void)?
    var onConnect: ((ServerConfig) -> Void)?
    var onEdit: ((ServerConfig) -> Void)?
    var onSwitchEndpoint: ((ServerConfig) -> Void)?
    var onRemove: ((ServerConfig) -> Void)?
    var onOpenVault: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let tableView = ServerTableView()
    private let scrollView = NSScrollView()
    private let bottomBar = SidebarBottomBar()
    /// Section-header add button, Notes-style: a small plus at the
    /// trailing edge of the "服务器" group row.
    private let headerAddButton = NSButton()
    /// The most recent mouse-driven selection change; lets a double
    /// click's echo be told from a fresh activation.
    private var lastMouseSelection: (row: Int, at: Date)?

    init(viewModel: ServerListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        viewModel.onStateChange = { [weak self] _ in
            self?.loadViewIfNeeded()
            self?.tableView.reloadData()
        }
        viewModel.onActiveDestinationChange = { [weak self] destination in
            guard let self else { return }
            loadViewIfNeeded()
            syncBarHighlight()
            // Single highlight invariant (2026-09-12 acceptance: no
            // double highlight): a pinned destination on screen clears
            // the table's selection capsule; server destinations keep
            // the clicked row selected.
            if destination != .none {
                tableView.deselectAll(nil)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        // Sidebar vibrancy: the visual effect root gives the whole pane
        // the translucent desktop-tinted material instead of a flat fill.
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Source-list style provides the rounded capsule selection.
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.onReturn = { [weak self] in self?.activateSelectedServer() }

        // Right-click menu on server rows; validated against clickedRow in
        // validateMenuItem so the header row and empty space offer nothing.
        let menu = NSMenu()
        let switchItem = NSMenuItem(
            title: "切换到远程地址", action: #selector(handleSwitchEndpoint), keyEquivalent: ""
        )
        switchItem.target = self
        menu.addItem(switchItem)
        let editItem = NSMenuItem(title: "编辑…", action: #selector(handleEdit), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)
        menu.addItem(.separator())
        let removeItem = NSMenuItem(title: "删除", action: #selector(handleRemove), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        root.addSubview(scrollView)
        root.addSubview(bottomBar)
        // The table scrolls solo; the bar is pinned to the sidebar bottom.
        scrollView.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.bottom.equalTo(bottomBar.snp.top)
        }
        bottomBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }
        bottomBar.onOpenVault = { [weak self] in self?.onOpenVault?() }
        bottomBar.onOpenSettings = { [weak self] in self?.onOpenSettings?() }

        view = root
    }

    @objc private func handleAdd() {
        onAddServer?()
    }

    @objc private func handleDoubleClick() {
        guard Self.shouldConnectOnDoubleClick(
            clickedRow: tableView.clickedRow,
            lastMouseSelection: lastMouseSelection.map {
                (row: $0.row, elapsed: Date().timeIntervalSince($0.at))
            },
            doubleClickInterval: NSEvent.doubleClickInterval
        ) else { return }
        connect(row: tableView.clickedRow)
    }

    @objc private func handleSwitchEndpoint() {
        let row = tableView.clickedRow
        guard let server = viewModel.server(atTableRow: row) else { return }
        onSwitchEndpoint?(server)
    }

    @objc private func handleEdit() {
        let row = tableView.clickedRow
        guard let server = viewModel.server(atTableRow: row) else { return }
        onEdit?(server)
    }

    @objc private func handleRemove() {
        let row = tableView.clickedRow
        guard let server = viewModel.server(atTableRow: row) else { return }
        onRemove?(server)
    }

    private func connect(row: Int) {
        guard let server = viewModel.server(atTableRow: row) else { return }
        onConnect?(server)
    }

    /// Return-activation counterpart of the mouse single click.
    private func activateSelectedServer() {
        connect(row: tableView.selectedRow)
    }

    /// Single highlight invariant: the bar's destination capsule only
    /// shows while the table has no selection — a keyboard-driven
    /// selection (which never connects) masks the bar instead of
    /// doubling the highlight.
    private func syncBarHighlight() {
        bottomBar.setActiveDestination(
            tableView.selectedRow >= 0 ? .none : viewModel.activeDestination
        )
    }
}

extension ServerListViewController {
    /// True only while a left mouse press drives the selection change:
    /// right clicks (context menus), keyboard arrows, and programmatic
    /// selection all report a different current event type or none.
    static func isLeftMouseActivation(eventType: NSEvent.EventType?) -> Bool {
        eventType == .leftMouseDown
    }

    /// Double-click connect decision: when a double click's first click
    /// changed the selection onto the row, that click already connected
    /// it — connecting again would restart the same enumeration for
    /// nothing. Only the echo inside the double-click interval is
    /// suppressed; an older or different-row double click is a fresh
    /// activation (the re-show of an already-selected server).
    static func shouldConnectOnDoubleClick(
        clickedRow: Int,
        lastMouseSelection: (row: Int, elapsed: TimeInterval)?,
        doubleClickInterval: TimeInterval
    ) -> Bool {
        guard clickedRow >= 0 else { return false }
        if let lastMouseSelection, lastMouseSelection.row == clickedRow,
           lastMouseSelection.elapsed < doubleClickInterval {
            return false
        }
        return true
    }
}

extension ServerListViewController: NSMenuItemValidation {
    /// Menu items only apply to actual server rows — not the section
    /// header (row 0) and not empty space below the list. The switch item
    /// additionally renames itself to the destination address kind and is
    /// only offered for servers that actually have a remote address.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let row = tableView.clickedRow
        guard let server = viewModel.server(atTableRow: row) else { return false }
        if menuItem.action == #selector(handleSwitchEndpoint) {
            menuItem.title = server.activeEndpoint == .remote ? "切换到局域网地址" : "切换到远程地址"
            return server.remoteHost != nil
        }
        return true
    }
}

extension ServerListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.rowCount
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        viewModel.isGroupRow(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !viewModel.isGroupRow(row)
    }

    /// Single-click activation: a left-mouse-originated selection change
    /// connects the clicked server. Right clicks only move the selection
    /// to open the context menu, keyboard arrows select without
    /// connecting (Return activates via the table subclass).
    func tableViewSelectionDidChange(_ notification: Notification) {
        syncBarHighlight()
        let row = tableView.clickedRow
        guard row >= 0, Self.isLeftMouseActivation(eventType: NSApp.currentEvent?.type) else { return }
        lastMouseSelection = (row: row, at: Date())
        connect(row: row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // Sidebar rhythm: tight 20pt group headers, 32pt rows.
        viewModel.isGroupRow(row) ? CoveStyle.rowSidebarGroup : CoveStyle.rowSidebar
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if viewModel.isGroupRow(row) {
            return makeHeaderCell(in: tableView)
        }
        let identifier = NSUserInterfaceItemIdentifier("ServerCell")
        let cell: ServerRowCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ServerRowCellView {
            cell = reused
        } else {
            cell = ServerRowCellView()
            cell.identifier = identifier
        }
        if let server = viewModel.server(atTableRow: row) {
            cell.configure(with: server)
        }
        return cell
    }

    /// Section header: small gray label with a trailing add button, in
    /// the spirit of Notes' sidebar section headers.
    private func makeHeaderCell(in tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("ServerHeaderCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.font = CoveStyle.sectionHeaderFont
            textField.textColor = .secondaryLabelColor
            cell.addSubview(textField)
            cell.textField = textField

            headerAddButton.isBordered = false
            headerAddButton.image = NSImage(
                systemSymbolName: "plus", accessibilityDescription: "添加服务器"
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolSmall, weight: .medium))
            headerAddButton.contentTintColor = .secondaryLabelColor
            headerAddButton.imagePosition = .imageOnly
            headerAddButton.title = ""
            headerAddButton.focusRingType = .none
            headerAddButton.target = self
            headerAddButton.action = #selector(handleAdd)
            cell.addSubview(headerAddButton)

            textField.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(CoveStyle.space4)
                make.centerY.equalToSuperview()
            }
            headerAddButton.snp.makeConstraints { make in
                make.trailing.equalToSuperview().inset(CoveStyle.space4)
                make.centerY.equalToSuperview()
                make.size.equalTo(16)
            }
        }
        cell.textField?.stringValue = "服务器"
        return cell
    }
}

/// One server row: a plain monochrome symbol and the server name, in the
/// clean sidebar (no badge chrome). The one marker is a small "远程" tag
/// while the server's remote address is the active one.
@MainActor
private final class ServerRowCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let endpointTagLabel = NSTextField(labelWithString: "远程")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .regular))
        iconView.contentTintColor = .labelColor

        nameLabel.font = CoveStyle.bodyFont
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle

        endpointTagLabel.font = CoveStyle.captionFont
        endpointTagLabel.textColor = .secondaryLabelColor
        endpointTagLabel.isHidden = true
        endpointTagLabel.setContentHuggingPriority(.required, for: .horizontal)
        endpointTagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(endpointTagLabel)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(CoveStyle.space6)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(18)
        }
        endpointTagLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-CoveStyle.space6)
            make.centerY.equalToSuperview()
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(CoveStyle.space8)
            make.trailing.equalToSuperview().offset(-CoveStyle.space4)
            make.centerY.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with server: ServerConfig) {
        nameLabel.stringValue = server.displayName
        // The LAN default stays unmarked (clean sidebar); only the remote
        // endpoint earns the tag, so reuse has to be able to drop it again.
        let showsRemoteTag = server.activeEndpoint == .remote && server.remoteHost != nil
        endpointTagLabel.isHidden = !showsRemoteTag
        nameLabel.snp.remakeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(CoveStyle.space8)
            make.centerY.equalToSuperview()
            if showsRemoteTag {
                make.trailing.lessThanOrEqualTo(endpointTagLabel.snp.leading).offset(-CoveStyle.space6)
            } else {
                make.trailing.equalToSuperview().offset(-CoveStyle.space4)
            }
        }
    }
}

/// Minimal table subclass: forwards Return/Enter to `onReturn` so the
/// keyboard can activate the selected server — arrows only move the
/// selection, the same split `tableViewSelectionDidChange` enforces for
/// the mouse.
@MainActor
private final class ServerTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}
