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
    var onOpenHome: (() -> Void)?
    var onOpenVault: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Vault pin row intents, forwarded from the bottom bar to the
    /// library coordinator (same pass-through pattern as onOpenVault).
    var onOpenPin: ((_ path: String) -> Void)?
    var onSetAlias: ((_ path: String) -> Void)?
    var onRemovePin: ((_ path: String) -> Void)?

    /// Local-folder section intents (TASK-local-folder-sidebar). The
    /// NSOpenPanel run and the security-scoped bookmark creation stay in
    /// this View layer (task DoD 2); the coordinator only ever receives
    /// pure values (name/bookmark/id).
    var onOpenLocalFolder: ((_ id: String) -> Void)?
    var onAddLocalFolder: ((_ name: String, _ bookmark: Data) -> Void)?
    var onRemoveLocalFolder: ((_ id: String) -> Void)?
    var onRepickLocalFolder: ((_ id: String, _ bookmark: Data) -> Void)?

    private let tableView = ServerTableView()
    private let scrollView = NSScrollView()
    private let bottomBar = SidebarBottomBar()
    /// The most recent mouse-driven selection change; lets a double
    /// click's echo be told from a fresh activation.
    private var lastMouseSelection: (row: Int, at: Date)?

    init(viewModel: ServerListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        viewModel.onStateChange = { [weak self] _ in
            guard let self else { return }
            loadViewIfNeeded()
            tableView.reloadData()
            // The server count shifts every local-folder row; re-sync the
            // folder highlight against the new layout.
            syncTableSelection()
            syncBarHighlight()
        }
        viewModel.onActiveDestinationChange = { [weak self] destination in
            guard let self else { return }
            loadViewIfNeeded()
            syncTableSelection()
            syncBarHighlight()
        }
        viewModel.onLocalFoldersChange = { [weak self] _ in
            guard let self else { return }
            loadViewIfNeeded()
            tableView.reloadData()
            syncTableSelection()
            syncBarHighlight()
        }
        viewModel.onPinsChange = { [weak self] pins in
            self?.loadViewIfNeeded()
            self?.bottomBar.setPins(pins)
        }
        viewModel.onActivePinChange = { [weak self] _ in
            self?.loadViewIfNeeded()
            self?.syncBarHighlight()
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

        // Right-click menu, rebuilt per click in `menuNeedsUpdate` from
        // the clicked row's kind: server rows get endpoint/edit/delete,
        // local-folder rows get remove (+ re-pick when invalid), headers
        // and empty space get nothing.
        let menu = NSMenu()
        menu.delegate = self
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
        bottomBar.onOpenHome = { [weak self] in self?.onOpenHome?() }
        bottomBar.onOpenVault = { [weak self] in self?.onOpenVault?() }
        bottomBar.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        bottomBar.onOpenPin = { [weak self] in self?.onOpenPin?($0) }
        bottomBar.onSetAlias = { [weak self] in self?.onSetAlias?($0) }
        bottomBar.onRemovePin = { [weak self] in self?.onRemovePin?($0) }

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

    /// Single/double-click and Return activation funnel: local-folder
    /// rows open the folder, server rows connect the server.
    private func connect(row: Int) {
        if let folder = viewModel.localFolder(atTableRow: row) {
            onOpenLocalFolder?(folder.id)
        } else if let server = viewModel.server(atTableRow: row) {
            onConnect?(server)
        }
    }

    /// Section-header "+": pick a directory, create its security-scoped
    /// bookmark here in the View layer, hand name + bookmark upstream.
    @objc private func handleAddLocalFolder() {
        presentFolderPicker { [weak self] url, bookmark in
            self?.onAddLocalFolder?(url.lastPathComponent, bookmark)
        }
    }

    @objc private func handleRemoveLocalFolder() {
        guard let folder = viewModel.localFolder(atTableRow: tableView.clickedRow) else { return }
        onRemoveLocalFolder?(folder.id)
    }

    /// Invalid-row re-pick: same panel as add; the entry keeps its name,
    /// only the bookmark is replaced upstream.
    @objc private func handleRepickLocalFolder() {
        guard let folder = viewModel.localFolder(atTableRow: tableView.clickedRow) else { return }
        presentFolderPicker { [weak self] _, bookmark in
            self?.onRepickLocalFolder?(folder.id, bookmark)
        }
    }

    /// Shared folder picker: directories only, single selection. The
    /// bookmark is created in the completion so AppKit panel APIs never
    /// leave the View layer (task DoD 2).
    private func presentFolderPicker(completion: @escaping (URL, Data) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择要添加的本地文件夹"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let bookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                completion(url, bookmark)
            } catch {
                self?.presentFolderPickerError(error)
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func presentFolderPickerError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "添加本地文件夹失败"
        alert.informativeText = "无法为该文件夹创建访问书签：\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if let window = view.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    /// Return-activation counterpart of the mouse single click.
    private func activateSelectedServer() {
        connect(row: tableView.selectedRow)
    }

    /// Single highlight invariant (2026-09-12 acceptance: no double
    /// highlight): a pinned bottom-bar destination on screen clears the
    /// table's selection capsule; a local-folder destination selects its
    /// own row instead (the bar has no row for it); server destinations
    /// keep the clicked row selected. A removed-while-browsed folder has
    /// no row left, so its stale destination simply unselects.
    private func syncTableSelection() {
        switch viewModel.activeDestination {
        case .none:
            break
        case .localFolder(let id):
            if let row = viewModel.tableRow(forLocalFolderID: id) {
                if tableView.selectedRow != row {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            } else {
                tableView.deselectAll(nil)
            }
        case .home, .vault, .settings:
            tableView.deselectAll(nil)
        }
    }

    /// Single highlight invariant: the bar's destination capsule only
    /// shows while the table has no selection — a keyboard-driven
    /// selection (which never connects) masks the bar instead of
    /// doubling the highlight.
    private func syncBarHighlight() {
        let masked = tableView.selectedRow >= 0
        bottomBar.setActiveDestination(masked ? .none : viewModel.activeDestination)
        bottomBar.setActivePin(masked ? nil : viewModel.activePinPath)
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

extension ServerListViewController: NSMenuDelegate {
    /// The context menu is rebuilt per click from the clicked row's kind:
    /// server rows offer endpoint-switch (only with a remote address,
    /// titled after the destination kind), edit, and delete; local-folder
    /// rows offer remove, plus a re-pick while the bookmark is invalid.
    /// Section headers and empty space get an empty menu (none shows).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        if let server = viewModel.server(atTableRow: row) {
            if server.remoteHost != nil {
                let title = server.activeEndpoint == .remote ? "切换到局域网地址" : "切换到远程地址"
                menu.addItem(makeMenuItem(title: title, action: #selector(handleSwitchEndpoint)))
            }
            menu.addItem(makeMenuItem(title: "编辑…", action: #selector(handleEdit)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: "删除", action: #selector(handleRemove)))
        } else if let folder = viewModel.localFolder(atTableRow: row) {
            if !folder.isAvailable {
                menu.addItem(makeMenuItem(title: "重新选择…", action: #selector(handleRepickLocalFolder)))
            }
            menu.addItem(makeMenuItem(title: "移除", action: #selector(handleRemoveLocalFolder)))
        }
    }

    private func makeMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
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
            if viewModel.isLocalFolderHeaderRow(row) {
                return makeSectionHeaderCell(
                    in: tableView,
                    identifier: "LocalFolderHeaderCell",
                    title: "本地文件夹",
                    addAccessibility: "添加本地文件夹"
                ) { [weak self] in self?.handleAddLocalFolder() }
            }
            return makeSectionHeaderCell(
                in: tableView,
                identifier: "ServerHeaderCell",
                title: "服务器",
                addAccessibility: "添加服务器"
            ) { [weak self] in self?.handleAdd() }
        }
        if let folder = viewModel.localFolder(atTableRow: row) {
            let identifier = NSUserInterfaceItemIdentifier("LocalFolderCell")
            let cell: LocalFolderRowCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? LocalFolderRowCellView {
                cell = reused
            } else {
                cell = LocalFolderRowCellView()
                cell.identifier = identifier
            }
            cell.configure(with: folder)
            return cell
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

    /// Section header cell from the reuse pool, configured with the
    /// section's title and add intent. The cell owns its button so both
    /// sections ("服务器" / "本地文件夹") share the one layout.
    private func makeSectionHeaderCell(
        in tableView: NSTableView,
        identifier: String,
        title: String,
        addAccessibility: String,
        onAdd: @escaping () -> Void
    ) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(identifier)
        let cell: SectionHeaderCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SectionHeaderCellView {
            cell = reused
        } else {
            cell = SectionHeaderCellView()
            cell.identifier = identifier
        }
        cell.configure(title: title, addAccessibility: addAccessibility, onAdd: onAdd)
        return cell
    }
}

/// One sidebar section header: a small gray label with a trailing add
/// button, in the spirit of Notes' sidebar section headers. Owns its add
/// button so each section wires its own intent.
@MainActor
private final class SectionHeaderCellView: NSTableCellView {
    private let addButton = NSButton()
    private var onAdd: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let textField = NSTextField(labelWithString: "")
        textField.font = CoveStyle.sectionHeaderFont
        textField.textColor = .secondaryLabelColor
        addSubview(textField)
        self.textField = textField

        addButton.isBordered = false
        addButton.imagePosition = .imageOnly
        addButton.title = ""
        addButton.focusRingType = .none
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(handleAdd)
        addSubview(addButton)

        textField.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(CoveStyle.space4)
            make.centerY.equalToSuperview()
        }
        addButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(CoveStyle.space4)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, addAccessibility: String, onAdd: @escaping () -> Void) {
        textField?.stringValue = title
        addButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: addAccessibility
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolSmall, weight: .medium)
        )
        self.onAdd = onAdd
    }

    @objc private func handleAdd() {
        onAdd?()
    }
}

/// One local-folder row: a folder symbol and the folder name. An
/// unresolved bookmark greys the row out (secondary label color) to
/// signal the re-pick path in its context menu.
@MainActor
private final class LocalFolderRowCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolMedium, weight: .regular))
        iconView.contentTintColor = .labelColor

        nameLabel.font = CoveStyle.bodyFont
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(iconView)
        addSubview(nameLabel)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(CoveStyle.space6)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(18)
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

    func configure(with folder: LocalFolderRow) {
        nameLabel.stringValue = folder.name
        let color: NSColor = folder.isAvailable ? .labelColor : .secondaryLabelColor
        nameLabel.textColor = color
        iconView.contentTintColor = color
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
