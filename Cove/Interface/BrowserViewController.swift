import AppKit
import SnapKit
import SourceKit

/// Right pane: directory listing of the connected share.
/// Pure UI — navigation and file-open intents are forwarded via closures.
/// The back button means "up one directory", or "back to the share grid"
/// at the share root; the coordinator decides.
@MainActor
final class BrowserViewController: NSViewController {
    var onOpenDirectory: ((_ path: String) -> Void)?
    var onOpenImage: ((_ path: String, _ name: String) -> Void)?
    var onGoUp: (() -> Void)?

    private var items: [ContentItem] = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let backButton = NSButton(title: "返回", target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        let root = NSView()

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "名称"
        nameColumn.width = 300
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "大小"
        sizeColumn.width = 100
        let modifiedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modifiedColumn.title = "修改时间"
        modifiedColumn.width = 180
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(modifiedColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        backButton.bezelStyle = .rounded
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.target = self
        backButton.action = #selector(handleGoUp)
        backButton.isEnabled = false

        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.textColor = .secondaryLabelColor

        root.addSubview(backButton)
        root.addSubview(pathLabel)
        root.addSubview(scrollView)
        backButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(8)
            make.leading.equalToSuperview().offset(8)
        }
        pathLabel.snp.makeConstraints { make in
            make.centerY.equalTo(backButton)
            make.leading.equalTo(backButton.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-8)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(backButton.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview()
        }

        view = root
    }

    /// Replaces the listing. Items are shown directories-first, then by name.
    /// `.DS_Store` and AppleDouble (`._`-prefixed) files are hidden.
    /// At the share root the back button leads to the share grid, so it is
    /// labelled accordingly.
    func display(items: [ContentItem], path: String, isAtShareRoot: Bool) {
        self.items = items
            .filter { Self.isVisible($0) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        pathLabel.stringValue = path
        backButton.title = isAtShareRoot ? "共享列表" : "返回"
        backButton.isEnabled = true
        tableView.reloadData()
    }

    /// macOS metadata noise that never makes sense in a NAS browser.
    private static func isVisible(_ item: ContentItem) -> Bool {
        item.name != ".DS_Store" && !item.name.hasPrefix("._")
    }

    @objc private func handleGoUp() {
        onGoUp?()
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item.isDirectory {
            onOpenDirectory?(item.path)
        } else if item.fileType == .image {
            onOpenImage?(item.path, item.name)
        }
    }

    private func icon(for item: ContentItem) -> NSImage? {
        let symbolName: String
        if item.isDirectory {
            symbolName = "folder"
        } else {
            switch item.fileType ?? .other {
            case .video: symbolName = "film"
            case .image: symbolName = "photo"
            case .pdf: symbolName = "doc.richtext"
            case .text: symbolName = "doc.text"
            case .other: symbolName = "doc"
            }
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
}

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let item = items[row]

        switch column.identifier.rawValue {
        case "name":
            let identifier = NSUserInterfaceItemIdentifier("NameCell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let imageView = NSImageView()
                let textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(imageView)
                cell.addSubview(textField)
                cell.imageView = imageView
                cell.textField = textField
                imageView.snp.makeConstraints { make in
                    make.leading.equalToSuperview().offset(4)
                    make.centerY.equalToSuperview()
                    make.width.height.equalTo(16)
                }
                textField.snp.makeConstraints { make in
                    make.leading.equalTo(imageView.snp.trailing).offset(6)
                    make.trailing.equalToSuperview().offset(-4)
                    make.centerY.equalToSuperview()
                }
            }
            cell.imageView?.image = icon(for: item)
            cell.textField?.stringValue = item.name
            return cell

        case "size":
            let text = item.isDirectory ? "--" : byteFormatter.string(fromByteCount: item.size)
            return makeTextCell(in: tableView, identifier: "SizeCell", text: text)

        default: // "modified"
            let text = item.modifiedDate.map { dateFormatter.string(from: $0) } ?? ""
            return makeTextCell(in: tableView, identifier: "ModifiedCell", text: text)
        }
    }

    private func makeTextCell(in tableView: NSTableView, identifier: String, text: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let textField = NSTextField(labelWithString: "")
            cell.addSubview(textField)
            cell.textField = textField
            textField.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
        }
        cell.textField?.stringValue = text
        return cell
    }
}
