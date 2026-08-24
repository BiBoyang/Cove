import Foundation
import SourceKit

/// Presentation state for the directory browser.
@MainActor
final class BrowserViewModel {
    /// Toolbar preheat button presentation.
    enum PreheatButtonState: Sendable, Equatable {
        /// No share connected: button disabled.
        case unavailable
        /// Idle; clicking starts the preheat.
        case ready
        /// Running; `total` is 0 while the directory is still enumerating.
        case preheating(completed: Int, total: Int, bytesPerSecond: Double)
        /// Queue drained; stays until the user navigates or clicks.
        /// `truncatedAtCap` is non-nil when enumeration hit the file cap,
        /// so "finished" does not imply the whole subtree was preheated.
        case finished(failed: Int, truncatedAtCap: Int?)
    }

    /// Toolbar download-to-vault presentation; nil means idle (nothing
    /// shown).
    enum DownloadState: Sendable, Equatable {
        /// Running; `file` is the name currently being downloaded.
        case running(completed: Int, total: Int, file: String)
        /// Terminal summary; stays until the next navigation or download.
        case finished(String)
    }

    struct State: Sendable {
        let items: [ContentItem]
        let path: String
        let title: String
        let canGoUp: Bool
        let preheat: PreheatButtonState
        let download: DownloadState?
    }

    private(set) var state = State(
        items: [], path: "", title: "", canGoUp: false, preheat: .unavailable, download: nil
    )

    var onStateChange: ((State) -> Void)? {
        didSet { onStateChange?(state) }
    }

    /// Async progress source for the directory preheat, injected by the
    /// coordinator; polled on the main actor while monitoring is active.
    /// A nil result means the service dropped the preheat (navigation,
    /// disconnect, enumeration failure) and monitoring stops.
    var preheatProgressProvider: (() async -> PreheatService.DirectoryPreheatProgress?)?

    /// How often the preheat progress provider is polled.
    private static let preheatPollInterval: Duration = .milliseconds(500)
    private var preheatPollTask: Task<Void, Never>?

    var imageItems: [ContentItem] {
        state.items.filter { $0.fileType == .image }
    }

    var videoItems: [ContentItem] {
        state.items.filter { $0.fileType == .video }
    }

    func item(atPath path: String) -> ContentItem? {
        state.items.first { $0.path == path }
    }

    func display(items: [ContentItem], path: String, title: String) {
        preheatPollTask?.cancel()
        preheatPollTask = nil
        state = State(
            items: Self.visibleItems(from: items),
            path: path,
            title: title,
            canGoUp: true,
            preheat: .ready,
            // Navigation ends any download presentation; the download task
            // itself is the coordinator's business.
            download: nil
        )
        onStateChange?(state)
    }

    // MARK: - Download-to-vault presentation

    /// Reflects one vault-download progress tick (driven directly by
    /// VaultService callbacks — no polling needed).
    func downloadProgress(completed: Int, total: Int, file: String) {
        setDownload(.running(completed: completed, total: total, file: file))
    }

    /// Terminal download summary ("下载完成：3 个文件" / "下载已取消").
    func downloadFinished(_ summary: String) {
        setDownload(.finished(summary))
    }

    private func setDownload(_ download: DownloadState?) {
        guard state.download != download else { return }
        state = State(
            items: state.items,
            path: state.path,
            title: state.title,
            canGoUp: state.canGoUp,
            preheat: state.preheat,
            download: download
        )
        onStateChange?(state)
    }

    /// Vault browsing has no preheat pipeline; the coordinator marks the
    /// button unavailable there and restores it for SMB shares.
    func setPreheatAvailable(_ available: Bool) {
        setPreheat(available ? .ready : .unavailable)
    }

    /// Starts polling the preheat progress provider and reflecting it into
    /// `state.preheat`. Called by the coordinator right after it starts a
    /// directory preheat.
    func startPreheatMonitoring() {
        preheatPollTask?.cancel()
        preheatPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let provider = self.preheatProgressProvider else { return }
                let progress = await provider()
                guard !Task.isCancelled else { return }
                guard let progress else {
                    // Service-side cancel/failure: back to idle.
                    self.setPreheat(.ready)
                    return
                }
                self.applyPreheatProgress(progress)
                if progress.isComplete { return }
                try? await Task.sleep(for: Self.preheatPollInterval)
            }
        }
    }

    /// Stops polling and returns the button to the idle state. Called when
    /// the user cancels via the button; `display` also resets on its own.
    func stopPreheatMonitoring() {
        preheatPollTask?.cancel()
        preheatPollTask = nil
        setPreheat(.ready)
    }

    private func applyPreheatProgress(_ progress: PreheatService.DirectoryPreheatProgress) {
        if progress.isComplete {
            setPreheat(.finished(failed: progress.failed, truncatedAtCap: progress.truncatedAtCap))
        } else {
            setPreheat(.preheating(
                completed: progress.total - progress.remaining,
                total: progress.total,
                bytesPerSecond: progress.throughputBytesPerSecond
            ))
        }
    }

    private func setPreheat(_ preheat: PreheatButtonState) {
        guard state.preheat != preheat else { return }
        state = State(
            items: state.items,
            path: state.path,
            title: state.title,
            canGoUp: state.canGoUp,
            preheat: preheat,
            download: state.download
        )
        onStateChange?(state)
    }

    static func visibleItems(from items: [ContentItem]) -> [ContentItem] {
        items
            .filter { !$0.isNoise }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return NaturalSort.areInIncreasingOrder(lhs.name, rhs.name)
            }
    }
}
