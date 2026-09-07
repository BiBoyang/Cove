import AppKit

/// Shared design constants for Cove's UI: spacing, component sizes,
/// corner radii, fonts, and colors.
/// One place so every feature screen speaks the same visual language
/// instead of growing its own ad-hoc values.
@MainActor
enum CoveStyle {
    // MARK: Spacing (tokens §3)

    // Fixed spacing scale; call sites pick a step directly instead of
    // inventing ad-hoc offsets. Steps 6/10/14 are the admitted 2pt
    // sub-steps for measured high-density chrome (transport chains,
    // slider flanks, popover insets); prefer the main 4pt grid elsewhere.
    // Usage conventions (content insets, card padding, compact gaps) are
    // documented in design/DESIGN-TOKENS.md §3, not aliased here.
    static let space4: CGFloat = 4
    static let space6: CGFloat = 6
    static let space8: CGFloat = 8
    static let space10: CGFloat = 10
    static let space12: CGFloat = 12
    static let space14: CGFloat = 14
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32

    // MARK: Component sizes (tokens §3)

    // Fixed component dimensions by semantic role: one role per
    // value+meaning pair — a repeated value with a different meaning gets
    // its own role so each can evolve independently. Mirrors the role
    // table in design/DESIGN-TOKENS.md §3.

    /// Capsule (pill) control standard height; PillButton enforces it as
    /// its minimum height.
    static let controlPill: CGFloat = 26
    /// Browser list row height (badge tile plus breathing room).
    static let rowList: CGFloat = 56
    /// Sidebar row height (servers/local groups).
    static let rowSidebar: CGFloat = 32
    /// Sidebar group-header row height (same value as `chipCodec`,
    /// different meaning — separate role).
    static let rowSidebarGroup: CGFloat = 20
    /// Row icon badge tile in browser list rows.
    static let badgeTile: CGFloat = 40
    /// Browser toolbar strip height above the content list.
    static let barBrowserToolbar: CGFloat = 52
    /// Player controls capsule height (upper control row + lower progress
    /// row).
    static let capsulePlayer: CGFloat = 68
    /// Square action buttons on horizontal control bars (the player
    /// capsule's transport row, the browser toolbar).
    static let controlTransport: CGFloat = 28
    /// Codec info chip height (HW / codec / resolution / bitrate).
    static let chipCodec: CGFloat = 20
    /// Player volume slider width.
    static let sliderVolume: CGFloat = 64
    /// Reader chrome pill height (scrubber / page chrome / resume hint;
    /// same value as `rowSidebar`, different meaning — separate role).
    static let pillReaderChrome: CGFloat = 32
    /// Accessory symbol buttons nested inside reader chrome pills
    /// (auto-scroll, auto-advance).
    static let controlPillAccessory: CGFloat = 24
    /// Reader navigation circles (previous/next page).
    static let circleNav: CGFloat = 44
    /// Strip-reader scrubber slider width (inside the scrubber pill).
    static let sliderScrubber: CGFloat = 220
    /// Settings numeric input field width (capacity / TTL / rate limit;
    /// same value as `sliderVolume`, different meaning — separate role).
    static let fieldNumeric: CGFloat = 64
    /// Settings preheat-folder table height.
    static let tablePreheatFolder: CGFloat = 150
    /// Queue row height in the player's playlist popover (same value as
    /// `rowSidebar`, different meaning — separate role); the popover's
    /// height formula takes its row term from this role.
    static let rowPlaylist: CGFloat = 32
    /// Reader mode-toggle circle (paged/strip), the smaller sibling of the
    /// `circleNav` prev/next circles (same value as `rowSidebar`,
    /// different meaning — separate role).
    static let circleMode: CGFloat = 32
    /// Mini accessory action button on a horizontal chrome bar (the
    /// browser toolbar's download-cancel button); deliberately smaller
    /// than the `controlPill` standard (same value as `chipCodec`,
    /// different meaning — separate role).
    static let controlBarAccessory: CGFloat = 20

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

    // MARK: Media chrome surfaces (tokens §1)

    /// Opaque warm-black backing for chrome floating over media (reader
    /// pills, the player capsule, codec chips). Deliberately NOT a
    /// translucent material: on bright comic pages a see-through fill lets
    /// the page wash out the chrome, and an opaque board keeps contrast
    /// predictable regardless of what renders underneath.
    static let surfaceOverlay = NSColor(
        srgbRed: 0x1E / 255.0, green: 0x1C / 255.0, blue: 0x1C / 255.0, alpha: 1
    )

    /// Overlay text on media, tier 1: primary readouts (page numbers,
    /// timecodes, titles, zoom flashes).
    static let textOnMedia1 = NSColor.white
    /// Overlay text on media, tier 2: secondary readouts (speed gears,
    /// volume values).
    static let textOnMedia2 = NSColor.white.withAlphaComponent(0.7)
    /// Overlay text on media, tier 3: hints (page placeholders).
    static let textOnMedia3 = NSColor.white.withAlphaComponent(0.5)

    /// Reader letterbox background (single-page, strip, PDF): warm
    /// near-black, one step deeper than `surfaceOverlay` and in the same
    /// warm family as the library palette. Pure black reads cold next to
    /// the warm chrome and flattens the layering; this keeps the frame
    /// warm while staying darker than any chrome floating on it.
    static let readerBackground = NSColor(
        srgbRed: 0x1A / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0, alpha: 1
    )

    // MARK: Shadow recipes (tokens §4.6)

    // NSShadow is mutable, so each recipe returns a fresh instance per
    // call instead of sharing one across call sites.

    /// Legibility shadow for white overlay text on media (the player's
    /// center title, the readers' zoom flashes): keeps the glyphs readable
    /// on bright frames and pages.
    static var shadowTextOnMedia: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }

    /// Drop shadow for chrome boards floating over media (the player
    /// controls capsule, the Up Next pill): a soft low halo that separates
    /// the opaque board from the frame underneath.
    static var shadowFloatingChrome: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        return shadow
    }

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
