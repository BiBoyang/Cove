import AppKit
import SnapKit

/// Servers feature sidebar: the persisted server list plus an add button.
/// Row 0 is a section header; servers start at row 1.
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

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    /// Section-header add button, Notes-style: a small plus at the
    /// trailing edge of the "服务器" group row.
    private let headerAddButton = NSButton()

    init(viewModel: ServerListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        viewModel.onStateChange = { [weak self] _ in
            self?.loadViewIfNeeded()
            self?.tableView.reloadData()
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
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        view = root
    }

    @objc private func handleAdd() {
        onAddServer?()
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        if viewModel.isVaultRow(row) {
            onOpenVault?()
            return
        }
        guard let server = viewModel.server(atTableRow: row) else { return }
        onConnect?(server)
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

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // Sidebar rhythm: tight 20pt group headers, 32pt rows.
        viewModel.isGroupRow(row) ? 20 : 32
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == 0 {
            return makeHeaderCell(in: tableView)
        }
        if viewModel.isGroupRow(row) {
            return makeVaultHeaderCell(in: tableView)
        }
        let identifier = NSUserInterfaceItemIdentifier("ServerCell")
        let cell: ServerRowCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ServerRowCellView {
            cell = reused
        } else {
            cell = ServerRowCellView()
            cell.identifier = identifier
        }
        if viewModel.isVaultRow(row) {
            cell.configure(symbol: "externaldrive.fill", title: "本地仓库", tint: CoveStyle.accentGold)
        } else if let server = viewModel.server(atTableRow: row) {
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
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            headerAddButton.contentTintColor = .secondaryLabelColor
            headerAddButton.imagePosition = .imageOnly
            headerAddButton.title = ""
            headerAddButton.focusRingType = .none
            headerAddButton.target = self
            headerAddButton.action = #selector(handleAdd)
            cell.addSubview(headerAddButton)

            textField.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
            headerAddButton.snp.makeConstraints { make in
                make.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
                make.size.equalTo(16)
            }
        }
        cell.textField?.stringValue = "服务器"
        return cell
    }

    /// The "本地" group header: same look as the servers header, without
    /// the add button.
    private func makeVaultHeaderCell(in tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("VaultHeaderCell")
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
            textField.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
        }
        cell.textField?.stringValue = "本地"
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
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconView.contentTintColor = .labelColor

        nameLabel.font = CoveStyle.bodyFont
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle

        endpointTagLabel.font = .systemFont(ofSize: 10, weight: .medium)
        endpointTagLabel.textColor = .secondaryLabelColor
        endpointTagLabel.isHidden = true
        endpointTagLabel.setContentHuggingPriority(.required, for: .horizontal)
        endpointTagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(endpointTagLabel)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(6)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(18)
        }
        endpointTagLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-6)
            make.centerY.equalToSuperview()
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-4)
            make.centerY.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with server: ServerConfig) {
        configure(symbol: "server.rack", title: server.displayName, tint: .labelColor)
        // The LAN default stays unmarked (clean sidebar); only the remote
        // endpoint earns the tag, so reuse has to be able to drop it again.
        let showsRemoteTag = server.activeEndpoint == .remote && server.remoteHost != nil
        endpointTagLabel.isHidden = !showsRemoteTag
        nameLabel.snp.remakeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            if showsRemoteTag {
                make.trailing.lessThanOrEqualTo(endpointTagLabel.snp.leading).offset(-6)
            } else {
                make.trailing.equalToSuperview().offset(-4)
            }
        }
    }

    /// Generic icon + title content (the vault row uses it too).
    func configure(symbol: String, title: String, tint: NSColor) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconView.contentTintColor = tint
        nameLabel.stringValue = title
    }
}
