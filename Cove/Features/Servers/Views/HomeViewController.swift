import AppKit
import SnapKit
import SourceKit

/// The home destination: the continue-watching records as a vertical card
/// grid (Amendment 2 decision 1), with the two-level empty state over it.
/// Pure UI — resume intents are forwarded via `onResumeWatch`, the
/// first-run add action via `onAddServer`.
@MainActor
final class HomeViewController: NSViewController {
    private let viewModel: HomeViewModel

    /// Continue-watching card double-clicks, forwarded to the coordinator's
    /// resume deep link (decision 4).
    var onResumeWatch: ((RecentWatchEntry) -> Void)?
    /// Continue-watching card right-clicks: "打开所在文件夹" reveals the
    /// record's directory in the browser (TASK-player-ux-trio Step 3).
    var onRevealInBrowser: ((RecentWatchEntry) -> Void)?
    /// First-run empty-state action (add server), mapped from the state.
    var onAddServer: (() -> Void)?
    /// Read-only cover lookup for the cards (display pool only; a miss
    /// keeps the film icon — never generates). Injected by the coordinator.
    var thumbnailProvider: (any RecentWatchThumbnailProviding)?

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private var placeholderView: StatePlaceholderView?

    /// Persistent page title ("继续观看"): the home page is the watch
    /// history, and the sidebar's "首页" entry alone never says so. Stays
    /// visible in all three states — the placeholder pins its top to this
    /// label instead of covering the whole root.
    private let pageTitleLabel = NSTextField(labelWithString: "继续观看")

    init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        viewModel.onStateChange = { [weak self] state in
            self?.render(state)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        // Same warm dark content background as the other panes.
        root.wantsLayer = true
        root.layer?.backgroundColor = CoveStyle.libraryBackground.cgColor

        // Same grid recipe as the share grid (Amendment 2 decision 1):
        // 160x130 cards, spacing/sectionInset from the CoveStyle tokens.
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 160, height: 130)
        layout.minimumInteritemSpacing = CoveStyle.space14
        layout.minimumLineSpacing = CoveStyle.space16
        layout.sectionInset = NSEdgeInsets(
            top: CoveStyle.space20, left: CoveStyle.space20,
            bottom: CoveStyle.space20, right: CoveStyle.space20
        )

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            RecentWatchCardItem.self,
            forItemWithIdentifier: RecentWatchCardItem.identifier
        )

        // NSCollectionView has no doubleAction; a two-click recognizer on the
        // collection view plus hit-testing the item is the AppKit way.
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        // Right-click menu: rebuilt per click by menuNeedsUpdate — the
        // first item shows the card's location (disabled), then
        // "打开所在文件夹" (TASK-player-ux-trio Step 3).
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        collectionView.menu = contextMenu

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = CoveStyle.libraryBackground

        pageTitleLabel.font = CoveStyle.pageTitleFont
        pageTitleLabel.textColor = .labelColor
        pageTitleLabel.alignment = .left

        root.addSubview(pageTitleLabel)
        pageTitleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(CoveStyle.space20)
            make.top.equalToSuperview().offset(CoveStyle.space20)
            make.trailing.lessThanOrEqualToSuperview().offset(-CoveStyle.space20)
        }

        root.addSubview(scrollView)
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(pageTitleLabel.snp.bottom).offset(CoveStyle.space8)
            make.leading.trailing.bottom.equalToSuperview()
        }

        view = root
        render(viewModel.state)
    }

    private func render(_ state: HomeViewModel.State) {
        loadViewIfNeeded()
        collectionView.reloadData()

        placeholderView?.removeFromSuperview()
        placeholderView = nil
        guard let placeholder = state.placeholder else { return }

        let symbol: String
        switch placeholder.kind {
        case .noServers: symbol = "server.rack"
        case .noRecords: symbol = "film"
        }
        let view = StatePlaceholderView(
            style: .symbol(symbol),
            title: placeholder.title,
            message: placeholder.message,
            actionTitle: placeholder.action == nil ? nil : "添加服务器"
        )
        view.onAction = { [weak self] in self?.onAddServer?() }
        self.view.addSubview(view)
        view.snp.makeConstraints { make in
            // The page title stays visible above the empty state.
            make.top.equalTo(pageTitleLabel.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        placeholderView = view
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.item < viewModel.state.entries.count else { return }
        onResumeWatch?(viewModel.state.entries[indexPath.item])
    }
}

extension HomeViewController: NSMenuDelegate {
    /// Finder-style right-click: clicking an unselected card moves the
    /// selection to it before the menu appears (same rule as the
    /// browser's `selectionOnRightClick`), so the menu never acts on a
    /// card that doesn't look selected. The menu carries the clicked
    /// card's location as a disabled first item plus the reveal action;
    /// empty space (no card under the click) yields an empty menu, which
    /// simply does not appear.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let event = NSApp.currentEvent else { return }
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.item < viewModel.state.entries.count else { return }
        if !collectionView.selectionIndexPaths.contains(indexPath) {
            // `selectItems` is additive even with
            // `allowsMultipleSelection = false` — the A1-1 highlight
            // accumulation. Assignment replaces the selection.
            collectionView.selectionIndexPaths = [indexPath]
        }
        let entry = viewModel.state.entries[indexPath.item]

        let pathItem = NSMenuItem(title: entry.locationText(), action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)

        let revealItem = NSMenuItem(
            title: "打开所在文件夹",
            action: #selector(handleRevealInBrowser(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        revealItem.representedObject = entry
        menu.addItem(revealItem)
    }

    @objc private func handleRevealInBrowser(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? RecentWatchEntry else { return }
        onRevealInBrowser?(entry)
    }

}

extension HomeViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewModel.state.entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: RecentWatchCardItem.identifier,
            for: indexPath
        )
        let entries = viewModel.state.entries
        guard let card = item as? RecentWatchCardItem, indexPath.item < entries.count else { return item }
        card.configure(with: entries[indexPath.item], thumbnailProvider: thumbnailProvider)
        return card
    }
}

