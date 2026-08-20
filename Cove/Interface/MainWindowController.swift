import AppKit
import SourceKit
import TraceKit

/// Root window: server list on the left, directory browser on the right.
/// Owns all async coordination; the view controllers stay purely declarative.
@MainActor
final class MainWindowController: NSWindowController {
    private let logger = TraceLogger(category: "MainWindowController")
    private let sessionService = SMBSessionService()

    private let serverListViewController = ServerListViewController()
    private let browserViewController = BrowserViewController()

    /// Navigation stack of share-relative paths; last element is current.
    private var pathStack: [String] = ["/"]
    private var imageWindows: [ImageViewerWindowController] = []

    init() {
        let splitViewController = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: serverListViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.preferredThicknessFraction = 0.25
        let browserItem = NSSplitViewItem(viewController: browserViewController)
        splitViewController.splitViewItems = [sidebarItem, browserItem]

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
            self?.connect(to: server)
        }
        browserViewController.onOpenDirectory = { [weak self] path in
            self?.navigateInto(path)
        }
        browserViewController.onOpenImage = { [weak self] path, name in
            self?.openImage(at: path, name: name)
        }
        browserViewController.onGoUp = { [weak self] in
            self?.goUp()
        }
    }

    // MARK: - Server list

    private func presentAddServerSheet() {
        guard let window else { return }
        let sheet = AddServerSheetController()
        sheet.beginSheet(on: window) { [weak self] result in
            guard let self, let result else { return }
            do {
                try self.sessionService.addServer(
                    host: result.host,
                    share: result.share,
                    username: result.username,
                    password: result.password
                )
                self.serverListViewController.reload(servers: self.sessionService.servers)
            } catch {
                self.showError(error, title: "保存服务器失败")
            }
        }
    }

    // MARK: - Browsing

    private func connect(to server: ServerConfig) {
        Task {
            do {
                try await sessionService.connect(to: server)
                pathStack = ["/"]
                try await loadCurrentDirectory()
            } catch {
                showError(error, title: "连接失败")
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

    private func goUp() {
        guard pathStack.count > 1 else { return }
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

    private func loadCurrentDirectory() async throws {
        let path = pathStack.last ?? "/"
        let items = try await sessionService.list(at: path)
        browserViewController.display(items: items, path: path, canGoUp: pathStack.count > 1)
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
