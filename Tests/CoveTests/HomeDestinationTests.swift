import AppKit
import Foundation
import Testing
@testable import Cove

@Suite("Home destination highlight")
@MainActor
struct HomeDestinationHighlightTests {
    @Test("the home destination flows to the bar like any pinned destination")
    func homeDestinationTransitions() {
        let viewModel = ServerListViewModel()
        var observed: [SidebarDestination] = []
        viewModel.onActiveDestinationChange = { observed.append($0) }

        #expect(viewModel.activeDestination == .none)
        observed.removeAll()

        viewModel.setActiveDestination(.home)
        viewModel.setActiveDestination(.vault)
        viewModel.setActiveDestination(.home)
        // A server pane takes over: the home capsule clears.
        viewModel.setActiveDestination(.none)

        #expect(observed == [.home, .vault, .home, .none])
        #expect(viewModel.activeDestination == .none)
    }
}

@Suite("openHome reset")
@MainActor
struct OpenHomeResetTests {
    /// A coordinator over isolated stores, mirroring the continue-watching
    /// suite's seam: seeded servers carry no Keychain password, so nothing
    /// here ever reaches the network.
    private func makeCoordinator(
        seedServers: [ServerConfig]
    ) throws -> (LibraryCoordinator, PlaybackProgressStore, () -> Void) {
        let suiteName = "HomeDestinationTests-\(UUID().uuidString)"
        let settingsSuite = "\(suiteName)-settings"
        let progressSuite = "\(suiteName)-progress"
        let defaults = UserDefaults(suiteName: suiteName)!
        try ServerStore(defaults: defaults).save(seedServers)
        let service = SMBSessionService(store: ServerStore(defaults: defaults))
        let settings = SettingsService(defaults: UserDefaults(suiteName: settingsSuite)!)
        let cache = makeTestCache()
        let preheat = PreheatService(settings: settings, cacheStore: cache)
        let vault = VaultService(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("CoveTests-\(UUID().uuidString)", isDirectory: true)
        )
        let progressDefaults = UserDefaults(suiteName: progressSuite)!
        progressDefaults.removePersistentDomain(forName: progressSuite)
        let progressStore = PlaybackProgressStore(defaults: progressDefaults)
        let coordinator = LibraryCoordinator(
            sessionService: service,
            cache: cache,
            readerCoordinator: ReaderCoordinator(cache: cache, preheatService: preheat, settings: settings),
            preheatService: preheat,
            vaultService: vault,
            preferencesViewModel: PreferencesViewModel(
                settings: settings,
                cache: PreferencesCacheAdapter(store: cache),
                vault: vault
            ),
            shareOpenStore: ShareOpenStore(defaults: UserDefaults(suiteName: settingsSuite)!),
            progressStore: progressStore
        )
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
            progressDefaults.removePersistentDomain(forName: progressSuite)
        }
        return (coordinator, progressStore, cleanup)
    }

    @Test("from the settings pane: home page back with its cards, home highlighted")
    func openHomeFromSettings() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, store, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        store.savePosition(60, forKey: "smb://nas.local/media|/movies/a.mp4", duration: 300)
        coordinator.start()
        coordinator.openSettings()
        #expect(coordinator.serverListViewModel.activeDestination == .settings)

        var titles: [String] = []
        coordinator.onTitleChange = { titles.append($0) }
        var detailIsHome = false
        coordinator.onShowDetail = { detailIsHome = $0 === coordinator.homeViewController }

        coordinator.openHome()

        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(titles.last == "Cove")
        #expect(detailIsHome)
        // The home page is back, its grid carrying the watch record.
        #expect(coordinator.homeViewModel.state.entries.map(\.fileName) == ["a.mp4"])
        #expect(coordinator.homeViewModel.state.placeholder == nil)
    }

    @Test("from the vault pane: same reset, and a repeat tap is idempotent")
    func openHomeFromVaultAndRepeat() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, store, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        store.savePosition(60, forKey: "smb://nas.local/media|/movies/a.mp4", duration: 300)
        coordinator.start()
        coordinator.serverListViewController.onOpenVault?()
        #expect(coordinator.serverListViewModel.activeDestination == .vault)

        coordinator.openHome()

        // The reset lands synchronously; the cancelled vault open dies at
        // its generation guard, without an alert.
        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(coordinator.homeViewModel.state.entries.count == 1)
        #expect(coordinator.homeViewModel.state.placeholder == nil)

        // A second tap re-runs the same reset: nothing drifts.
        coordinator.openHome()
        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(coordinator.homeViewModel.state.entries.count == 1)
        #expect(coordinator.homeViewModel.state.placeholder == nil)
    }

    @Test("launch lands on the home page with the home row highlighted")
    func startHighlightsHome() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, _, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        var detailIsHome = false
        coordinator.onShowDetail = { detailIsHome = $0 === coordinator.homeViewController }

        coordinator.start()

        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(detailIsHome)
        // No records yet: the no-records level of the two-level empty state.
        #expect(coordinator.homeViewModel.state.entries.isEmpty)
        #expect(coordinator.homeViewModel.state.placeholder?.kind == .noRecords)
    }

    @Test("first run is the home page too: no-servers level with an add action")
    func firstRunHighlightsHome() throws {
        let (coordinator, _, cleanup) = try makeCoordinator(seedServers: [])
        defer { cleanup() }
        var detailIsHome = false
        coordinator.onShowDetail = { detailIsHome = $0 === coordinator.homeViewController }

        coordinator.start()

        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(detailIsHome)
        #expect(coordinator.homeViewModel.state.placeholder?.kind == .noServers)
        #expect(coordinator.homeViewModel.state.placeholder?.action == .addServer)
    }

    @Test("removing the current server resets to the home page with home highlighted")
    func removalResetHighlightsHome() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, store, cleanup) = try makeCoordinator(seedServers: [server])
        defer { cleanup() }
        store.savePosition(60, forKey: "smb://nas.local/media|/movies/a.mp4", duration: 300)
        coordinator.start()
        coordinator.openSettings()
        #expect(coordinator.serverListViewModel.activeDestination == .settings)

        // The deletion flow's reset, driven directly: the confirm alert
        // sheet around it needs a real window.
        coordinator.resetAfterRemovingCurrentServer()

        #expect(coordinator.serverListViewModel.activeDestination == .home)
        #expect(coordinator.homeViewModel.state.entries.count == 1)
        #expect(coordinator.homeViewModel.state.placeholder == nil)
    }
}
