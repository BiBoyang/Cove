import CoreGraphics
import Testing

@testable import Cove

@Suite("Paged zoom layout")
struct PagedZoomLayoutTests {
    // MARK: fit rect

    @Test("landscape image in landscape window fits by width")
    func landscapeImageLandscapeWindow() {
        let rect = PagedZoomLayout.fittedRect(
            imageSize: CGSize(width: 2000, height: 1000),
            containerSize: CGSize(width: 1000, height: 800)
        )
        // Width-limited: scale 0.5 → 1000 × 500, centered vertically.
        #expect(rect == CGRect(x: 0, y: 150, width: 1000, height: 500))
    }

    @Test("portrait image in landscape window fits by height")
    func portraitImageLandscapeWindow() {
        let rect = PagedZoomLayout.fittedRect(
            imageSize: CGSize(width: 1000, height: 2000),
            containerSize: CGSize(width: 1000, height: 800)
        )
        // Height-limited: scale 0.4 → 400 × 800, centered horizontally.
        #expect(rect == CGRect(x: 300, y: 0, width: 400, height: 800))
    }

    @Test("landscape image in portrait window fits by width")
    func landscapeImagePortraitWindow() {
        let rect = PagedZoomLayout.fittedRect(
            imageSize: CGSize(width: 2000, height: 1000),
            containerSize: CGSize(width: 600, height: 1000)
        )
        // Width-limited: scale 0.3 → 600 × 300, centered vertically.
        #expect(rect == CGRect(x: 0, y: 350, width: 600, height: 300))
    }

    @Test("portrait image in portrait window fits by height")
    func portraitImagePortraitWindow() {
        let rect = PagedZoomLayout.fittedRect(
            imageSize: CGSize(width: 1000, height: 2000),
            containerSize: CGSize(width: 600, height: 1000)
        )
        // Height-limited: scale 0.5 → 500 × 1000, centered horizontally.
        #expect(rect == CGRect(x: 50, y: 0, width: 500, height: 1000))
    }

    @Test("empty image yields an empty centered rect")
    func emptyImage() {
        let rect = PagedZoomLayout.fittedRect(
            imageSize: .zero, containerSize: CGSize(width: 800, height: 600)
        )
        #expect(rect.isEmpty)
        #expect(rect.midX == 400 && rect.midY == 300)
    }

    // MARK: tier steps

    @Test("tier steps up through the ladder and clamps at 300%")
    func stepUpClamp() {
        #expect(PagedZoomLayout.stepUp(from: 1) == 1.5)
        #expect(PagedZoomLayout.stepUp(from: 1.5) == 2)
        #expect(PagedZoomLayout.stepUp(from: 2) == 3)
        #expect(PagedZoomLayout.stepUp(from: 3) == 3)
    }

    @Test("tier steps down through the ladder and clamps at 100%")
    func stepDownClamp() {
        #expect(PagedZoomLayout.stepDown(from: 3) == 2)
        #expect(PagedZoomLayout.stepDown(from: 2) == 1.5)
        #expect(PagedZoomLayout.stepDown(from: 1.5) == 1)
        #expect(PagedZoomLayout.stepDown(from: 1) == 1)
    }

    // MARK: frame + pan clamp

    @Test("tier 1 frame equals the fitted centered rect regardless of pan")
    func tier1IsFit() {
        let image = CGSize(width: 2000, height: 1000)
        let container = CGSize(width: 1000, height: 800)
        let fit = PagedZoomLayout.fittedRect(imageSize: image, containerSize: container)
        let frame = PagedZoomLayout.imageFrame(
            imageSize: image, containerSize: container, tier: 1,
            panOffset: CGPoint(x: 500, y: -500) // pan ignored at fit
        )
        #expect(frame == fit)
    }

    @Test("zoomed frame covers the window with zero pan")
    func zoomedCoversContainer() {
        let frame = PagedZoomLayout.imageFrame(
            imageSize: CGSize(width: 2000, height: 1000),
            containerSize: CGSize(width: 1000, height: 800),
            tier: 2, panOffset: .zero
        )
        // Fit was 1000 × 500 → 2000 × 1000, centered.
        #expect(frame == CGRect(x: -500, y: -100, width: 2000, height: 1000))
    }

    @Test("pan clamps at the window edges on the oversized axis only")
    func panClampAtEdges() {
        let frameSize = CGSize(width: 3000, height: 400)
        let container = CGSize(width: 1000, height: 800)
        // X slack = 1000, Y smaller than container → pinned to 0.
        #expect(
            PagedZoomLayout.clampedPan(
                CGPoint(x: 5000, y: 999), frameSize: frameSize, containerSize: container
            ) == CGPoint(x: 1000, y: 0)
        )
        #expect(
            PagedZoomLayout.clampedPan(
                CGPoint(x: -5000, y: -999), frameSize: frameSize, containerSize: container
            ) == CGPoint(x: -1000, y: 0)
        )
        // In-range pan passes through.
        #expect(
            PagedZoomLayout.clampedPan(
                CGPoint(x: 250, y: 0), frameSize: frameSize, containerSize: container
            ) == CGPoint(x: 250, y: 0)
        )
    }

    @Test("a clamped pan keeps the image covering the container")
    func clampedFrameCovers() {
        let image = CGSize(width: 2000, height: 1000)
        let container = CGSize(width: 1000, height: 800)
        let frame = PagedZoomLayout.imageFrame(
            imageSize: image, containerSize: container, tier: 3,
            panOffset: CGPoint(x: -100000, y: 100000)
        )
        #expect(frame.minX <= 0 && frame.maxX >= container.width)
        #expect(frame.minY <= 0 && frame.maxY >= container.height)
    }
}
