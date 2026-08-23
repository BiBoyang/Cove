import AppKit
import SourceKit

/// Step 1 spike player window: a plain NSWindow hosting the mpv render
/// layer, with keyboard-only controls (space = pause, arrows = seek,
/// Esc = close). The real player UI arrives in Step 2; this window exists
/// to prove libmpv + stream_cb + CAOpenGLLayer end to end.
@MainActor
final class SpikePlayerWindowController: NSWindowController, NSWindowDelegate {
    private let core: MPVPlayerCore
    /// Fired exactly once when the window closes; the coordinator uses it
    /// to drop its owning reference.
    var onClose: (() -> Void)?

    init(item: ContentItem, core: MPVPlayerCore) {
        self.core = core
        let window = SpikePlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = item.name
        window.center()
        window.contentView = VideoLayerHostView(videoLayer: core.videoLayer)
        super.init(window: window)
        window.delegate = self
        window.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        core.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Returns true when the key was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: // space
            core.togglePause()
            return true
        case 124: // right arrow
            core.seek(bySeconds: 10)
            return true
        case 123: // left arrow
            core.seek(bySeconds: -10)
            return true
        case 53: // esc
            window?.close()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        core.shutdown()
        onClose?()
        onClose = nil
    }
}

/// NSWindow subclass that routes unhandled key events to the controller
/// (the window is key and its content view is not an NSTextView, so plain
/// keyDown forwarding is enough for the spike controls).
private final class SpikePlayerWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }
}

/// Layer-hosting view for the mpv render layer: keeps the layer fitted to
/// the view bounds and in sync with the backing scale factor so mpv
/// renders at native resolution.
private final class VideoLayerHostView: NSView {
    private let videoLayer: CALayer

    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        // Assigning the layer first turns this into a layer-hosting view.
        layer = videoLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}
