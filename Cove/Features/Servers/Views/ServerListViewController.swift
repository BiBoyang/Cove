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

    @objc private func handleRemove() {
        let row = tableView.clickedRow
        guard let server = viewModel.server(atTableRow: row) else { return }
        onRemove?(server)
    }
}

extension ServerListViewController: NSMenuItemValidation {
    /// "删除" only applies to actual server rows — not the section header
    /// (row 0) and not empty space below the list.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let row = tableView.clickedRow
        return viewModel.server(atTableRow: row) != nil
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
/// clean sidebar (no badge chrome).
@MainActor
private final class ServerRowCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconView.contentTintColor = .labelColor

        nameLabel.font = CoveStyle.bodyFont
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(iconView)
        addSubview(nameLabel)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(6)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(18)
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
    }

    /// Generic icon + title content (the vault row uses it too).
    func configure(symbol: String, title: String, tint: NSColor) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconView.contentTintColor = tint
        nameLabel.stringValue = title
    }
}
