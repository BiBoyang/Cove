import AppKit
import SnapKit
import SourceKit

/// Servers feature detail after a connection: the server's shares as a card grid.
/// Pure UI — share-open intents are forwarded via `onOpenShare`.
@MainActor
final class ShareGridViewController: NSViewController {
    private let viewModel: ShareGridViewModel

    var onOpenShare: ((SMBShareInfo) -> Void)?

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let placeholderIcon = NSImageView()
    private let placeholderStack = NSStackView()

    init(viewModel: ShareGridViewModel) {
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

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 160, height: 130)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(ShareCardItem.self, forItemWithIdentifier: ShareCardItem.identifier)

        // NSCollectionView has no doubleAction; a two-click recognizer on the
        // collection view plus hit-testing the item is the AppKit way.
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true

        placeholderIcon.image = NSImage(
            systemSymbolName: "externaldrive", accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 36, weight: .light))
        placeholderIcon.contentTintColor = .tertiaryLabelColor
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 10
        placeholderStack.addArrangedSubview(placeholderIcon)
        placeholderStack.addArrangedSubview(placeholderLabel)

        root.addSubview(scrollView)
        root.addSubview(placeholderStack)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        placeholderStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        view = root
        render(viewModel.state)
    }

    private func render(_ state: ShareGridViewModel.State) {
        loadViewIfNeeded()
        collectionView.reloadData()
        placeholderLabel.stringValue = state.placeholder ?? ""
        placeholderStack.isHidden = state.placeholder == nil
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.item < viewModel.state.shares.count else { return }
        onOpenShare?(viewModel.state.shares[indexPath.item])
    }
}

extension ShareGridViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewModel.state.shares.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ShareCardItem.identifier,
            for: indexPath
        )
        let shares = viewModel.state.shares
        guard let card = item as? ShareCardItem, indexPath.item < shares.count else { return item }
        card.configure(with: shares[indexPath.item])
        return card
    }
}

/// One card in the share grid: outline folder icon, share name, remark.
/// Borderless by default (Finder/Infuse-style icon grid); a rounded fill
/// appears on hover and lights up while selected.
@MainActor
final class ShareCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ShareCardItem")

    private let cardView = RoundedFillView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let commentLabel = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet { updateHighlight() }
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    override func loadView() {
        cardView.cornerRadius = CoveStyle.radiusMedium

        let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
            )
        iconView.image = folderIcon
        iconView.contentTintColor = .labelColor

        nameLabel.alignment = .center
        nameLabel.font = CoveStyle.titleFont
        nameLabel.lineBreakMode = .byTruncatingMiddle

        commentLabel.alignment = .center
        commentLabel.font = CoveStyle.captionFont
        commentLabel.textColor = .secondaryLabelColor
        commentLabel.lineBreakMode = .byTruncatingTail

        // Icon + labels as one vertically centered group; the stack collapses
        // the remark line cleanly when a share has no comment.
        let contentStack = NSStackView(views: [iconView, nameLabel, commentLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 8
        contentStack.setCustomSpacing(4, after: nameLabel)

        cardView.addSubview(contentStack)
        contentStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        nameLabel.snp.makeConstraints { make in
            make.width.equalTo(cardView).offset(-16)
        }
        commentLabel.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(cardView).offset(-16)
        }

        view = cardView
        updateHighlight()
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

    func configure(with share: SMBShareInfo) {
        nameLabel.stringValue = share.name
        commentLabel.stringValue = share.comment
        commentLabel.isHidden = share.comment.isEmpty
    }

    // `RoundedFillView` re-resolves the fill on appearance changes, so the
    // highlight never goes stale across appearance flips.
    private func updateHighlight() {
        if isSelected {
            cardView.fillColor = .selectedContentBackgroundColor
        } else if isHovering {
            cardView.fillColor = .quaternaryLabelColor
        } else {
            cardView.fillColor = .clear
        }
    }
}
