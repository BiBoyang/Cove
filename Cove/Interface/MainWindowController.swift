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

    // MARK: - Share grid

    private func enumerateShares(of server: ServerConfig) {
        // Mark the intent up front so a slow enumeration of a previously
        // clicked server cannot overwrite the grid of the latest one.
        currentServer = server
        Task {
            showDetail(shareGridViewController)
            shareGridViewController.displayLoading()
            window?.title = server.displayName
            do {
                let shares = try await sessionService.enumerateShares(for: server.id)
                guard currentServer?.id == server.id else { return }
                currentShare = nil
                shareGridViewController.display(shares: shares)
            } catch {
                guard currentServer?.id == server.id else { return }
                shareGridViewController.showPlaceholder("双击左侧服务器以连接")
                showError(error, title: "获取共享列表失败")
            }
        }
    }

    // MARK: - Browsing

    private func openShare(_ share: SMBShareInfo) {
        guard let server = currentServer else { return }
        Task {
            do {
                try await sessionService.connect(to: server, share: share.name)
                currentShare = share.name
                pathStack = ["/"]
                showDetail(browserViewController)
                try await loadCurrentDirectory()
            } catch {
                showError(error, title: "打开共享失败")
            }
        }
    }

    private func navigateInto(_ path: String) {
        pathStack.append(path)
        Task {
            do {
                try await loadCurrentDirectory()
            } catch {
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
        let current = pathStack.removeLast()
        Task {
            do {
                try await loadCurrentDirectory()
            } catch {
                pathStack.append(current)
                showError(error, title: "打开目录失败")
            }
        }
    }

    private func backToShareGrid() {
        currentShare = nil
        pathStack = ["/"]
        window?.title = currentServer?.displayName ?? "Cove"
        showDetail(shareGridViewController)
        Task {
            await sessionService.disconnect()
        }
    }

    private func loadCurrentDirectory() async throws {
        let path = pathStack.last ?? "/"
        let items = try await sessionService.list(at: path)
        window?.title = path
        browserViewController.display(items: items, path: path)
    }

    // MARK: - Image probe

    private func openImage(at path: String, name: String) {
        Task {
            do {
                let data = try await sessionService.readFile(at: path)
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
