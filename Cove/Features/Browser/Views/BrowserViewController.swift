import AppKit
import SnapKit
import SourceKit

/// Browser feature view: directory listing of the connected share, rendered as
/// card-style rows under a toolbar.
/// Pure UI — navigation and file-open intents are forwarded via closures.
/// The back button means "up one directory", or "back to the share grid"
/// at the share root; the coordinator decides.
@MainActor
final class BrowserViewController: NSViewController {
    private let viewModel: BrowserViewModel

    var onOpenDirectory: ((_ path: String) -> Void)?
    var onOpenImage: ((_ path: String) -> Void)?
    var onOpenComic: ((_ path: String) -> Void)?
    var onOpenVideo: ((_ path: String) -> Void)?
    var onUnsupportedFile: ((_ name: String) -> Void)?
    var onGoUp: (() -> Void)?
    var onPreheatTapped: (() -> Void)?

    /// Real-thumbnail loader for image rows, injected by the coordinator
    /// once a share is connected; nil means "keep the symbol badges".
    var thumbnailProvider: (any ThumbnailProviding)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let toolbarView = NSView()
    private let backButton = NSButton()
    private let preheatButton = NSButton()
    private let preheatProgressLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        bindViewModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

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

        // "Preheat this folder" button: downloads the current directory's
        // images (one level) into the cache in the background. Its state
        // (idle / running with N/M progress / finished) is VM-driven.
        preheatButton.bezelStyle = .circular
        preheatButton.imagePosition = .imageOnly
        preheatButton.title = ""
        preheatButton.target = self
        preheatButton.action = #selector(handlePreheatTapped)
        preheatButton.isEnabled = false
        preheatButton.setContentHuggingPriority(.required, for: .horizontal)

        preheatProgressLabel.font = .systemFont(ofSize: 11)
        preheatProgressLabel.textColor = .secondaryLabelColor
        preheatProgressLabel.isHidden = true
        preheatProgressLabel.setContentHuggingPriority(.required, for: .horizontal)

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
        toolbarView.addSubview(preheatButton)
        toolbarView.addSubview(preheatProgressLabel)
        toolbarView.addSubview(pathLabel)
        toolbarView.addSubview(titleLabel)
        toolbarView.addSubview(searchField)
        backButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        preheatButton.snp.makeConstraints { make in
            make.leading.equalTo(backButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(28)
        }
        preheatProgressLabel.snp.makeConstraints { make in
            make.leading.equalTo(preheatButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
        }
        pathLabel.snp.makeConstraints { make in
            make.leading.equalTo(preheatProgressLabel.snp.trailing).offset(8)
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

    private func bindViewModel() {
        viewModel.onStateChange = { [weak self] state in
            self?.render(state)
        }
    }

    private func render(_ state: BrowserViewModel.State) {
        loadViewIfNeeded()
        titleLabel.stringValue = state.title
        pathLabel.stringValue = state.path
        pathLabel.toolTip = state.path
        backButton.isEnabled = state.canGoUp
        renderPreheat(state.preheat)
        tableView.reloadData()
    }

    private func renderPreheat(_ preheat: BrowserViewModel.PreheatButtonState) {
        switch preheat {
        case .unavailable:
            preheatButton.isEnabled = false
            preheatButton.image = preheatSymbol("arrow.down.circle", description: "预热此文件夹（含子文件夹）")
            preheatButton.toolTip = "预热此文件夹（含子文件夹）"
            preheatProgressLabel.stringValue = ""
            preheatProgressLabel.isHidden = true
        case .ready:
            preheatButton.isEnabled = true
            preheatButton.image = preheatSymbol("arrow.down.circle", description: "预热此文件夹（含子文件夹）")
            preheatButton.toolTip = "预热此文件夹（含子文件夹）"
            preheatProgressLabel.stringValue = ""
            preheatProgressLabel.isHidden = true
        case .preheating(let completed, let total, let bytesPerSecond):
            preheatButton.isEnabled = true
            preheatButton.image = preheatSymbol("stop.circle", description: "取消预热")
            preheatButton.toolTip = "取消预热"
            preheatProgressLabel.isHidden = false
            if total > 0 {
                let rate = byteFormatter.string(fromByteCount: Int64(bytesPerSecond))
                preheatProgressLabel.stringValue = "预热中 \(completed)/\(total) · \(rate)/s"
            } else {
                // Still enumerating the directory.
                preheatProgressLabel.stringValue = "预热中…"
            }
        case .finished(let failed, let truncatedAtCap):
            preheatButton.isEnabled = true
            preheatButton.image = preheatSymbol("checkmark.circle", description: "预热完成")
            preheatProgressLabel.isHidden = false
            var notes: [String] = []
            if let cap = truncatedAtCap {
                notes.append("已达 \(cap) 张上限")
            }
            if failed > 0 {
                notes.append("\(failed) 个失败")
            }
            let text = notes.isEmpty ? "预热完成" : "预热完成（\(notes.joined(separator: "，"))）"
            preheatButton.toolTip = text
            preheatProgressLabel.stringValue = text
        }
    }

    private func preheatSymbol(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    }

    @objc private func handleGoUp() {
        onGoUp?()
    }

    @objc private func handlePreheatTapped() {
        onPreheatTapped?()
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        let items = viewModel.state.items
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item.isDirectory {
            onOpenDirectory?(item.path)
        } else if item.fileType == .image {
            onOpenImage?(item.path)
        } else if item.fileType == .comic {
            onOpenComic?(item.path)
        } else if item.fileType == .video {
            onOpenVideo?(item.path)
        } else {
            onUnsupportedFile?(item.name)
        }
    }
}

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.state.items.count
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
        let item = viewModel.state.items[row]
        cell.configure(
            with: item,
            sizeText: item.isDirectory ? "--" : byteFormatter.string(fromByteCount: item.size),
            thumbnailProvider: thumbnailProvider
        )
        return cell
    }
}

/// One directory-entry row: a rounded icon badge, the file name (tail-
/// truncated), and the file size pinned to the trailing edge.
///
/// Image rows replace the badge's SF Symbol with the real thumbnail once it
/// arrives (fade-in over the symbol placeholder). The thumbnail loads async
/// via the injected `ThumbnailService`; row reuse cancels the pending
/// request, so off-screen rows never decode.
@MainActor
private final class BrowserRowCellView: NSTableCellView {
    private let badgeView = RoundedFillView()
    private let badgeImageView = NSImageView()
    private let thumbnailImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")

