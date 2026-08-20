import AppKit
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        backButton.bezelStyle = .rounded
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.target = self
        backButton.action = #selector(handleGoUp)
        backButton.isEnabled = false
        backButton.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(backButton)
        root.addSubview(pathLabel)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),

            pathLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    /// Replaces the listing. Items are shown directories-first, then by name.
    /// `.DS_Store` and AppleDouble (`._`-prefixed) files are hidden.
    func display(items: [ContentItem], path: String) {
        self.items = items
            .filter { Self.isVisible($0) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        pathLabel.stringValue = path
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
                imageView.translatesAutoresizingMaskIntoConstraints = false
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(imageView)
                cell.addSubview(textField)
                cell.imageView = imageView
                cell.textField = textField
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
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
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        return cell
    }
}
