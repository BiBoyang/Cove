import AppKit
import SnapKit

/// AppKit continuous vertical strip reader surface: pages stacked at full
/// viewport width inside an NSScrollView, virtualized ±3 screens by the
/// layout model. The view only renders what `ContinuousReaderViewModel`
/// computes — slot frames, create/destroy, anchored relayouts — and
/// forwards scroll/resize input.
///
/// Frames, not constraints, position the document and slot views: the
/// anchored relayout needs exact, transaction-free control that Auto
/// Layout constraints cannot express. Constraint-based chrome (scroll view,
/// progress label) still uses SnapKit per AGENTS.md §11.
@MainActor
final class ContinuousReaderView: NSView {
    private let viewModel: ContinuousReaderViewModel
    private let scrollView = NSScrollView()
    private let documentView = StripDocumentView()
    private let progressLabel = NSTextField(labelWithString: "")
    private var slotViews: [Int: StripSlotView] = [:]
    private var didApplyInitialOffset = false

    init(viewModel: ContinuousReaderViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        assemble()
        bindViewModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        let size = scrollView.contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        viewModel.updateViewport(width: size.width, height: size.height)
        if !didApplyInitialOffset {
            didApplyInitialOffset = true
            relayout(to: viewModel.startContentOffset)
        }
    }

    // MARK: - Assembly

    private func assemble() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        // Overlay style: a position affordance for long comics that never
        // narrows the document width (scroller visibility would change it).
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .white

        addSubview(scrollView)
        addSubview(progressLabel)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        progressLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-16)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func bindViewModel() {
        viewModel.onSlotsChanged = { [weak self] events in
            self?.applySlotEvents(events)
        }
        viewModel.onSlotImage = { [weak self] index, image in
            self?.slotViews[index]?.show(image: image, forPage: index)
        }
        viewModel.onRelayout = { [weak self] newOffset in
            self?.relayout(to: newOffset)
        }
        viewModel.onStateChange = { [weak self] state in
            self?.progressLabel.stringValue = state.progressText
            self?.window?.title = state.pageTitle
        }
    }

    // MARK: - Slot and layout application

    private func applySlotEvents(_ events: (create: [Int], destroy: [Int])) {
        for index in events.destroy {
            slotViews[index]?.removeFromSuperview()
            slotViews[index] = nil
        }
        for index in events.create where slotViews[index] == nil {
            let slot = StripSlotView(pageIndex: index)
            slot.frame = frame(forPage: index)
            documentView.addSubview(slot)
            slotViews[index] = slot
        }
    }

    /// Applies a batch reflow: new document height, resident slot frames,
    /// then the anchor-preserving content offset from the view model.
    private func relayout(to newOffset: CGFloat) {
        let width = scrollView.contentView.bounds.width
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: viewModel.contentHeight)
        for (index, slot) in slotViews {
            slot.frame = frame(forPage: index)
        }
        if abs(scrollView.contentView.bounds.origin.y - newOffset) > 0.5 {
            scroll(to: newOffset)
        }
        // Heights moved the residency window; report the settled offset.
        viewModel.updateScrollOffset(scrollView.contentView.bounds.origin.y)
    }

    private func frame(forPage index: Int) -> NSRect {
        NSRect(
            x: 0,
            y: viewModel.yOffset(forPage: index),
            width: scrollView.contentView.bounds.width,
            height: viewModel.height(forPage: index)
        )
    }

    private func scroll(to y: CGFloat) {
        let maxOffset = max(0, viewModel.contentHeight - scrollView.contentView.bounds.height)
        let clamped = max(0, min(y, maxOffset))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func clipBoundsDidChange(_ notification: Notification) {
        viewModel.updateScrollOffset(scrollView.contentView.bounds.origin.y)
    }

    // MARK: - Keyboard

    /// Handles scroll keys while strip mode owns the window. Returns true
    /// when the key was consumed. Left/right are consumed as no-ops —
    /// paging keys have no meaning in the strip.
    func handleKey(_ event: NSEvent) -> Bool {
        let offset = scrollView.contentView.bounds.origin.y
        switch event.keyCode {
        case 126: scroll(to: offset - 80) // ↑
        case 125: scroll(to: offset + 80) // ↓
        case 116: scroll(to: offset - scrollView.contentView.bounds.height) // PageUp
        case 121: scroll(to: offset + scrollView.contentView.bounds.height) // PageDown
        case 123, 124: break // ←/→
        default: return false
        }
        return true
    }
}

/// Flipped so y=0 is the document top, matching the layout model's
/// coordinates (a slot's frame y equals the model's yOffset).
@MainActor
private final class StripDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// One page slot. The page index is pinned at creation and never changes;
/// an image is applied only when its arriving index matches the pin (hard
/// rule: async results must never land on a re-purposed view). The
/// placeholder is a near-black fill with the page number.
@MainActor
private final class StripSlotView: NSView {
    let pageIndex: Int
    private let imageView = NSImageView()
    private let numberLabel = NSTextField(labelWithString: "")

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        numberLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        numberLabel.alignment = .center
        numberLabel.stringValue = "\(pageIndex + 1)"

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // Same solver insurance as the paged reader: the image's pixel-size
        // intrinsic claims must never beat the slot's edge constraints.
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        addSubview(imageView)
        addSubview(numberLabel)
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        numberLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(image: CGImage, forPage index: Int) {
        guard index == pageIndex else { return }
        imageView.image = NSImage(cgImage: image, size: .zero)
        numberLabel.isHidden = true
    }
}
