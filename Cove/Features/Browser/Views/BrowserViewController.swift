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
    var onOpenPdf: ((_ path: String) -> Void)?
    var onUnsupportedFile: ((_ name: String) -> Void)?
    var onGoUp: (() -> Void)?
    var onPreheatTapped: (() -> Void)?
    /// Right-click intents; the row's item is resolved by the coordinator's
    /// wiring, both via `contextMenuIntent(mode:clickedRow:items:)`.
    var onDownloadToVault: ((ContentItem) -> Void)?
    var onDeleteFromVault: ((ContentItem) -> Void)?
    var onCancelDownload: (() -> Void)?

    /// Which set of right-click actions the listing offers. Remote
    /// browsing offers "下载到本地仓库"; vault browsing offers
    /// "从本地仓库删除". Set by the coordinator.
    enum BrowseMode: Sendable {
        case remote
        case vault
    }

    var browseMode: BrowseMode = .remote

    /// The single right-click action a row offers in `mode`, if the row is
    /// valid. Pure and static so the menu wiring is unit-testable.
    enum ContextMenuIntent: Equatable {
        case downloadToVault(ContentItem)
        case deleteFromVault(ContentItem)
    }

    static func contextMenuIntent(
        mode: BrowseMode, clickedRow: Int, items: [ContentItem]
    ) -> ContextMenuIntent? {
        guard items.indices.contains(clickedRow) else { return nil }
        let item = items[clickedRow]
        switch mode {
        case .remote: return .downloadToVault(item)
        case .vault: return .deleteFromVault(item)
        }
    }

    /// Real-thumbnail loader for image rows, injected by the coordinator
    /// once a share is connected; nil means "keep the symbol badges".
    var thumbnailProvider: (any ThumbnailProviding)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let toolbarView = NSView()
    private let backButton = NSButton()
    private let preheatButton = NSButton()
    private let preheatProgressLabel = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let downloadLabel = NSTextField(labelWithString: "")
    private let downloadCancelButton = NSButton()

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Shared date formatter for the row subtitle ("2025/11/18") — formatters
    /// are expensive, so rows never create their own.
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d"
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

        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Download-to-vault progress at the trailing edge: a gray label
        // ("下载到本地仓库 3/12 · name"), plus a stop button while running.
        downloadLabel.font = .systemFont(ofSize: 11)
        downloadLabel.textColor = .secondaryLabelColor
        downloadLabel.lineBreakMode = .byTruncatingMiddle
        downloadLabel.isHidden = true
        downloadCancelButton.bezelStyle = .circular
        downloadCancelButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "取消下载"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        downloadCancelButton.imagePosition = .imageOnly
        downloadCancelButton.title = ""
        downloadCancelButton.toolTip = "取消下载"
        downloadCancelButton.target = self
        downloadCancelButton.action = #selector(handleCancelDownload)
        downloadCancelButton.isHidden = true

        toolbarView.addSubview(backButton)
        toolbarView.addSubview(preheatButton)
        toolbarView.addSubview(preheatProgressLabel)
        toolbarView.addSubview(locationLabel)
        toolbarView.addSubview(downloadLabel)
        toolbarView.addSubview(downloadCancelButton)
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
        locationLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualTo(preheatProgressLabel.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualTo(downloadLabel.snp.leading).offset(-8)
        }
        downloadLabel.snp.makeConstraints { make in
            make.trailing.equalTo(downloadCancelButton.snp.leading).offset(-6)
            make.centerY.equalToSuperview()
            make.width.lessThanOrEqualTo(320)
        }
        downloadCancelButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-20)
            make.centerY.equalToSuperview()
            make.size.equalTo(20)
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

        // Right-click menu: rebuilt per click by menuNeedsUpdate from
        // `contextMenuIntent`, so remote rows offer the vault download and
        // vault rows offer local delete — never both.
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

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
        locationLabel.attributedStringValue = Self.locationText(path: state.path, title: state.title)
        locationLabel.toolTip = state.path
        backButton.isEnabled = state.canGoUp
        renderPreheat(state.preheat)
        renderDownload(state.download)
        tableView.reloadData()
    }

    /// One label for location: gray parent chain + semibold current name.
    /// Showing the raw path and the title separately duplicated the last
    /// path component.
    static func locationText(path: String, title: String) -> NSAttributedString {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let parentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        // At the share root the title stands alone; deeper, the parents
        // lead in gray.
        let parents = components.dropLast()
        let text = NSMutableAttributedString()
        if !parents.isEmpty {
            text.append(NSAttributedString(
                string: parents.joined(separator: " / ") + " / ",
                attributes: parentAttributes
            ))
        }
        text.append(NSAttributedString(string: title, attributes: titleAttributes))
        return text
    }

    private func renderDownload(_ download: BrowserViewModel.DownloadState?) {
        switch download {
        case .none:
            downloadLabel.isHidden = true
            downloadCancelButton.isHidden = true
        case .running(let completed, let total, let file):
            downloadLabel.isHidden = false
            downloadCancelButton.isHidden = false
            downloadLabel.stringValue = total > 0
                ? "下载到本地仓库 \(completed)/\(total) · \(file)"
                : "下载到本地仓库…"
        case .finished(let summary):
            downloadLabel.isHidden = false
            downloadCancelButton.isHidden = true
            downloadLabel.stringValue = summary
        }
    }

    @objc private func handleCancelDownload() {
        onCancelDownload?()
    }

    @objc private func handleContextMenuAction(_ sender: NSMenuItem) {
        guard let intent = Self.contextMenuIntent(
            mode: browseMode, clickedRow: tableView.clickedRow, items: viewModel.state.items
        ) else { return }
        switch intent {
        case .downloadToVault(let item):
            onDownloadToVault?(item)
        case .deleteFromVault(let item):
            onDeleteFromVault?(item)
        }
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
        } else if item.fileType == .pdf {
            onOpenPdf?(item.path)
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
        // 48-pt thumbnail + 8 pt of breathing room above and below.
        64
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
            subtitle: subtitleText(for: item),
            thumbnailProvider: thumbnailProvider
        )
        return cell
    }

    /// Row subtitle: files show "size · modified date", directories just
    /// "文件夹". A file without a modification date shows only its size.
    private func subtitleText(for item: ContentItem) -> String {
        if item.isDirectory { return "文件夹" }
        let size = byteFormatter.string(fromByteCount: item.size)
        guard let modifiedDate = item.modifiedDate else { return size }
        return "\(size) · \(dateFormatter.string(from: modifiedDate))"
    }
}

