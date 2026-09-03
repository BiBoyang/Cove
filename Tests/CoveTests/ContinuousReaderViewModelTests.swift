import CoreGraphics
import Foundation
import ReaderKit
import Testing
import TraceKit

@testable import Cove

@Suite("Continuous reader view model")
@MainActor
struct ContinuousReaderViewModelTests {
    private func makeViewModel(
        pages: Int = 20,
        startIndex: Int = 0,
        loader: RecordingStripLoader
    ) -> ContinuousReaderViewModel {
        ContinuousReaderViewModel(
            pages: (1...pages).map { ReaderPage(id: "\($0)", title: "\($0)") },
            startIndex: startIndex,
            loader: loader,
            logger: TraceLogger(category: "StripTests")
        )
    }

    @Test("the initial viewport creates exactly the active window's slots")
    func initialWindowCreatesSlots() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        var creates: [[Int]] = []
        vm.onSlotsChanged = { creates.append($0.create) }

        vm.updateViewport(width: 300, height: 550)

        // Estimated height 400 at width 300: visible + 3 screens = 0..<6.
        #expect(creates == [[0, 1, 2, 3, 4, 5]])
    }

    @Test("scrolling destroys slots outside the window and creates the newcomers")
    func windowScrollsCreateAndDestroy() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        var events: [(create: [Int], destroy: [Int])] = []
        vm.onSlotsChanged = { events.append($0) }
        vm.updateViewport(width: 300, height: 550)

        vm.updateScrollOffset(3050)

        #expect(events.count == 2)
        #expect(events[1].destroy == [0, 1, 2])
        // ±3 screens of 550pt span ~9.6 estimated pages: 3..<14 resident.
        #expect(events[1].create == [6, 7, 8, 9, 10, 11, 12, 13])
    }

    @Test("a destroyed slot's late image never lands", .timeLimit(.minutes(1)))
    func destroyedSlotLateImageNeverLands() async throws {
        let loader = RecordingStripLoader(delay: .milliseconds(250))
        let vm = makeViewModel(loader: loader)
        var images: [Int] = []
        vm.onSlotImage = { index, _ in images.append(index) }
        vm.updateViewport(width: 300, height: 550)

        // Jump far in one step before page 2's load returns: the slot is
        // destroyed and its task cancelled, and no later window (even after
        // the relayout the surviving slots trigger) comes near page 2.
        vm.updateScrollOffset(6000)

        try await Task.sleep(for: .milliseconds(350))
        #expect(!images.contains(2))
        #expect(await loader.callCount(for: 2) == 1)
    }

    @Test("a re-created slot discards the previous generation's result", .timeLimit(.minutes(1)))
    func recreatedSlotDiscardsStaleGeneration() async throws {
        let loader = RecordingStripLoader(delay: .milliseconds(120))
        let vm = makeViewModel(loader: loader)
        var images: [Int] = []
        vm.onSlotImage = { index, _ in images.append(index) }
        vm.updateViewport(width: 300, height: 550)

        vm.updateScrollOffset(3000) // destroy page 2 before its load lands
        vm.updateScrollOffset(0)    // re-create: fresh generation, new task

        try await waitUntil { images.contains(2) }
        try await Task.sleep(for: .milliseconds(200))
        // Exactly one landing — the stale first-generation task was
        // cancelled on destroy and its result would be discarded anyway.
        #expect(images.filter { $0 == 2 }.count == 1)
        #expect(await loader.callCount(for: 2) == 2)
    }

    @Test("measurements land as one anchored batch", .timeLimit(.minutes(1)))
    func measurementsLandAsAnchoredBatch() async throws {
        let vm = makeViewModel(loader: RecordingStripLoader(delay: .milliseconds(10)))
        var images = 0
        var relayouts: [CGFloat] = []
        vm.onSlotImage = { _, _ in images += 1 }
        vm.onRelayout = { relayouts.append($0) }
        vm.updateViewport(width: 300, height: 550)

        // Six resident slots measure at aspect 1.0 (300pt); the other 14
        // pages stay at the 400pt estimate.
        try await waitUntil { images == 6 }
        try await waitUntil { abs(vm.contentHeight - 7400) < 0.01 }
        #expect(!relayouts.isEmpty)
        // Anchor was page 0 at offset 0: the viewport does not move.
        #expect(abs((relayouts.last ?? -1) - 0) < 0.01)
    }

    @Test("the current page follows scrolling and reports its index")
    func currentPageFollowsScrolling() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        var reported: [Int] = []
        var progress: [String] = []
        vm.onPageChanged = { reported.append($0) }
        vm.onStateChange = { progress.append($0.progressText) }
        vm.updateViewport(width: 300, height: 550)

        vm.updateScrollOffset(850)

        #expect(reported == [2])
        #expect(vm.currentPage == 2)
        #expect(progress.last == "3/20")
    }

    @Test("the warm window covers one screen ahead and only re-emits on change")
    func warmWindowCoverage() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        var emissions: [[Int]] = []
        vm.onWarmWindow = { emissions.append($0) }
        vm.updateViewport(width: 300, height: 550)

        vm.updateScrollOffset(0) // unchanged: no re-emit
        vm.updateScrollOffset(810)

        #expect(emissions == [[2], [4]])
    }

    @Test("a width change rebases heights under the viewport anchor")
    func widthChangeKeepsAnchor() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        var relayouts: [CGFloat] = []
        vm.onRelayout = { relayouts.append($0) }
        vm.updateViewport(width: 300, height: 550)
        vm.updateScrollOffset(810) // page 2, 10pt below its top

        vm.updateViewport(width: 600, height: 550)

        // New layout: page 2 top at 1600; the 10pt within-page offset holds.
        #expect(relayouts.count == 1)
        #expect(abs((relayouts.first ?? -1) - 1610) < 0.01)
        #expect(abs(vm.contentHeight - 16_000) < 0.01)
        #expect(vm.currentPage == 2)
    }

    @Test("zooming rebases the layout width under the same viewport anchor")
    func zoomKeepsAnchor() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        var relayouts: [CGFloat] = []
        var zooms: [CGFloat] = []
        vm.onRelayout = { relayouts.append($0) }
        vm.onZoomChange = { zooms.append($0) }
        vm.updateViewport(width: 300, height: 550)
        vm.updateScrollOffset(810) // page 2, 10pt below its top

        vm.zoomIn() // 1 → 1.25: effective width 375, estimated height 500

        // Page 2's top moves to 1000; the 10pt within-page offset holds.
        #expect(zooms == [1.25])
        #expect(relayouts.count == 1)
        #expect(abs((relayouts.first ?? -1) - 1010) < 0.01)
        #expect(abs(vm.contentWidth - 375) < 0.01)
        #expect(abs(vm.height(forPage: 0) - 500) < 0.01)
        #expect(vm.currentPage == 2)
    }

    @Test("zoom steps clamp at both ends and reset returns to fit-width")
    func zoomClampsAndResets() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        var zooms: [CGFloat] = []
        vm.onZoomChange = { zooms.append($0) }
        vm.updateViewport(width: 300, height: 550)

        vm.zoomOut() // already at the floor: no-op
        for _ in 0 ..< 5 { vm.zoomIn() } // 1.25, 1.5, 2, then clamped
        #expect(zooms == [1.25, 1.5, 2])
        #expect(vm.zoomScale == 2)
        #expect(abs(vm.height(forPage: 0) - 800) < 0.01)

        vm.resetZoom()
        #expect(zooms.last == 1)
        #expect(abs(vm.height(forPage: 0) - 400) < 0.01)
    }

    @Test("a zoom set before the first layout applies at creation time")
    func zoomBeforeViewport() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        vm.zoomIn()

        vm.updateViewport(width: 300, height: 550)

        #expect(abs(vm.contentWidth - 375) < 0.01)
        #expect(abs(vm.height(forPage: 0) - 500) < 0.01)
    }

    @Test("scrollToPage jumps to the page's top edge and clamps out-of-range indices")
    func scrollToPageJumpsAndClamps() {
        let vm = makeViewModel(loader: RecordingStripLoader())
        var scrolls: [CGFloat] = []
        vm.onScrollTo = { scrolls.append($0) }
        vm.updateViewport(width: 300, height: 550)

        vm.scrollToPage(5)
        #expect(scrolls == [2000]) // 5 × 400 estimated height
        #expect(vm.currentPage == 5)
        #expect(vm.state.progressText == "6/20")

        vm.scrollToPage(99) // clamps to the last page
        #expect(scrolls.last == 7600)
        #expect(vm.currentPage == 19)

        vm.scrollToPage(-3) // clamps to the first page
        #expect(scrolls.last == 0)
        #expect(vm.currentPage == 0)
    }

    @Test("the start page's offset is exposed under the all-estimated layout")
    func startContentOffsetReflectsStartIndex() {
        let vm = makeViewModel(startIndex: 3, loader: RecordingStripLoader())
        vm.updateViewport(width: 300, height: 550)

        #expect(abs(vm.startContentOffset - 1200) < 0.01)
    }

    @Test("teardown discards in-flight results", .timeLimit(.minutes(1)))
    func tearDownDiscardsResults() async throws {
        let vm = makeViewModel(loader: RecordingStripLoader(delay: .milliseconds(50)))
        var images = 0
        vm.onSlotImage = { _, _ in images += 1 }
        vm.updateViewport(width: 300, height: 550)

        vm.tearDown()

        try await Task.sleep(for: .milliseconds(120))
        #expect(images == 0)
    }
}

/// Loader double: records requested indices, returns a tiny image carrying
/// a 1:1 (300×300) display size after a configurable delay.
private actor RecordingStripLoader: ReaderPageLoading {
    private var calls: [Int] = []
    private let delay: Duration

    init(delay: Duration = .milliseconds(20)) {
        self.delay = delay
    }

    func load(pageAt index: Int) async throws -> ReaderLoadedImage {
        calls.append(index)
        try await Task.sleep(for: delay)
        return ReaderLoadedImage(image: makeStripImage(), size: CGSize(width: 300, height: 300))
    }

    func callCount(for index: Int) -> Int {
        calls.filter { $0 == index }.count
    }
}

private func makeStripImage() -> CGImage {
    let bytes = [UInt8](repeating: 0xFF, count: 4)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

/// Polls `condition` on the main actor until it holds, yielding between
/// checks so queued main-actor continuations can run. Throws (and thus
/// fails the test) on timeout instead of hanging.
@MainActor
private func waitUntil(
    _ message: @autoclosure () -> String = "condition not met before timeout",
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        if ContinuousClock.now > deadline {
            throw StripWaitTimeout(message: message())
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct StripWaitTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
