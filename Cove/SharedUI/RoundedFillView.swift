import AppKit

/// Shared layer-backed rounded rect filled with a dynamic semantic color.
/// Resolving the color in `updateLayer` keeps it correct across appearance
/// changes; a one-shot `layer.backgroundColor` assignment would go stale.
@MainActor
final class RoundedFillView: NSView {
    var fillColor: NSColor = .secondarySystemFill {
        didSet { needsDisplay = true }
    }

    /// Updates the fill, optionally animating the change with the fast
    /// motion token (tokens §5). The model value updates immediately and
    /// `updateLayer` re-resolves to the same value, which is a no-op for
    /// Core Animation, so the running transition never gets clobbered;
    /// appearance-driven re-resolves still land instantly (by design).
    /// Falls back to the un-animated path when not yet in a window.
    func setFillColor(_ color: NSColor, animated: Bool) {
        guard animated, window != nil, color != fillColor else {
            fillColor = color
            return
        }
        fillColor = color
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CoveStyle.motionFast
            context.timingFunction = CoveStyle.motionTimingFunction
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = color.cgColor
        }
    }

    /// Optional hairline border, re-resolved with the fill on appearance
    /// changes. Nil means no border.
    var borderColor: NSColor? {
        didSet { needsDisplay = true }
    }

    var cornerRadius: CGFloat = CoveStyle.radiusMedium {
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
        if let borderColor {
            layer?.borderWidth = 1
            layer?.borderColor = borderColor.cgColor
        } else {
            layer?.borderWidth = 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
