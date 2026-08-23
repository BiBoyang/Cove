import AppKit
import SnapKit

/// A circular overlay button with a translucent dark fill and a hairline
/// border, for controls that sit on top of media content (reader, player).
/// The fill brightens on hover. Plain NSButton bezels can't produce this
/// look, so the fill is a layer background managed here.
@MainActor
final class FrostedCircleButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet { updateFill() }
    }

    init(symbolName: String, pointSize: CGFloat, accessibilityDescription: String) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        contentTintColor = .white
        focusRingType = .none
        wantsLayer = true
        layer?.borderWidth = 1
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        updateAppearanceColors()
    }

    override func updateLayer() {
        updateAppearanceColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func updateFill() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(isHovering ? 0.55 : 0.35).cgColor
    }

    /// Border and fill are fixed dark-scheme colors (the button only ever
    /// sits on media); re-resolved here so the layer never goes stale.
    private func updateAppearanceColors() {
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        updateFill()
    }
}
