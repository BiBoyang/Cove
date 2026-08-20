import AppKit
import SnapKit
import SourceKit

/// Right pane: directory listing of the connected share, rendered as
/// card-style rows under a toolbar.
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
    private let toolbarView = NSView()
    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    override func loadView() {
        let root = NSView()

        // Toolbar: circular back button, the full path in small gray text,
        // the current directory name centered, and a disabled search field
        // reserving the slot for future filtering.
        backButton.bezelStyle = .circular
        backButton.image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: "返回"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        backButton.imagePosition = .imageOnly
        backButton.title = ""
        backButton.target = self
        backButton.action = #selector(handleGoUp)
        backButton.isEnabled = false
        backButton.setContentHuggingPriority(.required, for: .horizontal)

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        searchField.placeholderString = "搜索"
        searchField.isEnabled = false

        toolbarView.addSubview(backButton)
        toolbarView.addSubview(pathLabel)
        toolbarView.addSubview(titleLabel)
        toolbarView.addSubview(searchField)
        backButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        pathLabel.snp.makeConstraints { make in
            make.leading.equalTo(backButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
        }
        titleLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualTo(pathLabel.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualTo(searchField.snp.leading).offset(-8)
        }
        searchField.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-20)
            make.centerY.equalToSuperview()
            make.width.equalTo(160)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = 600
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.intercellSpacing = .zero
        tableView.focusRingType = .none

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        root.addSubview(toolbarView)
        root.addSubview(scrollView)
        toolbarView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(44)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(toolbarView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        view = root
    }

    /// Replaces the listing. Items are shown directories-first, then by name.
    /// `.DS_Store` and AppleDouble (`._`-prefixed) files are hidden.
    /// `title` is the short name centered in the toolbar (the share name at
    /// the share root); `path` is shown in full as secondary text.
    func display(items: [ContentItem], path: String, title: String) {
        self.items = items
            .filter { Self.isVisible($0) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        titleLabel.stringValue = title
        pathLabel.stringValue = path
        pathLabel.toolTip = path
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
}

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        52
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("BrowserRowCell")
        let cell: BrowserRowCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserRowCellView {
            cell = reused
        } else {
            cell = BrowserRowCellView()
            cell.identifier = identifier
        }
        let item = items[row]
        cell.configure(
            with: item,
            sizeText: item.isDirectory ? "--" : byteFormatter.string(fromByteCount: item.size)
        )
        return cell
    }
}

/// One directory-entry row: a rounded icon badge, the file name (tail-
/// truncated), and the file size pinned to the trailing edge.
@MainActor
private final class BrowserRowCellView: NSTableCellView {
    private let badgeView = RoundedFillView()
    private let badgeImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        badgeView.cornerRadius = 8

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(badgeView)
        badgeView.addSubview(badgeImageView)
        addSubview(nameLabel)
        addSubview(sizeLabel)
        badgeView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(40)
        }
        badgeImageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        sizeLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-20)
            make.centerY.equalToSuperview()
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(badgeView.snp.trailing).offset(12)
            make.trailing.lessThanOrEqualTo(sizeLabel.snp.leading).offset(-8)
            make.centerY.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with item: ContentItem, sizeText: String) {
        let style = Self.iconStyle(for: item)
        badgeImageView.image = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        badgeImageView.contentTintColor = style.tint
        nameLabel.stringValue = item.name
        sizeLabel.stringValue = sizeText
    }

    /// Symbol and tint per file kind, following the app's badge palette.
    private static func iconStyle(for item: ContentItem) -> (symbolName: String, tint: NSColor) {
        if item.isDirectory { return ("folder.fill", .systemBlue) }
        switch item.fileType ?? .other {
        case .video: return ("film.fill", .systemPurple)
        case .image: return ("photo.fill", .systemGreen)
        case .pdf: return ("doc.richtext.fill", .systemRed)
        case .text: return ("doc.text.fill", .systemGray)
        case .other: return ("doc.fill", .systemGray)
        }
    }
}

/// Row view that draws the selection as an inset rounded rect instead of
/// the default edge-to-edge highlight.
@MainActor
private final class RoundedSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let color = isEmphasized
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}
