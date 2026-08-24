import CoreGraphics
import Testing

@testable import Cove

@Suite("Strip layout model")
struct StripLayoutModelTests {
    /// Width 300 makes the estimated page height 400 (ratio 4/3), so the
    /// ±3-screen window at viewport height 550 spans 1650pt on each side.
    private let width: CGFloat = 300
    private let viewportHeight: CGFloat = 550

    @Test("the initial window covers the visible pages plus three screens ahead")
    func initialWindow() {
        let model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        #expect(model.activeRange(contentOffset: 0, viewportHeight: viewportHeight) == 0 ..< 6)
    }

    @Test("the window follows scrolling and clamps at both ends")
    func windowFollowsScrolling() {
        let model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        #expect(model.activeRange(contentOffset: 3000, viewportHeight: viewportHeight) == 3 ..< 10)
        #expect(model.activeRange(contentOffset: 3800, viewportHeight: viewportHeight) == 5 ..< 10)
    }

    @Test("a document shorter than the window keeps every page resident")
    func shortDocumentKeepsAllPages() {
        let model = StripLayoutModel(pageCount: 2, viewportWidth: width)
        #expect(model.activeRange(contentOffset: 0, viewportHeight: viewportHeight) == 0 ..< 2)
    }

    @Test("first visible page clamps out-of-range offsets")
    func firstVisibleClamping() {
        let model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        #expect(model.firstVisiblePage(atY: -50) == 0)
        #expect(model.firstVisiblePage(atY: 0) == 0)
        #expect(model.firstVisiblePage(atY: 401) == 1)
        #expect(model.firstVisiblePage(atY: 10_000) == 9)
    }

    @Test("window events only create and destroy — never reassign a resident page")
    func windowEventsShape() {
        let forward = StripLayoutModel.windowEvents(from: 0 ..< 6, to: 3 ..< 10)
        #expect(forward.create == [6, 7, 8, 9])
        #expect(forward.destroy == [0, 1, 2])

        let none = StripLayoutModel.windowEvents(from: 3 ..< 10, to: 3 ..< 10)
        #expect(none.create.isEmpty && none.destroy.isEmpty)

        let backward = StripLayoutModel.windowEvents(from: 3 ..< 10, to: 0 ..< 6)
        #expect(backward.create == [0, 1, 2])
        #expect(backward.destroy == [6, 7, 8, 9])
    }

    @Test("a page is destroyed before it can be created again over a scroll sequence")
    func slotIdentityStaysStable() {
        let model = StripLayoutModel(pageCount: 20, viewportWidth: width)
        var window = model.activeRange(contentOffset: 0, viewportHeight: viewportHeight)
        var resident = Set(window)

        for offset in [CGFloat(800), 1600, 3000, 7000, 1200, 500, 7800, 0] {
            let next = model.activeRange(contentOffset: offset, viewportHeight: viewportHeight)
            let events = StripLayoutModel.windowEvents(from: window, to: next)
            for index in events.create {
                // A create for a resident page would mean a slot got new
                // content instead of being destroyed first.
                #expect(!resident.contains(index))
                resident.insert(index)
            }
            for index in events.destroy {
                #expect(resident.contains(index))
                resident.remove(index)
            }
            #expect(resident == Set(next))
            window = next
        }
    }

    @Test("measurements above the anchor shift the offset by the height delta")
    func measurementsAboveAnchorShiftOffset() {
        var model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        // Anchor on page 3, 100pt below its top. Pages 0-2 shrink 400 -> 150.
        let newOffset = model.applyMeasurements(
            [0: 0.5, 1: 0.5, 2: 0.5],
            anchorPage: 3,
            offsetWithinAnchorPage: 100
        )
        #expect(isClose(newOffset, 550))
        #expect(isClose(model.height(forPage: 0), 150))
        #expect(isClose(model.contentHeight, 3250))
        // The anchor page kept its visual position under the new layout.
        #expect(isClose(model.yOffset(forPage: 3) + 100, newOffset))
    }

