import AppKit
import SnapKit
import SourceKit

/// Right pane after a server connects: the server's shares as a card grid.
/// Pure UI — share-open intents are forwarded via `onOpenShare`.
@MainActor
final class ShareGridViewController: NSViewController {
    var onOpenShare: ((SMBShareInfo) -> Void)?

    private var shares: [SMBShareInfo] = []

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let placeholderLabel = NSTextField(labelWithString: "")

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
        showPlaceholder("双击左侧服务器以连接")
    }

    /// Idle state, also used before any server has been selected.
    func showPlaceholder(_ text: String) {
        shares = []
        collectionView.reloadData()
        placeholderLabel.stringValue = text
        placeholderLabel.isHidden = false
    }

    /// Shown while the share list is being fetched.
    func displayLoading() {
        showPlaceholder("正在获取共享列表…")
    }

    /// Replaces the grid contents.
    func display(shares: [SMBShareInfo]) {
        self.shares = shares
        collectionView.reloadData()
        if shares.isEmpty {
            placeholderLabel.stringValue = "该服务器没有可用共享"
            placeholderLabel.isHidden = false
        } else {
            placeholderLabel.isHidden = true
        }
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.item < shares.count else { return }
        onOpenShare?(shares[indexPath.item])
    }
}

extension ShareGridViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shares.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ShareCardItem.identifier,
            for: indexPath
        )
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
