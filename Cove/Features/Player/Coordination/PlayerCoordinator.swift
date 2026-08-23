import AppKit
import SourceKit

/// Assembles and owns the v1 player window (bridge + mpv core + view model
/// + window controller). Single-window policy: opening another video
/// replaces the current one — `close()` synchronously runs
/// `windowWillClose`, which tears the old mpv handle and stream bridge
/// down in the required order before the new session is built.
@MainActor
final class PlayerCoordinator {
    private var windowController: PlayerWindowController?

    var onError: ((_ error: Error, _ title: String) -> Void)?
    var onMessageError: ((_ message: String, _ title: String) -> Void)?

    func open(item: ContentItem, reader: @escaping VideoStreamBridge.RangedReader) {
        windowController?.window?.close()
        let bridge = VideoStreamBridge(path: item.path, size: item.size, reader: reader)
        do {
            let core = try MPVPlayerCore(bridge: bridge)
            let viewModel = PlayerViewModel(controller: core)
            core.onEvent = { [weak viewModel] event in viewModel?.apply(event) }
            viewModel.onError = { [weak self] detail in
                self?.onMessageError?("播放中断：\(detail)", "播放失败")
            }
            let controller = PlayerWindowController(item: item, core: core, viewModel: viewModel)
            windowController = controller
            controller.onClose = { [weak self] in self?.windowController = nil }
            controller.show()
        } catch {
            bridge.detach()
            onError?(error, "打开视频失败")
        }
    }
}

extension MPVPlayerCore: PlayerPlaybackControlling {}
