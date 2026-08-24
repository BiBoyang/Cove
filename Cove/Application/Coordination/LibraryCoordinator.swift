import AppKit
import CacheKit
import SourceKit

/// Coordinates the Servers and Browser features over one SMB session.
/// A single generation covers all navigation branches so stale async results
/// can never overwrite the user's newest destination.
@MainActor
final class LibraryCoordinator {
    private let sessionService: SMBSessionService
    private let cache: CacheStore
    private let readerCoordinator: ReaderCoordinator
    private let preheatService: PreheatService
    private let vaultService: VaultService

    private let serverListViewModel = ServerListViewModel()
    private let shareGridViewModel = ShareGridViewModel()
    private let browserViewModel = BrowserViewModel()

    let serverListViewController: ServerListViewController
    let shareGridViewController: ShareGridViewController
    let browserViewController: BrowserViewController

    private var currentServer: ServerConfig?
    private var currentShare: String?
    /// True while the browser pane shows the vault (LocalFileSource)
    /// instead of an SMB share.
    private var browsingVault = false
    /// The single in-flight vault download; a second request is refused
    /// until it finishes or is cancelled.
    private var downloadTask: Task<Void, Never>?
    private var navigationPath = LibraryNavigationPath()
    private var activeAddServerSheet: AddServerSheetController?
    /// Owns the single v1 player window; a new video replaces it.
    private let playerCoordinator: PlayerCoordinator
    /// Owns the single PDF reader window; a new PDF replaces it.
    private let pdfReaderCoordinator: PdfReaderCoordinator
    private var navigationGeneration = 0
    private var activeTask: Task<Void, Never>?

