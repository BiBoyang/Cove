import AppKit
import SnapKit

/// Left pane: the persisted server list plus an add button.
/// Row 0 is a section header; servers start at row 1.
/// Pure UI — events are forwarded to `MainWindowController` via closures.
@MainActor
final class ServerListViewController: NSViewController {
    var onAddServer: (() -> Void)?
    var onConnect: ((ServerConfig) -> Void)?
    var onRemove: ((ServerConfig) -> Void)?

    private var servers: [ServerConfig] = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton(title: "添加服务器", target: nil, action: nil)

    override func loadView() {
        let root = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
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

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(handleAdd)

        root.addSubview(scrollView)
        root.addSubview(addButton)
        scrollView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(addButton.snp.top).offset(-8)
        }
        addButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.bottom.equalToSuperview().offset(-8)
        }

        view = root
    }

    func reload(servers: [ServerConfig]) {
        self.servers = servers
        tableView.reloadData()
    }

    @objc private func handleAdd() {
        onAddServer?()
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 1, row - 1 < servers.count else { return }
        onConnect?(servers[row - 1])
    }

    @objc private func handleRemove() {
        let row = tableView.clickedRow
        guard row >= 1, row - 1 < servers.count else { return }
        onRemove?(servers[row - 1])
    }
}

extension ServerListViewController: NSMenuItemValidation {
    /// "删除" only applies to actual server rows — not the section header
    /// (row 0) and not empty space below the list.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let row = tableView.clickedRow
        return row >= 1 && row - 1 < servers.count
    }
}

extension ServerListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        servers.count + 1
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        row == 0
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row != 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == 0 {
            return makeHeaderCell(in: tableView)
        }
        return makeServerCell(in: tableView, server: servers[row - 1])
    }

    /// Section header: small gray label, in the spirit of Finder's sidebar.
    private func makeHeaderCell(in tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("ServerHeaderCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.font = .systemFont(ofSize: 11, weight: .semibold)
            textField.textColor = .secondaryLabelColor
            cell.addSubview(textField)
            cell.textField = textField
            textField.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
        }
        cell.textField?.stringValue = "服务器"
        return cell
    }

    private func makeServerCell(in tableView: NSTableView, server: ServerConfig) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("ServerCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField
            textField.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
        }
        cell.textField?.stringValue = server.displayName
        return cell
    }
}
