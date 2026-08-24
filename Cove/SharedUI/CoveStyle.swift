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

    // MARK: Fonts

    /// Row/card titles.
    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    /// Primary body text (list rows).
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    /// Secondary metadata (dates, sizes, comments).
    static let captionFont = NSFont.systemFont(ofSize: 11)
    /// Small section headers (sidebar groups).
    static let sectionHeaderFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    // MARK: Colors

    /// Subtle card border that keeps rounded shapes readable on dark
    /// backgrounds without a heavy outline.
    static var cardBorderColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.08)
    }
}