/// One directory-entry row: a 48-pt rounded thumbnail (or a monochrome
/// symbol placeholder) on the leading edge, and two text lines — the file
/// name (tail-truncated) over a metadata subtitle.
///
/// Image rows replace the placeholder symbol with the real thumbnail once it
/// arrives (fade-in over the placeholder). The thumbnail loads async via the
/// injected `ThumbnailService`; row reuse cancels the pending request, so
/// off-screen rows never decode.
@MainActor
private final class BrowserRowCellView: NSTableCellView {
    private let badgeView = RoundedFillView()
    private let badgeImageView = NSImageView()
    private let thumbnailImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    /// In-flight thumbnail request for the currently shown item.
    private var thumbnailTask: Task<Void, Never>?
    /// Path of the item the cell currently shows; guards against applying a
    /// thumbnail to a row that has since been reused for another file.
    private var currentPath: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        badgeView.cornerRadius = CoveStyle.radiusSmall
        // Clip the thumbnail image to the badge's rounded corners.
        badgeView.layer?.masksToBounds = true

        // The thumbnail is stored center-cropped to a square, so a plain
        // proportional NSImageView fills the badge exactly. The badge clips
        // it to the corner radius.
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.isHidden = true

        nameLabel.font = CoveStyle.titleFont
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = CoveStyle.captionFont
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        addSubview(badgeView)
        badgeView.addSubview(badgeImageView)
        badgeView.addSubview(thumbnailImageView)
        addSubview(nameLabel)
        addSubview(subtitleLabel)
        badgeView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(48)
        }
        badgeImageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        thumbnailImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        // The two text lines sit as a pair centered on the row: the name
        // ends just above the midpoint, the subtitle starts just below.
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(badgeView.snp.trailing).offset(12)
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
            make.bottom.equalTo(self.snp.centerY).offset(-2)
        }
        subtitleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(nameLabel)
            make.top.equalTo(self.snp.centerY).offset(2)
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

    func configure(with item: ContentItem, subtitle: String, thumbnailProvider: (any ThumbnailProviding)?) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        currentPath = item.path

        // Placeholders stay monochrome so the loaded thumbnail is the only
        // saturated element on the row.
        badgeImageView.image = NSImage(systemSymbolName: Self.placeholderSymbol(for: item), accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        badgeImageView.contentTintColor = .tertiaryLabelColor
        badgeImageView.isHidden = false
        thumbnailImageView.image = nil
        thumbnailImageView.isHidden = true
        nameLabel.stringValue = item.name
        subtitleLabel.stringValue = subtitle

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

    /// Placeholder symbol per file kind. Directories always show a folder;
    /// image rows keep `photo` until the real thumbnail fades in.
    private static func placeholderSymbol(for item: ContentItem) -> String {
        if item.isDirectory { return "folder.fill" }
        switch item.fileType ?? .other {
        case .video: return "film.fill"
        case .image: return "photo"
        case .pdf: return "doc.richtext.fill"
        case .comic: return "books.closed.fill"
        case .text: return "doc.text.fill"
        case .other: return "doc.fill"
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

extension BrowserViewController: NSMenuDelegate {
    /// Builds the right-click menu on demand: exactly one item, chosen by
    /// `contextMenuIntent` from the browse mode and clicked row. An empty
    /// menu (header/empty space) simply does not appear.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let intent = Self.contextMenuIntent(
            mode: browseMode, clickedRow: tableView.clickedRow, items: viewModel.state.items
        ) else { return }
        let title: String
        switch intent {
        case .downloadToVault:
            title = "下载到本地仓库"
        case .deleteFromVault:
            title = "从本地仓库删除…"
        }
        let menuItem = NSMenuItem(
            title: title, action: #selector(handleContextMenuAction(_:)), keyEquivalent: ""
        )
        menuItem.target = self
        menu.addItem(menuItem)
    }
}