    /// In-flight thumbnail request for the currently shown item.
    private var thumbnailTask: Task<Void, Never>?
    /// Path of the item the cell currently shows; guards against applying a
    /// thumbnail to a row that has since been reused for another file.
    private var currentPath: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        badgeView.cornerRadius = 8
        // Clip the thumbnail image to the badge's rounded corners.
        badgeView.layer?.masksToBounds = true

        // The thumbnail is stored center-cropped to a square, so a plain
        // proportional NSImageView fills the badge exactly. The badge clips
        // it to the 8-pt corner radius.
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.isHidden = true

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
        badgeView.addSubview(thumbnailImageView)
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
        thumbnailImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
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

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        currentPath = nil
    }

    func configure(with item: ContentItem, sizeText: String, thumbnailProvider: (any ThumbnailProviding)?) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        currentPath = item.path

        let style = Self.iconStyle(for: item)
        badgeImageView.image = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        badgeImageView.contentTintColor = style.tint
        badgeImageView.isHidden = false
        thumbnailImageView.image = nil
        thumbnailImageView.isHidden = true
        nameLabel.stringValue = item.name
        sizeLabel.stringValue = sizeText

        // Image rows swap the symbol for the real thumbnail once loaded.
        guard let thumbnailProvider, item.fileType == .image else { return }
        let path = item.path
        thumbnailTask = Task { [weak self] in
            let thumbnail = await thumbnailProvider.thumbnail(for: item)
            guard let self, !Task.isCancelled, self.currentPath == path, let thumbnail else { return }
            self.showThumbnail(thumbnail)
        }
    }

    /// Fades the loaded thumbnail in over the symbol placeholder.
    private func showThumbnail(_ image: CGImage) {
        thumbnailImageView.image = NSImage(cgImage: image, size: .zero)
        thumbnailImageView.alphaValue = 0
        thumbnailImageView.isHidden = false
        badgeImageView.isHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            thumbnailImageView.animator().alphaValue = 1
        }
    }

    /// Symbol and tint per file kind, following the app's badge palette.
    private static func iconStyle(for item: ContentItem) -> (symbolName: String, tint: NSColor) {
        if item.isDirectory { return ("folder.fill", .systemBlue) }
        switch item.fileType ?? .other {
        case .video: return ("film.fill", .systemPurple)
        case .image: return ("photo.fill", .systemGreen)
        case .pdf: return ("doc.richtext.fill", .systemRed)
        case .comic: return ("books.closed.fill", .systemOrange)
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
