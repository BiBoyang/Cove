import AppKit

/// Layer-backed rounded rect filled with a dynamic (semantic) color.
/// Resolving the color in `updateLayer` keeps it correct across appearance
/// changes; a one-shot `layer.backgroundColor` assignment would go stale.
@MainActor
final class RoundedFillView: NSView {
    var fillColor: NSColor = .secondarySystemFill {
        didSet { needsDisplay = true }
    }

    var cornerRadius: CGFloat = 8 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
