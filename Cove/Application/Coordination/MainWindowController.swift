import AppKit
import TraceKit

/// Main application window shell. Feature state and workflows live in their
/// view models/coordinators; this type only assembles the split view, swaps
/// the detail pane, and presents app-level errors.
@MainActor
final class MainWindowController: NSWindowController {
    private let logger = TraceLogger(category: "MainWindowController")
    private let libraryCoordinator: LibraryCoordinator
    private let splitViewController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem

    init(libraryCoordinator: LibraryCoordinator) {
        self.libraryCoordinator = libraryCoordinator

        sidebarItem = NSSplitViewItem(sidebarWithViewController: libraryCoordinator.serverListViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.preferredThicknessFraction = 0.25
        // There is no UI to bring a collapsed sidebar back, so collapsing
        // is disabled until a sidebar toggle exists.
        sidebarItem.canCollapse = false
        splitViewController.splitViewItems = [
            sidebarItem,
            NSSplitViewItem(viewController: libraryCoordinator.shareGridViewController),
        ]

        let window = NSWindow(contentViewController: splitViewController)
        window.title = "Cove"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 960, height: 600))
        window.center()
        super.init(window: window)

        wireCoordinator()
        libraryCoordinator.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func wireCoordinator() {
        libraryCoordinator.hostWindowProvider = { [weak self] in self?.window }
        libraryCoordinator.onShowDetail = { [weak self] in self?.showDetail($0) }
        libraryCoordinator.onTitleChange = { [weak self] in self?.window?.title = $0 }
        libraryCoordinator.onError = { [weak self] in self?.showError($0, title: $1) }
        libraryCoordinator.onMessageError = { [weak self] in self?.showError(message: $0, title: $1) }
        libraryCoordinator.onUnsupportedFile = { [weak self] in self?.showUnsupportedFile(name: $0) }
    }

    private func showDetail(_ viewController: NSViewController) {
        // Replacing the split view items tears down and re-attaches the
        // detail pane; when done for the view controller that is already
        // showing (e.g. connecting while the share grid is up), the split
        // view transiently gives the sidebar the full window width and the
        // source-list selection paints edge to edge. Skip no-op swaps.
        if splitViewController.splitViewItems.last?.viewController === viewController {
            return
        }
        splitViewController.splitViewItems = [
            sidebarItem,
            NSSplitViewItem(viewController: viewController),
        ]
    }

    private func showUnsupportedFile(name: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "暂不支持打开该类型文件"
        alert.informativeText = name
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window)
    }

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
