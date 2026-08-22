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

        placeholderLabel.textColor = .secondaryLabelColor

        root.addSubview(scrollView)
        root.addSubview(placeholderLabel)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        placeholderLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        view = root
        render(viewModel.state)
    }

    private func render(_ state: ShareGridViewModel.State) {
        loadViewIfNeeded()
        collectionView.reloadData()
        placeholderLabel.stringValue = state.placeholder ?? ""
        placeholderLabel.isHidden = state.placeholder == nil
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

/// One card in the share grid: large folder icon, share name, remark.
/// The rounded background lights up while selected.
@MainActor
final class ShareCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ShareCardItem")

    private let cardView = RoundedFillView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let commentLabel = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    override func loadView() {
        cardView.cornerRadius = 10

        let folderIcon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
            )
        iconView.image = folderIcon
        iconView.contentTintColor = .systemBlue

        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle

        commentLabel.alignment = .center
        commentLabel.font = .systemFont(ofSize: 11)
        commentLabel.textColor = .secondaryLabelColor
        commentLabel.lineBreakMode = .byTruncatingTail

        cardView.addSubview(iconView)
        cardView.addSubview(nameLabel)
        cardView.addSubview(commentLabel)
        iconView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(16)
            make.centerX.equalToSuperview()
        }
        nameLabel.snp.makeConstraints { make in
            make.top.equalTo(iconView.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(8)
        }
        commentLabel.snp.makeConstraints { make in
            make.top.equalTo(nameLabel.snp.bottom).offset(2)
            make.leading.trailing.equalTo(nameLabel)
        }

        view = cardView
        updateHighlight()
    }

    func configure(with share: SMBShareInfo) {
        nameLabel.stringValue = share.name
        commentLabel.stringValue = share.comment
        commentLabel.isHidden = share.comment.isEmpty
    }

    // `RoundedFillView` re-resolves the fill on appearance changes, so the
    // highlight never goes stale across light/dark flips.
    private func updateHighlight() {
        cardView.fillColor = isSelected
            ? .selectedContentBackgroundColor
            : .secondarySystemFill
    }
}