/// One card of the home grid: cover well (film symbol, or the player's
/// captured cover fading in over it), two-line truncating file name,
/// mini progress bar (only with a known duration), and the
/// "已看至 h:mm:ss · N天前" line. Same rounded-fill/border/hover recipe as
/// the share cards (Amendment 2 decision 1); a double click resumes
/// (decision 5).
@MainActor
final class RecentWatchCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("RecentWatchCardItem")

    /// Cover well side: matches the browser row's badge tile so both
    /// thumbnail surfaces speak the same size language.
    private static let coverSide: CGFloat = 40

    private let cardView = RoundedFillView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// In-flight cover request for the currently shown entry; cancelled on
    /// reuse (cell-reuse-driven loads are View lifecycle work, rule 12).
    private var coverTask: Task<Void, Never>?
    /// Store key of the entry the cover task was issued for, so a late
    /// result never lands on a reused card.
    private var coverKey: String?
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            updateHighlight()
        }
    }

    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            updateHighlight()
        }
    }

    override func loadView() {
        cardView.cornerRadius = CoveStyle.radiusMedium
        // Rest-state hairline so cards read as cards on the warm dark
        // background (tokens §6.4); kept on hover/selection.
        cardView.borderColor = CoveStyle.cardBorderColor

        // The same well carries the film symbol fallback and, when the
        // display pool has a captured cover, the thumbnail (clipped to the
        // same rounded corners as the browser badge).
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = CoveStyle.radiusSmall
        iconView.layer?.masksToBounds = true
        showFilmIcon()

        nameLabel.alignment = .center
        nameLabel.font = CoveStyle.bodyFont
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small

        subtitleLabel.alignment = .center
        subtitleLabel.font = CoveStyle.captionFont
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        // Icon + text rows as one vertically centered group, matching the
        // share card's centered composition. The stack collapses the
        // progress bar cleanly on pre-duration records (decision 1).
        let contentStack = NSStackView(views: [iconView, nameLabel, progressBar, subtitleLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = CoveStyle.space8
        contentStack.setCustomSpacing(CoveStyle.space4, after: nameLabel)
        contentStack.setCustomSpacing(CoveStyle.space4, after: progressBar)

        cardView.addSubview(contentStack)
        contentStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        iconView.snp.makeConstraints { make in
            make.width.height.equalTo(Self.coverSide)
        }
        nameLabel.snp.makeConstraints { make in
            make.width.equalTo(cardView).offset(-CoveStyle.space16)
        }
        progressBar.snp.makeConstraints { make in
            make.width.equalTo(nameLabel)
        }
        subtitleLabel.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(cardView).offset(-CoveStyle.space16)
        }

        view = cardView
        updateHighlight(animated: false)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverTask?.cancel()
        coverTask = nil
        coverKey = nil
        cardView.toolTip = nil
        showFilmIcon()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        view.addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    func configure(
        with entry: RecentWatchEntry,
        thumbnailProvider: (any RecentWatchThumbnailProviding)?
    ) {
        coverTask?.cancel()
        coverTask = nil
        coverKey = entry.key
        showFilmIcon()
        nameLabel.stringValue = entry.fileName
        // The subtitle's directory segment is middle-truncated; the
        // tooltip carries the untruncated full path (Step 3).
        cardView.toolTip = entry.path
        if let fraction = entry.progressFraction {
            progressBar.isHidden = false
            progressBar.doubleValue = fraction
        } else {
            // Pre-duration record (decision 1): timecode-only card.
            progressBar.isHidden = true
        }
        subtitleLabel.stringValue = entry.subtitleText(relativeTo: Date())

        // Covers come from the display pool only: a hit fades in over the
        // symbol, a miss (never watched through the player, unknown file
        // facts) keeps the film icon — the view never generates work.
        guard let thumbnailProvider else { return }
        let key = entry.key
        coverTask = Task { [weak self] in
            let cover = await thumbnailProvider.thumbnail(for: entry)
            guard let self, !Task.isCancelled, self.coverKey == key, let cover else { return }
            self.showCover(cover)
        }
    }

    /// Restores the tinted film symbol at its natural point size.
    private func showFilmIcon() {
        iconView.imageScaling = .scaleNone
        iconView.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolLarge, weight: .regular)
            )
        iconView.contentTintColor = CoveStyle.badgeTintVideo
        iconView.alphaValue = 1
    }

    /// Fades the captured cover in over the symbol (same recipe as the
    /// browser rows' thumbnails).
    private func showCover(_ image: CGImage) {
        iconView.contentTintColor = nil
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(cgImage: image, size: .zero)
        iconView.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CoveStyle.motionFast
            context.timingFunction = CoveStyle.motionTimingFunction
            iconView.animator().alphaValue = 1
        }
    }

    // `RoundedFillView` re-resolves the fill on appearance changes, so the
    // highlight never goes stale across appearance flips. Initial state in
    // `loadView` lands un-animated; live hover/selection changes transition
    // over the fast motion token (tokens §5).
    private func updateHighlight(animated: Bool = true) {
        let color: NSColor
        if isSelected {
            color = .selectedContentBackgroundColor
        } else if isHovering {
            color = CoveStyle.hoverFillColor
        } else {
            color = .clear
        }
        cardView.setFillColor(color, animated: animated)
    }
}
