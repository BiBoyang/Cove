import CoreGraphics
import Foundation

/// Pure layout logic for the continuous vertical strip reader: per-page
/// heights, the ±3-screen virtualization window, and viewport-anchored
/// reflow when estimated heights are replaced by measured ones.
///
/// The model owns the two invariants the previous iteration died on:
/// a slot is created for exactly one page index and destroyed when it
/// leaves the window (never reused for another page), and every height
/// change is applied as an anchored batch that keeps the first visible
/// page visually stationary. No AppKit — the view layer only renders
/// what this model computes.
struct StripLayoutModel: Sendable {
    /// Height/width ratio assumed for a page whose image has not been
    /// decoded yet: a portrait 3:4 page spanning the full viewport width.
    static let estimatedAspectRatio: CGFloat = 4.0 / 3.0

    /// Viewport heights kept alive beyond each side of the visible area.
    static let windowScreens: CGFloat = 3

    let pageCount: Int
    private(set) var viewportWidth: CGFloat

    /// Measured height/width ratio per page; nil while the estimate applies.
    private var aspects: [CGFloat?]

    init(pageCount: Int, viewportWidth: CGFloat) {
        precondition(pageCount > 0, "StripLayoutModel requires at least one page")
        precondition(viewportWidth > 0, "StripLayoutModel requires a positive viewport width")
        self.pageCount = pageCount
        self.viewportWidth = viewportWidth
        aspects = [CGFloat?](repeating: nil, count: pageCount)
    }

    /// Displayed height of a page at the current viewport width.
    func height(forPage index: Int) -> CGFloat {
        viewportWidth * (aspects[index] ?? Self.estimatedAspectRatio)
    }

    /// Total document height at the current viewport width.
    var contentHeight: CGFloat {
        (0 ..< pageCount).reduce(0) { $0 + height(forPage: $1) }
    }

    /// Top edge of a page in document coordinates.
    func yOffset(forPage index: Int) -> CGFloat {
        (0 ..< index).reduce(0) { $0 + height(forPage: $1) }
    }

    /// Distance of a document position below its page's top edge. The view
    /// layer captures this together with `firstVisiblePage(atY:)` to define
    /// an anchor before a reflow.
    func offsetWithinPage(pageIndex: Int, contentOffset: CGFloat) -> CGFloat {
        contentOffset - yOffset(forPage: pageIndex)
    }

    /// First page whose body intersects `y` — the page at the viewport's
    /// top edge. Out-of-range positions clamp onto the first/last page.
    func firstVisiblePage(atY y: CGFloat) -> Int {
        var top: CGFloat = 0
        for index in 0 ..< pageCount {
            let bottom = top + height(forPage: index)
            if y < bottom { return index }
            top = bottom
        }
        return pageCount - 1
    }

    /// Pages intersecting the visible area expanded by `windowScreens`
    /// viewport heights on each side, clamped into `0 ..< pageCount`.
    func activeRange(contentOffset: CGFloat, viewportHeight: CGFloat) -> Range<Int> {
        let lower = max(0, contentOffset - Self.windowScreens * viewportHeight)
        let upper = min(contentHeight, contentOffset + (1 + Self.windowScreens) * viewportHeight)
        let first = firstVisiblePage(atY: lower)
        let last = firstVisiblePage(atY: max(lower, upper))
        return first ..< (last + 1)
    }

    /// Create/destroy sets moving the residency window from `old` to `new`.
    /// A page is either fully resident or fully destroyed — the stream has
    /// no "reconfigure" event, which is what pins every slot to the page
    /// index it was created for.
    static func windowEvents(
        from old: Range<Int>,
        to new: Range<Int>
    ) -> (create: [Int], destroy: [Int]) {
        let create = new.filter { !old.contains($0) }
        let destroy = old.filter { !new.contains($0) }
        return (create, destroy)
    }

    /// Replaces estimates with measured height/width ratios and returns the
    /// content offset that keeps `anchorPage` visually stationary: its top
    /// keeps the same viewport-relative position, preserving
    /// `offsetWithinAnchorPage` (points, captured under the old layout)
    /// exactly. The whole batch lands in one pass so the document height
    /// changes atomically; the caller clamps the result into the scrollable
    /// range. Invalid indices and non-positive ratios are ignored.
    @discardableResult
    mutating func applyMeasurements(
        _ measurements: [Int: CGFloat],
        anchorPage: Int,
        offsetWithinAnchorPage: CGFloat
    ) -> CGFloat {
        for (index, aspect) in measurements where aspects.indices.contains(index) && aspect > 0 {
            aspects[index] = aspect
        }
        return yOffset(forPage: anchorPage) + offsetWithinAnchorPage
    }

    /// Re-bases every height on a new viewport width (window resize,
    /// fullscreen transitions) under the same anchoring rule: estimates
    /// scale with the width, measured pages keep their aspect ratio.
    @discardableResult
    mutating func updateViewportWidth(
        _ newWidth: CGFloat,
        anchorPage: Int,
        offsetWithinAnchorPage: CGFloat
    ) -> CGFloat {
        precondition(newWidth > 0, "StripLayoutModel requires a positive viewport width")
        viewportWidth = newWidth
        return yOffset(forPage: anchorPage) + offsetWithinAnchorPage
    }
}