    var hostWindowProvider: (() -> NSWindow?)?
    var onShowDetail: ((NSViewController) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onError: ((_ error: Error, _ title: String) -> Void)?
    var onMessageError: ((_ message: String, _ title: String) -> Void)?
    var onUnsupportedFile: ((_ name: String) -> Void)?

    init(
        sessionService: SMBSessionService,
        cache: CacheStore,
        readerCoordinator: ReaderCoordinator,
        preheatService: PreheatService,
        vaultService: VaultService,
        progressStore: PlaybackProgressStoring? = nil
    ) {
        self.sessionService = sessionService
        self.cache = cache
        self.readerCoordinator = readerCoordinator
        self.preheatService = preheatService
        self.vaultService = vaultService
        playerCoordinator = PlayerCoordinator(progressStore: progressStore)
        pdfReaderCoordinator = PdfReaderCoordinator(cache: cache)
        serverListViewController = ServerListViewController(viewModel: serverListViewModel)
        shareGridViewController = ShareGridViewController(viewModel: shareGridViewModel)
        browserViewController = BrowserViewController(viewModel: browserViewModel)
        wireCallbacks()
        wirePreheat()
    }

    func start() {
        serverListViewModel.update(servers: sessionService.servers)
        shareGridViewModel.showPlaceholder("双击左侧服务器以连接")
    }

    private func wireCallbacks() {
        serverListViewController.onAddServer = { [weak self] in self?.presentAddServerSheet() }
        serverListViewController.onConnect = { [weak self] in self?.enumerateShares(of: $0) }
        serverListViewController.onRemove = { [weak self] in self?.confirmRemoveServer($0) }
        serverListViewController.onOpenVault = { [weak self] in self?.openVault() }
        shareGridViewController.onOpenShare = { [weak self] in self?.openShare($0) }
        browserViewController.onOpenDirectory = { [weak self] in self?.navigateInto($0) }
        browserViewController.onOpenImage = { [weak self] in self?.openReader(forImageAt: $0) }
        browserViewController.onOpenComic = { [weak self] in self?.openComicReader(at: $0) }
        browserViewController.onOpenVideo = { [weak self] in self?.openPlayer(at: $0) }
        browserViewController.onOpenPdf = { [weak self] in self?.openPdfReader(at: $0) }
        browserViewController.onDownloadToVault = { [weak self] in self?.downloadToVault($0) }
        browserViewController.onDeleteFromVault = { [weak self] in self?.confirmDeleteFromVault($0) }
        browserViewController.onCancelDownload = { [weak self] in self?.cancelDownload() }
        browserViewController.onUnsupportedFile = { [weak self] in self?.onUnsupportedFile?($0) }
        browserViewController.onGoUp = { [weak self] in self?.goBack() }
        browserViewController.onPreheatTapped = { [weak self] in self?.toggleDirectoryPreheat() }
        readerCoordinator.onError = { [weak self] in self?.onError?($0, $1) }
        readerCoordinator.onMessageError = { [weak self] in self?.onMessageError?($0, $1) }
        playerCoordinator.onError = { [weak self] in self?.onError?($0, $1) }
        playerCoordinator.onMessageError = { [weak self] in self?.onMessageError?($0, $1) }
        pdfReaderCoordinator.onError = { [weak self] in self?.onError?($0, $1) }
        pdfReaderCoordinator.onMessageError = { [weak self] in self?.onMessageError?($0, $1) }
    }

    private func wirePreheat() {
        sessionService.onPreheatConnectionChanged = { [preheatService] connection in
            if let connection {
                preheatService.connectionReady(source: connection.source, share: connection.share)
            } else {
                preheatService.connectionClosed()
            }
        }
        preheatService.displayWidthProvider = {
            ScreenGeometry.mainScreenPixelWidth
        }
        browserViewModel.preheatProgressProvider = { [preheatService] in
            await preheatService.directoryPreheatProgress()
        }
    }

    /// Toolbar preheat button: toggles the on-demand preheat of the
    /// directory currently on screen (single level, .currentDirectory
    /// priority). Only meaningful with a share connected.
    private func toggleDirectoryPreheat() {
        if preheatService.isDirectoryPreheatActive {
            preheatService.cancelDirectoryPreheat()
            browserViewModel.stopPreheatMonitoring()
        } else {
            guard currentShare != nil else { return }
            preheatService.preheatDirectory(path: navigationPath.currentPath)
            browserViewModel.startPreheatMonitoring()
        }
    }

    private func beginNavigation() -> Int {
        navigationGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        readerCoordinator.cancelPendingOpen()
        pdfReaderCoordinator.cancelPendingOpen()
        // Directory preheats are tied to the directory on screen: any
        // navigation (switch folder, leave the share, open the reader)
        // cancels the queue without touching userFolder work.
        preheatService.cancelDirectoryPreheat()
        return navigationGeneration
    }

    private func presentAddServerSheet() {
        guard let window = hostWindowProvider?() else { return }
        let sheet = AddServerSheetController()
        activeAddServerSheet = sheet
        sheet.beginSheet(on: window) { [weak self] result in
            guard let self, let result else {
                self?.activeAddServerSheet = nil
                return
            }
            do {
                try sessionService.addServer(host: result.host, username: result.username, password: result.password)
                serverListViewModel.update(servers: sessionService.servers)
            } catch {
                onError?(error, "保存服务器失败")
            }
            activeAddServerSheet = nil
        }
    }

    private func confirmRemoveServer(_ server: ServerConfig) {
        guard let window = hostWindowProvider?() else { return }
        let alert = NSAlert()
        alert.messageText = "删除服务器“\(server.displayName)”？"
        alert.informativeText = "将同时删除保存的密码，此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try sessionService.removeServer(id: server.id)
                serverListViewModel.update(servers: sessionService.servers)
                if currentServer?.id == server.id { resetAfterRemovingCurrentServer() }
            } catch {
                onError?(error, "删除服务器失败")
            }
        }
    }

    private func resetAfterRemovingCurrentServer() {
        _ = beginNavigation()
        currentServer = nil
        currentShare = nil
        browsingVault = false
        navigationPath.reset()
        onTitleChange?("Cove")
        browserViewController.thumbnailProvider = nil
        shareGridViewModel.showPlaceholder("双击左侧服务器以连接")
        onShowDetail?(shareGridViewController)
        activeTask = Task { await sessionService.disconnect() }
    }

    private func enumerateShares(of server: ServerConfig) {
        let generation = beginNavigation()
        currentServer = server
        browsingVault = false
        // Drop the previous share's thumbnail service so it is not kept
        // alive (or used) while the browser pane is off screen.
        browserViewController.thumbnailProvider = nil
        onShowDetail?(shareGridViewController)
        shareGridViewModel.showLoading()
        onTitleChange?(server.displayName)
        activeTask = Task {
            do {
                let shares = try await sessionService.enumerateShares(for: server.id)
                guard generation == navigationGeneration else { return }
                currentShare = nil
                shareGridViewModel.display(shares: shares)
            } catch {
                if Task.isCancelled { return }
                guard generation == navigationGeneration else { return }
                shareGridViewModel.showPlaceholder("获取共享列表失败，双击重试")
                onError?(error, "获取共享列表失败")
            }
        }
    }

    private func openShare(_ share: SMBShareInfo) {
        guard let server = currentServer else { return }
        let generation = beginNavigation()
        activeTask = Task {
            do {
                try await sessionService.connect(to: server, share: share.name)
                guard generation == navigationGeneration else { return }
                currentShare = share.name
                browsingVault = false
                browserViewController.browseMode = .remote
                navigationPath.reset()
                onTitleChange?("\(server.displayName) / \(share.name)")
                if let sourceID = sessionService.currentSourceID {
                    browserViewController.thumbnailProvider = ThumbnailService(
                        readFile: makeFileReader(), cache: cache, sourceID: sourceID
                    )
                }
                onShowDetail?(browserViewController)
                try await loadDirectory(at: "/", generation: generation)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == navigationGeneration else { return }
                onError?(error, "打开共享失败")
            }
        }
    }

    private func navigateInto(_ path: String) {
        let generation = beginNavigation()
        navigationPath.navigateInto(path)
        activeTask = Task {
            do {
                try await loadDirectory(at: path, generation: generation)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == navigationGeneration else { return }
                navigationPath.rollbackInto()
                onError?(error, "打开目录失败")
            }
        }
    }

    private func goBack() {
        switch navigationPath.backDestination {
        case .shareGrid:
            backToShareGrid()
        case .directory(let target):
            let generation = beginNavigation()
            let popped = navigationPath.goBack()
            activeTask = Task {
                do {
                    try await loadDirectory(at: target, generation: generation)
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    guard generation == navigationGeneration else { return }
                    navigationPath.restoreAfterFailedGoBack(popped)
                    onError?(error, "打开目录失败")
                }
            }
        }
    }

    private func backToShareGrid() {
        _ = beginNavigation()
        currentShare = nil
        browsingVault = false
        navigationPath.reset()
        onTitleChange?(currentServer?.displayName ?? "Cove")
        browserViewController.thumbnailProvider = nil
        onShowDetail?(shareGridViewController)
        activeTask = Task { await sessionService.disconnect() }
    }

    private func loadDirectory(at path: String, generation: Int) async throws {
        let items = try await sessionService.list(at: path)
        guard generation == navigationGeneration else { throw CancellationError() }
        let title = LibraryNavigationPath.browserTitle(
            forPath: path, shareName: browsingVault ? "本地仓库" : currentShare
        )
        browserViewModel.display(items: items, path: path, title: title)
        if browsingVault {
            // `display` resets the preheat button to ready; the vault has
            // no preheat pipeline, so keep it unavailable on every
            // navigation, not just on entry.
            browserViewModel.setPreheatAvailable(false)
        }
    }

    // MARK: - Vault

    /// Opens the vault as a virtual share: the same browser pipeline over a
    /// LocalFileSource, no network, no preheat, no thumbnails (the
    /// thumbnail pipeline would copy raw bytes into the original pool,
    /// which the vault red line forbids).
    private func openVault() {
        let generation = beginNavigation()
        browsingVault = true
        currentServer = nil
        currentShare = nil
        navigationPath.reset()
        onTitleChange?("本地仓库")
        browserViewController.thumbnailProvider = nil
        browserViewController.browseMode = .vault
        onShowDetail?(browserViewController)
        activeTask = Task {
            do {
                try await sessionService.connectLocal(LocalFileSource(root: vaultService.rootURL))
                guard generation == navigationGeneration else { return }
                try await loadDirectory(at: "/", generation: generation)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == navigationGeneration else { return }
                onError?(error, "打开本地仓库失败")
            }
        }
    }

    /// Downloads a file or folder (recursive, all types) into the vault.
    /// Progress goes straight into the browser toolbar via the view model;
    /// the task is cancellable from the same label.
    private func downloadToVault(_ item: ContentItem) {
        guard !browsingVault, let server = currentServer, let share = currentShare else { return }
        guard downloadTask == nil else {
            onMessageError?("已有下载任务在进行中，请等待完成或先取消。", "下载到本地仓库")
            return
        }
        let vaultService = self.vaultService
        let list = sessionService.makeLister()
        let read = sessionService.makeRangedFileReader()
        let serverLabel = server.displayName
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await vaultService.download(
                    item: item,
                    serverLabel: serverLabel,
                    share: share,
                    list: list,
                    read: read,
                    progress: { [weak self] progress in
                        self?.browserViewModel.downloadProgress(
                            completed: progress.completed,
                            total: progress.total,
                            file: progress.currentFile
                        )
                    }
                )
                downloadTask = nil
                var summary = "下载完成：\(result.downloaded) 个文件"
                if result.skipped > 0 { summary += "，跳过 \(result.skipped) 个未变更" }
                if result.truncated { summary += "（已达数量上限，部分内容未下载）" }
                browserViewModel.downloadFinished(summary)
                if !result.failedPaths.isEmpty {
                    onMessageError?("\(result.failedPaths.count) 个文件下载失败。", "下载到本地仓库")
                }
            } catch {
                downloadTask = nil
                if Task.isCancelled || error is CancellationError {
                    browserViewModel.downloadFinished("下载已取消")
                    return
                }
                browserViewModel.downloadFinished("下载中断")
                onError?(error, "下载到本地仓库失败")
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Deletes a vault item after confirmation. The wording must stay
    /// explicit that the NAS is never touched (task red line).
    private func confirmDeleteFromVault(_ item: ContentItem) {
        guard browsingVault, let window = hostWindowProvider?() else { return }
        let alert = NSAlert()
        alert.messageText = "从本地仓库删除“\(item.name)”？"
        alert.informativeText = "仅删除本地仓库中的副本，不会影响 NAS 上的文件。此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try vaultService.delete(vaultRelativePath: item.path)
            } catch {
                onError?(error, "从本地仓库删除失败")
                return
            }
            let generation = navigationGeneration
            let path = navigationPath.currentPath
            activeTask = Task {
                do {
                    try await self.loadDirectory(at: path, generation: generation)
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    guard generation == self.navigationGeneration else { return }
                    self.onError?(error, "刷新目录失败")
                }
            }
        }
    }


    private func openReader(forImageAt path: String) {
        guard let sourceID = sessionService.currentSourceID else {
            onMessageError?("当前共享已断开。", "打开阅读器失败")
            return
        }
        _ = beginNavigation()
        readerCoordinator.openDirectory(
            items: browserViewModel.imageItems,
            selectedPath: path,
            sourceID: sourceID,
            fileReader: makeFileReader(),
            // Vault red line: local bytes never enter the original pool.
            bypassOriginalPool: browsingVault
        )
    }

    private func openComicReader(at path: String) {
        guard let item = browserViewModel.item(atPath: path), let sourceID = sessionService.currentSourceID else {
            onMessageError?("无法定位漫画包，或当前共享已断开。", "打开漫画失败")
            return
        }
        _ = beginNavigation()
        readerCoordinator.openComic(
            item: item,
            sourceID: sourceID,
            fileReader: makeFileReader(),
            isSourceCurrent: { [weak self] in self?.sessionService.currentSourceID == sourceID },
            bypassOriginalPool: browsingVault
        )
    }

    /// Opens the PDF reader for a PDF file. The PdfReaderCoordinator owns
    /// the single PDF window; opening another PDF replaces it.
    private func openPdfReader(at path: String) {
        guard let item = browserViewModel.item(atPath: path), let sourceID = sessionService.currentSourceID else {
            onMessageError?("无法定位 PDF 文件，或当前共享已断开。", "打开 PDF 失败")
            return
        }
        _ = beginNavigation()
        pdfReaderCoordinator.open(
            item: item,
            sourceID: sourceID,
            fileReader: makeFileReader(),
            bypassOriginalPool: browsingVault
        )
    }

    private func makeFileReader() -> @Sendable (String) async throws -> Data {
        sessionService.makeFileReader()
    }

    /// Opens the player for a video file. The PlayerCoordinator owns the
    /// single player window; opening another video tears the previous
    /// session down first (window close shuts the mpv handle and the
    /// stream bridge down via `windowWillClose`).
    private func openPlayer(at path: String) {
        guard let item = browserViewModel.item(atPath: path) else {
            onMessageError?("无法定位视频文件。", "打开视频失败")
            return
        }
        playerCoordinator.open(
            item: item,
            sourceID: sessionService.currentSourceID,
            reader: sessionService.makeRangedFileReader()
        )
    }
}

