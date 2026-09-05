import AppKit

/// Shared design constants for Cove's UI: corner radii, fonts, and colors.
/// One place so every feature screen speaks the same visual language
/// instead of growing its own ad-hoc values.
@MainActor
enum CoveStyle {
    // MARK: Corner radii

    /// Small badges and chips (e.g. the server row icon badge).
    static let radiusSmall: CGFloat = 6
    /// Cards and grid items (e.g. share cards).
    static let radiusMedium: CGFloat = 12
    /// Panels and floating bars (e.g. overlay controls).
    static let radiusLarge: CGFloat = 14
    /// Table row selection highlight (a hair wider than radiusSmall so the
    /// rounded rect reads as a row, not a badge).
    static let radiusRowSelection: CGFloat = 8

    // MARK: Interaction fills

    /// Hover feedback on content surfaces (cards, grid items) — system
    /// semantic gray, same family as the system-blue selection.
    static var hoverFillColor: NSColor { .quaternaryLabelColor }

    // MARK: Overlay button recipe (buttons floating on media/dark surfaces)

    /// Translucent dark fill for overlay buttons, rest state.
    static var overlayButtonFill: NSColor { NSColor.black.withAlphaComponent(0.35) }
    /// Brightened overlay fill on hover.
    static var overlayButtonFillHover: NSColor { NSColor.black.withAlphaComponent(0.55) }
    /// Hairline border for overlay buttons.
    static var overlayButtonBorder: NSColor { NSColor.white.withAlphaComponent(0.18) }

    // MARK: Motion (tokens §5)

    /// Motion serves state feedback only (hover/selection/fade-ins), never
    /// decoration, and always eases out so changes start fast and settle
    /// instead of feeling floaty. Fast: hover/selection fills, fade-ins.
    static let motionFast: TimeInterval = 0.15
    /// Medium: panel and overlay-chrome reveals. Reserved for future use;
    /// no current call site consumes it yet.
    static let motionMedium: TimeInterval = 0.25
    /// Shared timing curve for both motion tiers.
    static var motionTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeOut)
    }

    // MARK: Symbol sizes

    /// Small affordances (tags, compact controls).
    static let symbolSmall: CGFloat = 12
    /// Toolbar and transport controls.
    static let symbolMedium: CGFloat = 14
    /// List-row badges.
    static let symbolLarge: CGFloat = 18
    /// Cards and placeholders.
    static let symbolHero: CGFloat = 36

    // MARK: Fonts

    /// Row/card titles.
    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    /// Primary body text (list rows).
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    /// Secondary metadata (dates, sizes, comments).
    static let captionFont = NSFont.systemFont(ofSize: 11)
    /// Small section headers (sidebar groups).
    static let sectionHeaderFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// Form labels and auxiliary copy (preferences, breadcrumb chain).
    static let formLabelFont = NSFont.systemFont(ofSize: 12)
    /// Monospaced digits for timecodes and page numbers.
    static let monoDigitFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    /// Reader zoom-factor flash overlay.
    static let overlayFlashFont = NSFont.systemFont(ofSize: 15, weight: .semibold)

    // MARK: Colors

    /// Subtle card border that keeps rounded shapes readable on dark
    /// backgrounds without a heavy outline.
    static var cardBorderColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.08)
    }

    // MARK: Library palette (warm dark grays)

    /// Library content background (list area behind rows and cards).
    static let libraryBackground = NSColor(
        srgbRed: 0x2c / 255.0, green: 0x29 / 255.0, blue: 0x29 / 255.0, alpha: 1
    )
    /// Library toolbar strip above the content area.
    static let libraryToolbarBackground = NSColor(
        srgbRed: 0x33 / 255.0, green: 0x31 / 255.0, blue: 0x31 / 255.0, alpha: 1
    )
    /// Small gold accent (selected/active hints).
    static let accentGold = NSColor(
        srgbRed: 0xe0 / 255.0, green: 0xc0 / 255.0, blue: 0x20 / 255.0, alpha: 1
    )
}