    @Test("measurements below the anchor leave the offset untouched")
    func measurementsBelowAnchorKeepOffset() {
        var model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        let newOffset = model.applyMeasurements([5: 2.0], anchorPage: 0, offsetWithinAnchorPage: 120)
        #expect(isClose(newOffset, 120))
        #expect(isClose(model.height(forPage: 5), 600))
        #expect(isClose(model.contentHeight, 4200))
    }

    @Test("the anchor page's own measurement keeps its top in place")
    func anchorOwnMeasurementKeepsTop() {
        var model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        let topBefore = model.yOffset(forPage: 1)
        let newOffset = model.applyMeasurements([1: 1.0], anchorPage: 1, offsetWithinAnchorPage: 50)
        #expect(isClose(newOffset, topBefore + 50))
        #expect(isClose(model.height(forPage: 1), 300))
    }

    @Test("a mixed batch lands in a single pass")
    func mixedBatchLandsAtomically() {
        var model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        let newOffset = model.applyMeasurements([0: 0.5, 4: 2.0], anchorPage: 2, offsetWithinAnchorPage: 0)
        // Only the page-0 shrink (-250) sits above the anchor.
        #expect(isClose(newOffset, 550))
        #expect(isClose(model.height(forPage: 4), 600))
    }

    @Test("an untouched first screen stays anchored at zero")
    func initialAnchorStaysPut() {
        var model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        #expect(isClose(model.applyMeasurements([0: 1.0], anchorPage: 0, offsetWithinAnchorPage: 0), 0))
        #expect(isClose(model.applyMeasurements([3: 0.25], anchorPage: 0, offsetWithinAnchorPage: 0), 0))
    }

    @Test("invalid measurements are ignored")
    func invalidMeasurementsIgnored() {
        var model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        let newOffset = model.applyMeasurements(
            [-1: 1.0, 99: 1.0, 3: -2],
            anchorPage: 4,
            offsetWithinAnchorPage: 10
        )
        #expect(isClose(newOffset, 1610))
        #expect(isClose(model.contentHeight, 4000))
    }

    @Test("a viewport width change re-bases heights and keeps the anchor stationary")
    func viewportWidthChangeKeepsAnchor() {
        var model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        model.applyMeasurements([0: 0.5], anchorPage: 0, offsetWithinAnchorPage: 0)
        // Widen to 600: page 0 -> 300 (aspect kept), estimates -> 800.
        let newOffset = model.updateViewportWidth(600, anchorPage: 1, offsetWithinAnchorPage: 200)
        #expect(isClose(model.height(forPage: 0), 300))
        #expect(isClose(model.height(forPage: 1), 800))
        #expect(isClose(newOffset, 500))
        #expect(isClose(model.contentHeight, 300 + 9 * 800))
    }

    @Test("a single-page document stays one slot tall at any offset")
    func singlePageDocument() {
        var model = StripLayoutModel(pageCount: 1, viewportWidth: width)
        #expect(model.activeRange(contentOffset: 0, viewportHeight: viewportHeight) == 0 ..< 1)
        #expect(model.activeRange(contentOffset: 9999, viewportHeight: viewportHeight) == 0 ..< 1)
        #expect(model.firstVisiblePage(atY: 9999) == 0)
        #expect(isClose(model.applyMeasurements([0: 2.0], anchorPage: 0, offsetWithinAnchorPage: 0), 0))
        #expect(isClose(model.height(forPage: 0), 600))
    }

    @Test("offset within page is captured against the current layout")
    func offsetWithinPageCapture() {
        let model = StripLayoutModel(pageCount: 10, viewportWidth: width)
        #expect(isClose(model.offsetWithinPage(pageIndex: 2, contentOffset: 1000), 200))
    }

    private func isClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        abs(a - b) < tolerance
    }
}
