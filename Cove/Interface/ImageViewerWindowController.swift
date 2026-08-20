import AppKit

/// Read-pipeline probe: shows an image loaded from the NAS at full size in a
/// plain window. Deliberately no caching, downscaling or preloading in v0.
@MainActor
final class ImageViewerWindowController: NSWindowController {
    init(image: NSImage, name: String) {
        let maxSize = NSSize(width: 1200, height: 800)
        var windowSize = image.size
        if windowSize.width <= 0 || windowSize.height <= 0 {
            windowSize = NSSize(width: 400, height: 300)
        } else if windowSize.width > maxSize.width || windowSize.height > maxSize.height {
            let scale = min(maxSize.width / windowSize.width, maxSize.height / windowSize.height)
            windowSize = NSSize(
                width: floor(windowSize.width * scale),
                height: floor(windowSize.height * scale)
            )
        }

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = name
        window.contentView = imageView
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