/// Pure value-type navigation state for the library browser's path stack.
///
/// Factored out of LibraryCoordinator so the optimistic push/pop rules and
/// their failure rollbacks are unit-testable without AppKit or an SMB
/// session. The stack is always rooted at "/"; `goBack` from the root means
/// leaving the share (back to the share grid), which the coordinator turns
/// into a disconnect. The browser-pane title rule lives here too because it
/// is path semantics — the root shows the share name, a subdirectory its
/// folder name — while window titles involving the server display name stay
/// in the coordinator with the session state they read.
struct LibraryNavigationPath: Equatable, Sendable {
    private(set) var stack: [String] = ["/"]

    /// Where `goBack` leads from the current directory.
    enum BackDestination: Equatable, Sendable {
        /// At the share root: leaving the share, back to the share grid.
        case shareGrid
        /// The parent directory path to load.
        case directory(String)
    }

    var currentPath: String { stack.last ?? "/" }

    var backDestination: BackDestination {
        stack.count > 1 ? .directory(stack[stack.count - 2]) : .shareGrid
    }

    /// Optimistic push into a subdirectory; pair with `rollbackInto()` when
    /// the directory load fails.
    mutating func navigateInto(_ path: String) {
        stack.append(path)
    }

    /// Rolls back a failed `navigateInto`.
    mutating func rollbackInto() {
        if stack.count > 1 { stack.removeLast() }
    }

