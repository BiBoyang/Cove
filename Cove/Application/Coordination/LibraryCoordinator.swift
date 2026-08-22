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

    private let serverListViewModel = ServerListViewModel()
    private let shareGridViewModel = ShareGridViewModel()
    private let browserViewModel = BrowserViewModel()

    let serverListViewController: ServerListViewController
    let shareGridViewController: ShareGridViewController
    let browserViewController: BrowserViewController

    private var currentServer: ServerConfig?
    private var currentShare: String?
    private var pathStack: [String] = ["/"]
    private var activeAddServerSheet: AddServerSheetController?
    private var navigationGeneration = 0
    private var activeTask: Task<Void, Never>?

    var hostWindowProvider: (() -> NSWindow?)?
    var onShowDetail: ((NSViewController) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onError: ((_ error: Error, _ title: String) -> Void)?
    var onMessageError: ((_ message: String, _ title: String) -> Void)?
    var onUnsupportedFile: ((_ name: String) -> Void)?

    init(sessionService: SMBSessionService, cache: CacheStore, readerCoordinator: ReaderCoordinator) {
        self.sessionService = sessionService
        self.cache = cache
        self.readerCoordinator = readerCoordinator
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
        shareGridViewController.onOpenShare = { [weak self] in self?.openShare($0) }
        browserViewController.onOpenDirectory = { [weak self] in self?.navigateInto($0) }
        browserViewController.onOpenImage = { [weak self] in self?.openReader(forImageAt: $0) }
        browserViewController.onOpenComic = { [weak self] in self?.openComicReader(at: $0) }
        browserViewController.onUnsupportedFile = { [weak self] in self?.onUnsupportedFile?($0) }
        browserViewController.onGoUp = { [weak self] in self?.goBack() }
        readerCoordinator.onError = { [weak self] in self?.onError?($0, $1) }
        readerCoordinator.onMessageError = { [weak self] in self?.onMessageError?($0, $1) }
    }

    private func wirePreheat() {
        sessionService.onPreheatConnectionChanged = { connection in
            if let connection {
                PreheatService.shared.connectionReady(source: connection.source, share: connection.share)
            } else {
                PreheatService.shared.connectionClosed()
            }
        }
        PreheatService.shared.displayWidthProvider = {
            let screen = NSScreen.main
            return max(1, Int(((screen?.frame.width ?? 1440) * (screen?.backingScaleFactor ?? 2)).rounded()))
        }
    }

    private func beginNavigation() -> Int {
        navigationGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        readerCoordinator.cancelPendingOpen()
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
        pathStack = ["/"]
        onTitleChange?("Cove")
        browserViewController.thumbnailProvider = nil
        shareGridViewModel.showPlaceholder("双击左侧服务器以连接")
        onShowDetail?(shareGridViewController)
        activeTask = Task { await sessionService.disconnect() }
    }

    private func enumerateShares(of server: ServerConfig) {
        let generation = beginNavigation()
        currentServer = server
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
                pathStack = ["/"]
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
        pathStack.append(path)
        activeTask = Task {
            do {
                try await loadDirectory(at: path, generation: generation)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == navigationGeneration else { return }
                pathStack.removeLast()
                onError?(error, "打开目录失败")
            }
        }
    }

    private func goBack() {
        guard pathStack.count > 1 else {
            backToShareGrid()
            return
        }
        let generation = beginNavigation()
        let popped = pathStack.removeLast()
        let target = pathStack.last ?? "/"
        activeTask = Task {
            do {
                try await loadDirectory(at: target, generation: generation)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == navigationGeneration else { return }
                pathStack.append(popped)
                onError?(error, "打开目录失败")
            }
        }
    }

    private func backToShareGrid() {
        _ = beginNavigation()
        currentShare = nil
        pathStack = ["/"]
        onTitleChange?(currentServer?.displayName ?? "Cove")
        browserViewController.thumbnailProvider = nil
        onShowDetail?(shareGridViewController)
        activeTask = Task { await sessionService.disconnect() }
    }

    private func loadDirectory(at path: String, generation: Int) async throws {
        let items = try await sessionService.list(at: path)
        guard generation == navigationGeneration else { throw CancellationError() }
        let title = path == "/" ? (currentShare ?? "/") : (path as NSString).lastPathComponent
        browserViewModel.display(items: items, path: path, title: title)
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
            fileReader: makeFileReader()
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
            isSourceCurrent: { [weak self] in self?.sessionService.currentSourceID == sourceID }
        )
    }

    private func makeFileReader() -> @Sendable (String) async throws -> Data {
        sessionService.makeFileReader()
    }
}
