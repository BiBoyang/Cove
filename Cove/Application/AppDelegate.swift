import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    /// Retained so the app-menu Cmd+, entry can route into the library
    /// coordinator's settings destination.
    private var libraryCoordinator: LibraryCoordinator?
    /// The app's single composition root owns the service graph; the
    /// preheat service is retained transitively by the library coordinator.
    private var settingsService: SettingsService?
    private var cacheService: CacheService?
    private var vaultService: VaultService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dark-only presentation: the app is dark regardless of the
        // system appearance, so every window (library, player, readers)
        // speaks the same dark palette.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        installMainMenu()
        let settingsService = SettingsService()
        let cacheService = CacheService(settings: settingsService)
        let preheatService = PreheatService(settings: settingsService, cacheStore: cacheService.store)
        let sessionService = SMBSessionService()
        let progressStore = PlaybackProgressStore()
        let readingProgressStore = ReadingProgressStore()
        let shareOpenStore = ShareOpenStore()
        let vaultService = VaultService(settings: settingsService)
        // One preferences session for the sidebar settings destination,
        // built here because only the composition root sees all services.
        let preferencesViewModel = PreferencesViewModel(
            settings: settingsService,
            cache: PreferencesCacheAdapter(store: cacheService.store),
            vault: vaultService
        )
        let readerCoordinator = ReaderCoordinator(
            cache: cacheService.store,
            preheatService: preheatService,
            settings: settingsService,
            readingProgress: readingProgressStore
        )
        let libraryCoordinator = LibraryCoordinator(
            sessionService: sessionService,
            cache: cacheService.store,
            readerCoordinator: readerCoordinator,
            preheatService: preheatService,
            vaultService: vaultService,
            preferencesViewModel: preferencesViewModel,
            shareOpenStore: shareOpenStore,
            progressStore: progressStore
        )
        self.settingsService = settingsService
        self.cacheService = cacheService
        self.vaultService = vaultService
        self.libraryCoordinator = libraryCoordinator
        let controller = MainWindowController(libraryCoordinator: libraryCoordinator)
        controller.showWindow(nil)
        mainWindowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Main menu

    /// No storyboard, so the menu bar is built by hand: the app menu carries
    /// "设置…" (Cmd+,), "检查更新…", and "退出", plus a standard Edit menu
    /// so text fields keep their undo/cut/copy/paste/select-all shortcuts.
    @MainActor private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let preferencesItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        let checkForUpdatesItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        appMenu.addItem(checkForUpdatesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "退出 Cove",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        // "查找…" (Cmd+F) focuses the browser toolbar's filter field. No
        // target: the item rides the responder chain, so it enables only
        // while a browser view is on-screen.
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "查找…",
            action: #selector(BrowserViewController.focusSearchField(_:)),
            keyEquivalent: "f"
        ))
        editMenuItem.submenu = editMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    /// Settings live in the main window as a sidebar destination (the same
    /// information architecture a future iOS split view would use); Cmd+,
    /// and the menu item both focus it.
    @MainActor @objc private func openSettings(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        libraryCoordinator?.openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Manual update check: same window-first choreography as settings so
    /// the result alert always has a sheet host; the flow itself (fetch,
    /// compare, three-state alert) lives once in the library coordinator.
    @MainActor @objc private func checkForUpdates(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        libraryCoordinator?.checkForUpdates()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
