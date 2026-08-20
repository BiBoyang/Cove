import AppKit
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
        layout.itemSize = NSSize(width: 150, height: 120)
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

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

    private let cardView = NSView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let commentLabel = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    override func loadView() {
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 10

        let folderIcon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            )
        iconView.image = folderIcon
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        commentLabel.alignment = .center
        commentLabel.font = .systemFont(ofSize: 11)
        commentLabel.textColor = .secondaryLabelColor
        commentLabel.lineBreakMode = .byTruncatingTail
        commentLabel.translatesAutoresizingMaskIntoConstraints = false

        cardView.addSubview(iconView)
        cardView.addSubview(nameLabel)
        cardView.addSubview(commentLabel)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            iconView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -8),

            commentLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            commentLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            commentLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
        ])

        view = cardView
        updateHighlight()
    }

    func configure(with share: SMBShareInfo) {
        nameLabel.stringValue = share.name
        commentLabel.stringValue = share.comment
        commentLabel.isHidden = share.comment.isEmpty
    }

    private func updateHighlight() {
        cardView.layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.quaternarySystemFill.cgColor
    }
}
