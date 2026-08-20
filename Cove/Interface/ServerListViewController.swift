import AppKit

/// Left pane: the persisted server list plus an add button.
/// Row 0 is a section header; servers start at row 1.
/// Pure UI — events are forwarded to `MainWindowController` via closures.
@MainActor
final class ServerListViewController: NSViewController {
    var onAddServer: (() -> Void)?
    var onConnect: ((ServerConfig) -> Void)?

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

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(handleAdd)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(addButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

            addButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

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
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
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
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = server.displayName
        return cell
    }
}
