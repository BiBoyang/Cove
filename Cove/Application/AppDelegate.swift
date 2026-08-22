import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    /// Retained for the app lifetime; the window itself closes and reopens
    /// freely (`isReleasedWhenClosed = false`).
    private var preferencesWindowController: PreferencesWindowController?
    /// The app's single composition root owns the service graph; the
    /// preheat service is retained transitively by the library coordinator.
    private var settingsService: SettingsService?
    private var cacheService: CacheService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let settingsService = SettingsService()
        let cacheService = CacheService(settings: settingsService)
        let preheatService = PreheatService(settings: settingsService, cacheStore: cacheService.store)
        let sessionService = SMBSessionService()
        let readerCoordinator = ReaderCoordinator(cache: cacheService.store)
        let libraryCoordinator = LibraryCoordinator(
            sessionService: sessionService,
            cache: cacheService.store,
            readerCoordinator: readerCoordinator,
            preheatService: preheatService
        )
        self.settingsService = settingsService
        self.cacheService = cacheService
        let controller = MainWindowController(libraryCoordinator: libraryCoordinator)
        controller.showWindow(nil)
        mainWindowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Main menu

    /// No storyboard, so the menu bar is built by hand: the app menu carries
    /// "设置…" (Cmd+,) and "退出", plus a standard Edit menu so text fields
    /// keep their undo/cut/copy/paste/select-all shortcuts.
    @MainActor private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let preferencesItem = NSMenuItem(
            title: "设置…",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
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
        editMenuItem.submenu = editMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    @MainActor @objc private func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            guard let settingsService, let cacheService else { return }
            let viewModel = PreferencesViewModel(
                settings: settingsService,
                cache: PreferencesCacheAdapter(store: cacheService.store)
            )
            preferencesWindowController = PreferencesWindowController(viewModel: viewModel)
        }
        preferencesWindowController?.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
