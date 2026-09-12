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

    /// Continue-watching card double-clicks, forwarded to the
    /// coordinator's resume deep link (decision 4).
    var onResumeWatch: ((RecentWatchEntry) -> Void)?
    /// First-run empty-state action (add server), mapped from the state.
    var onAddServer: (() -> Void)?

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private var placeholderView: StatePlaceholderView?

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

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = CoveStyle.libraryBackground

        root.addSubview(scrollView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
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
            make.edges.equalToSuperview()
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
        card.configure(with: entries[indexPath.item])
        return card
    }
}

/// One card of the home grid: film badge, two-line truncating file name,
/// mini progress bar (only with a known duration), and the
/// "已看至 h:mm:ss · N天前" line. Same rounded-fill/border/hover recipe as
/// the share cards (Amendment 2 decision 1); a double click resumes
/// (decision 5).
@MainActor
final class RecentWatchCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("RecentWatchCardItem")

    private let cardView = RoundedFillView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let subtitleLabel = NSTextField(labelWithString: "")
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

        let filmIcon = NSImage(systemSymbolName: "film", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolLarge, weight: .regular)
            )
        iconView.image = filmIcon
        iconView.contentTintColor = CoveStyle.badgeTintVideo

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

    func configure(with entry: RecentWatchEntry) {
        nameLabel.stringValue = entry.fileName
        if let fraction = entry.progressFraction {
            progressBar.isHidden = false
            progressBar.doubleValue = fraction
        } else {
            // Pre-duration record (decision 1): timecode-only card.
            progressBar.isHidden = true
        }
        subtitleLabel.stringValue = entry.subtitleText(relativeTo: Date())
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
