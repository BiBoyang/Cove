import AppKit
import SourceKit
import TraceKit

/// Root window: server list on the left; the right pane swaps between the
/// share grid (server level) and the directory browser (share level).
/// Owns all async coordination; the view controllers stay purely declarative.
@MainActor
final class MainWindowController: NSWindowController {
    private let logger = TraceLogger(category: "MainWindowController")
    private let sessionService = SMBSessionService()

    private let splitViewController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem

    private let serverListViewController = ServerListViewController()
    private let shareGridViewController = ShareGridViewController()
    private let browserViewController = BrowserViewController()

    /// The server whose shares are on screen, if any.
    private var currentServer: ServerConfig?
    /// The share currently being browsed; `nil` while on the share grid.
    private var currentShare: String?
    /// Navigation stack of share-relative paths; last element is current.
    private var pathStack: [String] = ["/"]
    private var imageWindows: [ImageViewerWindowController] = []
    /// Retained for the lifetime of the sheet session. The sheet window is
    /// held by AppKit, but the controller is not — letting it deallocate
    /// leaves the buttons' weak targets dangling (clicks do nothing).
    private var activeAddServerSheet: AddServerSheetController?

    /// Monotonic counter identifying the latest navigation/read intent.
    /// Every navigation entry point bumps it and captures the value; an
    /// in-flight task re-checks it after each `await` and stays silent once
    /// superseded, so stale results never reach the UI.
    private var navigationGeneration = 0
    /// The in-flight navigation/image-read task; a new task cancels it.
    private var activeTask: Task<Void, Never>?

