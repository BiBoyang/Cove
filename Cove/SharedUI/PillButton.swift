import AppKit

/// A capsule-shaped button for toolbars and sheets, in the Infuse spirit:
/// primary actions get a solid accent fill, secondary actions a translucent
/// dark fill with a hairline border. Plain NSButton bezels can't produce
/// this look, so the fill is a layer background managed here (same approach
/// as FrostedCircleButton). The fill brightens on hover.
@MainActor
final class PillButton: NSButton {
    enum Style {
        /// Solid accent fill with a white label: the primary action.
        case primary
        /// Translucent dark fill + hairline border with a light label.
        case secondary
    }

    private let style: Style
    private let symbolPointSize: CGFloat
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet { updateFill() }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    /// Titled capsule (e.g. sheet confirm/cancel). The intrinsic width adds
    /// horizontal padding so the capsule hugs the label with breathing room.
    init(title: String, style: Style) {
        self.style = style
        self.symbolPointSize = 0
        super.init(frame: .zero)
        commonSetup()
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: NSColor.white]
        )
    }

    /// Symbol-only capsule (e.g. toolbar controls). Call sites pin the size
    /// with constraints; the symbol keeps the configured point size/weight.
    init(symbolName: String, pointSize: CGFloat, style: Style, accessibilityDescription: String) {
        self.style = style
        self.symbolPointSize = pointSize
        super.init(frame: .zero)
        imagePosition = .imageOnly
        contentTintColor = .white
        commonSetup()
        setSymbol(symbolName, accessibilityDescription: accessibilityDescription)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Swaps the symbol (e.g. a preheat state toggle), keeping the
    /// configured size and weight.
    func setSymbol(_ symbolName: String, accessibilityDescription: String) {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold))
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if !attributedTitle.string.isEmpty {
            size.width += 24
            size.height = max(size.height, 26)
        }
        return size
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

    private func commonSetup() {
        isBordered = false
        title = ""
        focusRingType = .none
        wantsLayer = true
        updateFill()
    }

    private func updateFill() {
        switch style {
        case .primary:
            // Hover brightens the accent; semantic colors need resolving to
            // a plain color space before blending, so fall back gracefully.
            let accent = NSColor.controlAccentColor
            var fill = accent
            if isHovering,
               let resolved = accent.usingColorSpace(.sRGB),
               let blended = resolved.blended(withFraction: 0.15, of: .white) {
                fill = blended
            }
            layer?.backgroundColor = fill.cgColor
        case .secondary:
            layer?.backgroundColor = (isHovering ? CoveStyle.overlayButtonFillHover : CoveStyle.overlayButtonFill).cgColor
        }
    }

    /// The border is a fixed dark-scheme hairline; re-resolved here so the
    /// layer never goes stale.
    private func updateAppearanceColors() {
        switch style {
        case .primary:
            layer?.borderWidth = 0
        case .secondary:
            layer?.borderWidth = 1
            layer?.borderColor = CoveStyle.overlayButtonBorder.cgColor
        }
        updateFill()
    }
}