    /// Optimistic pop for `goBack`; returns the popped path so a failed
    /// parent load can restore it via `restoreAfterFailedGoBack(_:)`.
    /// Call only when `backDestination` is `.directory`.
    mutating func goBack() -> String {
        stack.removeLast()
    }

    /// Restores the path popped by `goBack()` after the parent load failed.
    mutating func restoreAfterFailedGoBack(_ popped: String) {
        stack.append(popped)
    }

    /// Back to a fresh share root (share switch, disconnect, reset).
    mutating func reset() {
        stack = ["/"]
    }

    /// Browser pane title for `path`: the share name at the root, the
    /// directory name below it.
    static func browserTitle(forPath path: String, shareName: String?) -> String {
        path == "/" ? (shareName ?? "/") : (path as NSString).lastPathComponent
    }
}

/// Screen geometry shared by the coordinators.
enum ScreenGeometry {
    /// Pixel width of the main screen's backing store, used as the display
    /// variant width for cache keys and decode budgets. Falls back to a
    /// 1440pt @2x screen when no main screen is attached.
    static var mainScreenPixelWidth: Int {
        let screen = NSScreen.main
        return max(1, Int(((screen?.frame.width ?? 1440) * (screen?.backingScaleFactor ?? 2)).rounded()))
    }
}
