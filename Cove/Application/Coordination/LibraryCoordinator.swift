import AppKit
import CacheKit
import SourceKit
import TraceKit

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
    private let shareOpenStore: ShareOpenStore
    private let pinStore: VaultPinStore

    private let serverListViewModel = ServerListViewModel()
    /// Internal (not private) so the enumeration-failure placeholder wiring
    /// is unit-testable, like `enumerateShares`. Built in `init` because its
    /// records lookup reads the share-open store.
    let shareGridViewModel: ShareGridViewModel
    private let browserViewModel = BrowserViewModel()

    let serverListViewController: ServerListViewController
    let shareGridViewController: ShareGridViewController
    let browserViewController: BrowserViewController
    let settingsPaneViewController: SettingsPaneViewController

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
    /// The single in-flight update check; a re-click while running is
    /// ignored until the alert lands.
    private var updateCheckTask: Task<Void, Never>?
    private let updateService = UpdateService()
    private var navigationGeneration = 0
    private var activeTask: Task<Void, Never>?
    private let logger = TraceLogger(category: "Library")

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
        preferencesViewModel: PreferencesViewModel,
        shareOpenStore: ShareOpenStore,
        pinStore: VaultPinStore = VaultPinStore(),
        progressStore: PlaybackProgressStoring? = nil
    ) {
        self.sessionService = sessionService
        self.cache = cache
        self.readerCoordinator = readerCoordinator
        self.preheatService = preheatService
        self.vaultService = vaultService
        self.shareOpenStore = shareOpenStore
        self.pinStore = pinStore
        playerCoordinator = PlayerCoordinator(progressStore: progressStore)
        pdfReaderCoordinator = PdfReaderCoordinator(cache: cache)
        shareGridViewModel = ShareGridViewModel(lastOpened: { [shareOpenStore] serverID, share in
            shareOpenStore.lastOpened(forServer: serverID, share: share)
        })
        serverListViewController = ServerListViewController(viewModel: serverListViewModel)
        shareGridViewController = ShareGridViewController(viewModel: shareGridViewModel)
        browserViewController = BrowserViewController(viewModel: browserViewModel)
        settingsPaneViewController = SettingsPaneViewController(viewModel: preferencesViewModel)
        wireCallbacks()
        wirePreheat()
    }

    func start() {
        serverListViewModel.update(servers: sessionService.servers)
        showIdlePlaceholderForCurrentServerList()
        refreshPins()
    }

    /// Idle detail-pane placeholder: first-run guidance with an add action
    /// when no servers exist, plain "connect" guidance otherwise.
    private func showIdlePlaceholderForCurrentServerList() {
        if sessionService.servers.isEmpty {
            shareGridViewModel.showEmptyServerGuidance()
        } else {
            shareGridViewModel.showIdlePlaceholder()
        }
    }

    private func wireCallbacks() {
        serverListViewController.onAddServer = { [weak self] in self?.presentAddServerSheet() }
        serverListViewController.onConnect = { [weak self] in self?.enumerateShares(of: $0) }
        serverListViewController.onEdit = { [weak self] in self?.presentEditServerSheet($0) }
        serverListViewController.onSwitchEndpoint = { [weak self] in self?.switchEndpoint(of: $0) }
        serverListViewController.onRemove = { [weak self] in self?.confirmRemoveServer($0) }
        serverListViewController.onOpenVault = { [weak self] in self?.openVault() }
        serverListViewController.onOpenSettings = { [weak self] in self?.showSettings() }
        shareGridViewController.onOpenShare = { [weak self] in self?.openShare($0) }
        shareGridViewController.onRetry = { [weak self] in self?.retryEnumeration() }
        shareGridViewController.onAddServer = { [weak self] in self?.presentAddServerSheet() }
        browserViewController.onOpenDirectory = { [weak self] in self?.navigateInto($0) }
        browserViewController.onOpenImage = { [weak self] in self?.openReader(forImageAt: $0) }
        browserViewController.onOpenComic = { [weak self] in self?.openComicReader(at: $0) }
        browserViewController.onOpenVideo = { [weak self] in self?.openPlayer(at: $0) }
        browserViewController.onOpenPdf = { [weak self] in self?.openPdfReader(at: $0) }
        browserViewController.onDownloadToVault = { [weak self] in self?.downloadToVault($0) }
        browserViewController.onDeleteFromVault = { [weak self] in self?.confirmDeleteFromVault($0) }
        browserViewController.onPinToSidebar = { [weak self] in self?.pinToSidebar($0) }
        browserViewController.onUnpinFromSidebar = { [weak self] in self?.unpinFromSidebar($0) }
        serverListViewController.onOpenPin = { [weak self] in self?.openVaultFolder(relativePath: $0) }
        serverListViewController.onSetAlias = { [weak self] in self?.presentPinAliasEditor(forPath: $0) }
        serverListViewController.onRemovePin = { [weak self] in self?.removePin(atPath: $0) }
        // Vault-root changes re-stat every pin target (decision 4). The
        // hook fires on any settings write; the re-check is ≤8 sync stats.
        vaultService.onVaultRootChanged = { [weak self] in self?.refreshPins() }
        browserViewController.onCancelDownload = { [weak self] in self?.cancelDownload() }
        browserViewController.onUnsupportedFile = { [weak self] in self?.onUnsupportedFile?($0) }
        browserViewController.onGoUp = { [weak self] in self?.goBack() }
        browserViewController.onPreheatTapped = { [weak self] in self?.toggleDirectoryPreheat() }
        settingsPaneViewController.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
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
        sheet.beginSheet(on: window) { [weak self] outcome in
            guard let self else {
                self?.activeAddServerSheet = nil
                return
            }
            defer { activeAddServerSheet = nil }
            guard case let .add(result) = outcome else { return }
            do {
                try sessionService.addServer(
                    host: result.host,
                    username: result.username,
                    password: result.password,
                    remoteHost: result.remoteHost
                )
                serverListViewModel.update(servers: sessionService.servers)
            } catch {
                onError?(error, "保存服务器失败")
            }
        }
    }

    /// Edits a stored server's optional remote address. Host, username,
    /// and password are untouched, so the sheet never asks for them.
    private func presentEditServerSheet(_ server: ServerConfig) {
        guard let window = hostWindowProvider?() else { return }
        let sheet = AddServerSheetController(editRemote: server)
        activeAddServerSheet = sheet
        sheet.beginSheet(on: window) { [weak self] outcome in
            guard let self else {
                self?.activeAddServerSheet = nil
                return
            }
            defer { activeAddServerSheet = nil }
            guard case let .editRemote(server, remoteHost) = outcome else { return }
            do {
                let updated = try sessionService.updateRemoteHost(remoteHost, for: server.id)
                serverListViewModel.update(servers: sessionService.servers)
                // Rewriting or clearing the remote address may leave the
                // connected session on an address the config no longer
                // selects; drop it and reconnect at the new selection.
                if currentServer?.id == server.id, updated.activeHost != server.activeHost {
                    activeTask = Task { await self.sessionService.disconnect() }
                    enumerateShares(of: updated)
                }
            } catch {
                onError?(error, "保存远程地址失败")
            }
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
                // The server's open records can never be shown again once
                // its id is gone; prune them instead of letting them rot.
                shareOpenStore.removeRecords(forServer: server.id)
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
        showIdlePlaceholderForCurrentServerList()
        onShowDetail?(shareGridViewController)
        activeTask = Task { await sessionService.disconnect() }
    }

    /// Flips the server's address (LAN ↔ remote), drops any live session
    /// still running on the old address, and reconnects by enumerating
    /// shares at the newly selected one. Internal (not private) so the
    /// disconnect/reconnect choreography is unit-testable, like
    /// `LibraryNavigationPath`.
    func switchEndpoint(of server: ServerConfig) {
        let updated: ServerConfig
        do {
            updated = try sessionService.switchEndpoint(of: server.id)
        } catch {
            onError?(error, "切换地址失败")
            return
        }
        serverListViewModel.update(servers: sessionService.servers)
        if currentServer?.id == server.id {
            // The live share session (and its preheat connection) still
            // runs on the old address; drop it so reader traffic cannot
            // keep flowing there after the flip. Enumeration opens its own
            // short-lived connection, so the two never contend.
            activeTask = Task { await sessionService.disconnect() }
        }
        enumerateShares(of: updated)
    }

    /// Enumerates the shares of a server at its active address and shows
    /// the share grid. Internal (not private) so the failure-guidance
    /// wiring is unit-testable, like `LibraryNavigationPath`.
    func enumerateShares(of server: ServerConfig) {
        let generation = beginNavigation()
        currentServer = server
        browsingVault = false
        serverListViewModel.setActiveDestination(.none)
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
                shareGridViewModel.display(shares: shares, serverID: server.id)
            } catch {
                if Task.isCancelled { return }
                guard generation == navigationGeneration else { return }
                // The placeholder owns the failure presentation (retry button,
                // remote-endpoint hint); no modal alert on top of it.
                logger.error("获取共享列表失败: \(error.localizedDescription)")
                shareGridViewModel.showEnumerationFailure(canSwitchToRemote: server.canSwitchToRemote)
            }
        }
    }

    /// Retries share enumeration for the server the grid failed on
    /// (placeholder retry button).
    private func retryEnumeration() {
        guard let server = currentServer else { return }
        enumerateShares(of: server)
    }

    private func openShare(_ share: SMBShareInfo) {
        guard let server = currentServer else { return }
        let generation = beginNavigation()
        activeTask = Task {
            do {
                try await sessionService.connect(to: server, share: share.name)
                guard generation == navigationGeneration else { return }
                currentShare = share.name
                // Record the open the moment the connection is established
                // (decision record: success only — a failed open writes
                // nothing; a later directory-load failure still counts as
                // an opened share).
                shareOpenStore.recordOpen(forServer: server.id, share: share.name)
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
                    // Keep the user's bearings: the folder just exited is
                    // scrolled (and selected) into view. Runs after the
                    // synchronous display→render, so the rows exist.
                    browserViewController.revealItem(atPath: popped)
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
        // Backing out of the vault lands on a server pane: sync the bar,
        // the same contract as enumerateShares/openVault/showSettings.
        serverListViewModel.setActiveDestination(.none)
        navigationPath.reset()
        onTitleChange?(currentServer?.displayName ?? "Cove")
        browserViewController.thumbnailProvider = nil
        // The grid reappears with the open record just written; re-assemble
        // the cards so the "last opened" lines are fresh.
        shareGridViewModel.refreshCards()
        onShowDetail?(shareGridViewController)
        activeTask = Task { await sessionService.disconnect() }
    }

    private func loadDirectory(at path: String, generation: Int) async throws {
        // Switch to the loading placeholder first: the listing clears (no
        // stale leftovers) and the scroll position resets via the path
        // change, so the arriving directory is anchored at the top.
        let title = LibraryNavigationPath.browserTitle(
            forPath: path, shareName: browsingVault ? "本地仓库" : currentShare
        )
        browserViewModel.beginLoading(path: path, title: title)
        let items = try await sessionService.list(at: path)
        guard generation == navigationGeneration else { throw CancellationError() }
        browserViewModel.display(items: items, path: path, title: title)
        if browsingVault {
            // `display` resets the preheat button to ready; the vault has
            // no preheat pipeline, so keep it unavailable on every
            // navigation, not just on entry.
            browserViewModel.setPreheatAvailable(false)
            // The "current pin" capsule follows the browsed subtree.
            serverListViewModel.setActivePinPath(
                ServerListViewModel.activePin(
                    forPath: path, pinnedPaths: pinStore.load().entries.map(\.path)
                )
            )
        } else {
            serverListViewModel.setActivePinPath(nil)
        }
    }

    // MARK: - Vault

    /// Opens the vault as a virtual share: the same browser pipeline over a
    /// LocalFileSource, no network, no preheat. Thumbnails are wired once
    /// the local source is connected, exactly like an SMB share. Unlike the
    /// reader (which keeps vault bytes out of the original pool), a
    /// thumbnail miss does copy the file's bytes into that pool — accepted
    /// for BUG-5 (2026-09-07): local reads are cheap and CacheKit bounds
    /// the pool by capacity/TTL.
    private func openVault(initialPath: String? = nil) {
        let generation = beginNavigation()
        browsingVault = true
        currentServer = nil
        serverListViewModel.setActiveDestination(.vault)
        currentShare = nil
        navigationPath.reset()
        onTitleChange?("本地仓库")
        // Drop the previous share's provider up front so it cannot serve
        // stale rows during the connect; the vault's own provider is
        // installed only after `connectLocal` succeeds (same ordering as
        // `openShare`).
        browserViewController.thumbnailProvider = nil
        browserViewController.browseMode = .vault
        onShowDetail?(browserViewController)
        activeTask = Task {
            do {
                try await sessionService.connectLocal(LocalFileSource(root: vaultService.rootURL))
                guard generation == navigationGeneration else { return }
                if let sourceID = sessionService.currentSourceID {
                    browserViewController.thumbnailProvider = ThumbnailService(
                        readFile: makeFileReader(), cache: cache, sourceID: sourceID
                    )
                }
                try await loadDirectory(at: "/", generation: generation)
                if let initialPath {
                    do {
                        try await drillIntoVaultPath(initialPath, generation: generation)
                    } catch {
                        if Task.isCancelled || error is CancellationError { return }
                        guard generation == navigationGeneration else { return }
                        // The pinned folder vanished mid-open: fall back to
                        // the root; the pin-existence refresh below greys
                        // the row out instead of deleting it.
                        navigationPath.reset()
                        try await loadDirectory(at: "/", generation: generation)
                        onError?(error, "打开目录失败")
                    }
                }
                // Entering the vault re-checks pin targets (decision 4).
                refreshPins()
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == navigationGeneration else { return }
                onError?(error, "打开本地仓库失败")
            }
        }
    }

    /// Walks down a vault-relative path one component at a time after the
    /// vault root loaded, so a pin click drills exactly like manual
    /// navigation — the back stack walks level by level back to the root
    /// (decision 5). A failed level rolls its optimistic push back, the
    /// same contract as `navigateInto`.
    private func drillIntoVaultPath(_ path: String, generation: Int) async throws {
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            try Task.checkCancellation()
            current += "/" + component
            navigationPath.navigateInto(current)
            do {
                try await loadDirectory(at: current, generation: generation)
            } catch {
                navigationPath.rollbackInto()
                throw error
            }
        }
    }

    // MARK: - Vault pins

    /// Pushes the persisted pins to the sidebar (rows) and the browser
    /// (context-menu state), re-stating every target's existence. Called
    /// at launch, on every pin mutation, on vault-root changes, and on
    /// entering the vault (decision 4) — at most 8 synchronous local
    /// stats, so the refresh is cheap.
    private func refreshPins() {
        let pins = pinStore.load()
        let rows = pins.entries.map {
            VaultPinRow(
                path: $0.path,
                alias: $0.alias,
                isAvailable: vaultService.pinTargetExists(relativePath: $0.path)
            )
        }
        serverListViewModel.update(pins: rows)
        browserViewController.pinnedPaths = Set(pins.entries.map(\.path))
        // Pin mutations can move the capsule (pin added for the current
        // subtree, or the active pin removed).
        serverListViewModel.setActivePinPath(
            browsingVault
                ? ServerListViewModel.activePin(
                    forPath: navigationPath.currentPath,
                    pinnedPaths: pins.entries.map(\.path)
                )
                : nil
        )
    }

    /// Sidebar pin click: opens the vault and drills to the pinned
    /// folder, reusing the plain vault open so the back stack starts at
    /// the root and walks up level by level (decision 5).
    private func openVaultFolder(relativePath path: String) {
        openVault(initialPath: path)
    }

    /// Browser context menu: pins a vault folder to the sidebar. The cap
    /// is announced with an alert (decision 6); nothing on disk is touched.
    private func pinToSidebar(_ item: ContentItem) {
        guard item.isDirectory else { return }
        guard pinStore.load().entries.count < VaultPins.maxCount else {
            presentPinCapAlert()
            return
        }
        pinStore.add(path: item.path)
        refreshPins()
    }

    private func unpinFromSidebar(_ item: ContentItem) {
        pinStore.remove(path: item.path)
        refreshPins()
    }

    /// Sidebar row menu: removing a pin touches only the stored entry,
    /// never the folder on disk (red line).
    private func removePin(atPath path: String) {
        pinStore.remove(path: path)
        refreshPins()
    }

    /// Sidebar row menu: alias editor. The field pre-fills the current
    /// display name; empty input clears the alias and restores the
    /// folder's own name (decision 1).
    private func presentPinAliasEditor(forPath path: String) {
        guard let window = hostWindowProvider?() else { return }
        let currentTitle = serverListViewModel.pins.first(where: { $0.path == path })?.title
            ?? VaultPinRow(path: path, alias: nil, isAvailable: true).title
        let alert = NSAlert()
        alert.messageText = "设置别名"
        alert.informativeText = "留空则恢复文件夹本名。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = currentTitle
        field.placeholderString = VaultPinRow.folderName(for: path)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            pinStore.setAlias(field.stringValue, forPath: path)
            refreshPins()
        }
    }

    /// Cap feedback (decision 6): informational, single button.
    private func presentPinCapAlert() {
        guard let window = hostWindowProvider?() else { return }
        let alert = NSAlert()
        alert.messageText = "最多固定 8 个文件夹"
        alert.informativeText = "从侧栏右键「从侧栏移除」后即可添加新的固定。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in }
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

    // MARK: - Settings

    /// Opens the settings destination from outside the sidebar (the
    /// Cmd+, app-menu entry); the sidebar bar highlights the destination
    /// because `showSettings` syncs it. Internal so the composition root
    /// can reach it, like `enumerateShares`.
    func openSettings() {
        showSettings()
    }

    /// Settings destination: swaps the detail pane to the settings page
    /// and highlights it in the sidebar's bottom bar. Leaving the
    /// on-screen directory cancels its in-flight loads and directory
    /// preheat, the same discipline as opening a reader; the SMB session
    /// itself stays connected.
    private func showSettings() {
        _ = beginNavigation()
        serverListViewModel.setActiveDestination(.settings)
        onShowDetail?(settingsPaneViewController)
        onTitleChange?("设置")
    }

    // MARK: - Update check

    /// Manual update check (app menu and settings pane both land here —
    /// the flow exists once). Queries GitHub Releases for the latest
    /// stable tag, compares it with the running MARKETING_VERSION, and
    /// presents one of three alerts as a sheet on the main window.
    /// Manual-only by decision: no background polling in 1.0. Every
    /// failure — offline, rate limit, malformed payload — converges on
    /// the informational alert, so this path can never crash.
    func checkForUpdates() {
        guard updateCheckTask == nil, let window = hostWindowProvider?() else { return }
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            defer { updateCheckTask = nil }
            do {
                let release = try await updateService.latestRelease()
                guard let running = SemanticVersion(AppVersion.short) else {
                    presentUpdateFailureAlert(on: window)
                    return
                }
                if release.version > running {
                    presentUpdateAvailableAlert(release, on: window)
                } else {
                    presentUpToDateAlert(on: window)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                logger.error("检查更新失败: \(error.localizedDescription)")
                presentUpdateFailureAlert(on: window)
            }
        }
    }

    /// Outcome 1/3: running the newest stable release.
    private func presentUpToDateAlert(on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "当前已是最新版本 (\(AppVersion.short))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in }
    }

    /// Outcome 2/3: a newer stable tag exists; 前往下载 opens the release
    /// page in the default browser.
    private func presentUpdateAvailableAlert(_ release: UpdateCheckResult, on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.tag)"
        alert.informativeText = "当前版本 \(AppVersion.short)，可前往 GitHub Releases 下载新版本。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    /// Outcome 3/3: informational only — no retry button, no crash path;
    /// offline and API rate limits both land here.
    private func presentUpdateFailureAlert(on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "无法检查更新"
        alert.informativeText = "请检查网络连接后重试。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in }
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

    /// Opens the player for a video file, carrying the directory's other
    /// videos as the playlist (prev/next buttons and auto-advance on a
    /// clean end). The full listing rides along as the siblings snapshot —
    /// external-subtitle sidecars are text files the videos-only playlist
    /// cannot see. The PlayerCoordinator owns the single player window; a
    /// new open or a track change swaps the session in place — window close
    /// shuts the live mpv handle and stream bridge down via
    /// `windowWillClose`.
    private func openPlayer(at path: String) {
        let videos = browserViewModel.videoItems
        guard videos.contains(where: { $0.path == path }) else {
            onMessageError?("无法定位视频文件。", "打开视频失败")
            return
        }
        playerCoordinator.open(
            items: videos,
            siblings: browserViewModel.state.items,
            selectedPath: path,
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