    init() {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: serverListViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.preferredThicknessFraction = 0.25
        splitViewController.splitViewItems = [
            sidebarItem,
            NSSplitViewItem(viewController: shareGridViewController),
        ]

        let window = NSWindow(contentViewController: splitViewController)
        window.title = "Cove"
        window.setContentSize(NSSize(width: 960, height: 600))
        window.center()
        super.init(window: window)

        wireCallbacks()
        serverListViewController.reload(servers: sessionService.servers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func wireCallbacks() {
        serverListViewController.onAddServer = { [weak self] in
            self?.presentAddServerSheet()
        }
        serverListViewController.onConnect = { [weak self] server in
            self?.enumerateShares(of: server)
        }
        serverListViewController.onRemove = { [weak self] server in
            self?.confirmRemoveServer(server)
        }
        shareGridViewController.onOpenShare = { [weak self] share in
            self?.openShare(share)
        }
        browserViewController.onOpenDirectory = { [weak self] path in
            self?.navigateInto(path)
        }
        browserViewController.onOpenImage = { [weak self] path, name in
            self?.openImage(at: path, name: name)
        }
        browserViewController.onGoUp = { [weak self] in
            self?.goBack()
        }
    }

    /// Swaps the right pane, keeping the sidebar item untouched.
    private func showDetail(_ viewController: NSViewController) {
        splitViewController.splitViewItems = [
            sidebarItem,
            NSSplitViewItem(viewController: viewController),
        ]
    }

    /// Invalidates and cancels the previous task, and returns the generation
    /// the new one must guard against after every `await`.
    private func beginNavigation() -> Int {
        navigationGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        return navigationGeneration
    }

    // MARK: - Server list

    private func presentAddServerSheet() {
        guard let window else { return }
        let sheet = AddServerSheetController()
        activeAddServerSheet = sheet
        sheet.beginSheet(on: window) { [weak self] result in
            guard let self, let result else {
                self?.activeAddServerSheet = nil
                return
            }
            do {
                try self.sessionService.addServer(
                    host: result.host,
                    username: result.username,
                    password: result.password
                )
                self.serverListViewController.reload(servers: self.sessionService.servers)
            } catch {
                self.showError(error, title: "保存服务器失败")
            }
            self.activeAddServerSheet = nil
        }
    }

    private func confirmRemoveServer(_ server: ServerConfig) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "删除服务器“\(server.displayName)”？"
        alert.informativeText = "将同时删除保存的密码，此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.sessionService.removeServer(id: server.id)
                self.serverListViewController.reload(servers: self.sessionService.servers)
                if self.currentServer?.id == server.id {
                    self.resetAfterRemovingCurrentServer()
                }
            } catch {
                self.showError(error, title: "删除服务器失败")
            }
        }
    }

    /// The server being browsed was deleted: tear its session down and
    /// return the window to the initial share-grid placeholder.
    private func resetAfterRemovingCurrentServer() {
        _ = beginNavigation()
        currentServer = nil
        currentShare = nil
        pathStack = ["/"]
        window?.title = "Cove"
        showDetail(shareGridViewController)
        shareGridViewController.showPlaceholder("双击左侧服务器以连接")
        activeTask = Task {
            await sessionService.disconnect()
        }
    }

    // MARK: - Share grid

    private func enumerateShares(of server: ServerConfig) {
        let generation = beginNavigation()
        // Mark the intent up front so a slow enumeration of a previously
        // clicked server cannot overwrite the grid of the latest one.
        currentServer = server
        activeTask = Task {
            showDetail(shareGridViewController)
            shareGridViewController.displayLoading()
            window?.title = server.displayName
            do {
                let shares = try await sessionService.enumerateShares(for: server.id)
                guard generation == navigationGeneration else { return }
                currentShare = nil
                shareGridViewController.display(shares: shares)
            } catch {
                if Task.isCancelled { return }
                guard generation == navigationGeneration else { return }
                shareGridViewController.showPlaceholder("获取共享列表失败，双击重试")
                showError(error, title: "获取共享列表失败")
            }
        }
    }

    // MARK: - Browsing

    private func openShare(_ share: SMBShareInfo) {
        guard let server = currentServer else { return }
        let generation = beginNavigation()
        activeTask = Task {
            do {
                try await sessionService.connect(to: server, share: share.name)
                guard generation == navigationGeneration else { return }
                currentShare = share.name
                pathStack = ["/"]
                window?.title = "\(server.displayName) / \(share.name)"
                showDetail(browserViewController)
                try await loadDirectory(at: "/", generation: generation)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == navigationGeneration else { return }
                showError(error, title: "打开共享失败")
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
                // This task still owns the generation, so the pushed path is
                // still on top of the stack and safe to roll back.
                pathStack.removeLast()
                showError(error, title: "打开目录失败")
            }
        }
    }

    /// Back button: up one directory, or — at the share root — back to the
    /// share grid.
    private func goBack() {
        guard pathStack.count > 1 else {
            backToShareGrid()
            return
        }
        let generation = beginNavigation()
        let popped = pathStack.removeLast()
        // Capture the target now; the task must not consult the mutable
        // stack after an `await`.
        let target = pathStack.last ?? "/"
        activeTask = Task {
            do {
                try await loadDirectory(at: target, generation: generation)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                guard generation == navigationGeneration else { return }
                pathStack.append(popped)
                showError(error, title: "打开目录失败")
            }
        }
    }

    private func backToShareGrid() {
        _ = beginNavigation()
        currentShare = nil
        pathStack = ["/"]
        window?.title = currentServer?.displayName ?? "Cove"
        showDetail(shareGridViewController)
        activeTask = Task {
            await sessionService.disconnect()
        }
    }

    /// Loads `path` into the browser. Throws `CancellationError` when the
    /// generation went stale while the listing was in flight, so callers can
    /// stay silent instead of flashing an alert for superseded work.
    private func loadDirectory(at path: String, generation: Int) async throws {
        let items = try await sessionService.list(at: path)
        guard generation == navigationGeneration else { throw CancellationError() }
        browserViewController.display(items: items, path: path, isAtShareRoot: path == "/")
    }

    // MARK: - Image probe

    private func openImage(at path: String, name: String) {
        let generation = beginNavigation()
        activeTask = Task {
            do {
                let data = try await sessionService.readFile(at: path)
                guard generation == navigationGeneration else { return }
                guard let image = NSImage(data: data) else {
                    showError(message: "无法解码图片：\(name)", title: "打开图片失败")
                    return
                }
                let controller = ImageViewerWindowController(image: image, name: name)
                imageWindows.append(controller)
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(imageWindowWillClose(_:)),
                    name: NSWindow.willCloseNotification,
                    object: controller.window
                )
                controller.showWindow(nil)
            } catch {
                if Task.isCancelled { return }
                guard generation == navigationGeneration else { return }
                showError(error, title: "打开图片失败")
            }
        }
    }

    @objc private func imageWindowWillClose(_ notification: Notification) {
        imageWindows.removeAll { $0.window === (notification.object as? NSWindow) }
    }

    // MARK: - Errors

    private func showError(_ error: Error, title: String) {
        logger.error("\(title): \(error.localizedDescription)")
        showError(message: error.localizedDescription, title: title)
    }

    private func showError(message: String, title: String) {
        logger.error("\(title): \(message)")
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}
