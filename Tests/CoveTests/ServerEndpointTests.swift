import Foundation
import Synchronization
import Testing
@testable import Cove

@Suite("Server config model")
struct ServerConfigTests {
    private func decode(_ json: String) throws -> ServerConfig {
        try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
    }

    @Test("decodes payloads written before remote addresses existed")
    func legacyPayload() throws {
        let config = try decode(
            #"{"id":"E621E1B8-9CE1-11D3-A348-00C04C4C71AB","host":"nas.local","username":"user"}"#
        )

        #expect(config.remoteHost == nil)
        #expect(config.activeEndpoint == .lan)
        #expect(config.displayName == "nas.local")
        #expect(config.activeHost == "nas.local")
    }

    @Test("round-trips a remote host and the remote endpoint")
    func roundTrip() throws {
        let config = ServerConfig(
            id: UUID(), host: "nas.local", username: "user",
            remoteHost: "100.64.0.5", activeEndpoint: .remote
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)

        #expect(decoded == config)
        #expect(decoded.activeHost == "100.64.0.5")
    }

    @Test("a whitespace-only remote host decodes as unset")
    func blankRemoteDecodesAsUnset() throws {
        let config = try decode(
            #"{"id":"E621E1B8-9CE1-11D3-A348-00C04C4C71AB","host":"nas.local","username":"user","remoteHost":"  "}"#
        )

        #expect(config.remoteHost == nil)
        #expect(config.activeEndpoint == .lan)
    }

    @Test("an unrecognized endpoint value falls back to LAN instead of failing the list decode")
    func unknownEndpointFallsBack() throws {
        let config = try decode(
            #"{"id":"E621E1B8-9CE1-11D3-A348-00C04C4C71AB","host":"nas.local","username":"user","remoteHost":"100.64.0.5","activeEndpoint":"starlink"}"#
        )

        #expect(config.activeEndpoint == .lan)
    }

    @Test("a remote endpoint without a remote address is pinned to LAN")
    func remoteEndpointRequiresRemoteHost() throws {
        let decoded = try decode(
            #"{"id":"E621E1B8-9CE1-11D3-A348-00C04C4C71AB","host":"nas.local","username":"user","remoteHost":"100.64.0.5","activeEndpoint":"remote"}"#
        )
        #expect(decoded.activeEndpoint == .remote)
        #expect(decoded.activeHost == "100.64.0.5")

        // Constructed in memory without a remote address: pinned to LAN.
        let pinned = ServerConfig(id: UUID(), host: "nas.local", username: "user", activeEndpoint: .remote)
        #expect(pinned.activeEndpoint == .lan)
        #expect(pinned.activeHost == "nas.local")
    }

    @Test("canSwitchToRemote requires a configured, idle remote address")
    func switchPredicate() {
        let lanOnly = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        #expect(!lanOnly.canSwitchToRemote)

        let idleRemote = ServerConfig(id: UUID(), host: "nas.local", username: "user", remoteHost: "100.64.0.5")
        #expect(idleRemote.canSwitchToRemote)

        let activeRemote = ServerConfig(
            id: UUID(), host: "nas.local", username: "user",
            remoteHost: "100.64.0.5", activeEndpoint: .remote
        )
        #expect(!activeRemote.canSwitchToRemote)
    }
}

@Suite("Server store endpoints")
@MainActor
struct ServerStoreEndpointTests {
    @Test("the chosen endpoint survives a store save/load cycle")
    func endpointPersistsThroughStore() throws {
        let suiteName = "ServerStoreEndpointTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = ServerStore(defaults: UserDefaults(suiteName: suiteName)!)

        let config = ServerConfig(
            id: UUID(), host: "nas.local", username: "user",
            remoteHost: "100.64.0.5", activeEndpoint: .remote
        )
        try store.save([config])

        #expect(store.load().first?.activeEndpoint == .remote)
        #expect(store.load().first?.remoteHost == "100.64.0.5")
    }
}

@Suite("SMB session config mutation")
@MainActor
struct SMBSessionServiceConfigTests {
    /// Isolated UserDefaults suite so config mutations never touch the
    /// developer's real server list.
    private func makeSeededService(_ servers: [ServerConfig]) throws -> (SMBSessionService, ServerStore, String) {
        let suiteName = "SMBSessionServiceConfigTests-\(UUID().uuidString)"
        let store = ServerStore(defaults: UserDefaults(suiteName: suiteName)!)
        try store.save(servers)
        return (SMBSessionService(store: store), store, suiteName)
    }

    private func seededServer(endpoint: ServerConfig.Endpoint = .lan) -> ServerConfig {
        ServerConfig(
            id: UUID(), host: "nas.local", username: "user",
            remoteHost: "100.64.0.5", activeEndpoint: endpoint
        )
    }

    @Test("setting a remote address persists and survives a service reload")
    func updateRemoteHostPersists() throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (service, store, suiteName) = try makeSeededService([server])
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let updated = try service.updateRemoteHost(" 100.64.0.5 ", for: server.id)

        #expect(updated.remoteHost == "100.64.0.5")
        #expect(service.servers.first?.remoteHost == "100.64.0.5")
        // A fresh service over the same store sees the same config.
        #expect(SMBSessionService(store: store).servers.first?.remoteHost == "100.64.0.5")
    }

    @Test("clearing the remote address pins the endpoint back to LAN")
    func clearingRemotePinsLAN() throws {
        let server = seededServer(endpoint: .remote)
        let (service, _, suiteName) = try makeSeededService([server])
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let updated = try service.updateRemoteHost(nil, for: server.id)

        #expect(updated.remoteHost == nil)
        #expect(updated.activeEndpoint == .lan)
        #expect(updated.activeHost == "nas.local")
    }

    @Test("updating an unknown server throws instead of mutating the list")
    func unknownServerThrows() throws {
        let (service, _, suiteName) = try makeSeededService([seededServer()])
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        #expect(throws: SessionError.unknownServer) {
            _ = try service.updateRemoteHost("100.64.0.5", for: UUID())
        }
    }

    @Test("switching to remote persists the choice across a service reload")
    func switchToRemotePersists() throws {
        let server = seededServer(endpoint: .lan)
        let (service, store, suiteName) = try makeSeededService([server])
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let updated = try service.switchEndpoint(of: server.id)

        #expect(updated.activeEndpoint == .remote)
        #expect(updated.activeHost == "100.64.0.5")
        #expect(SMBSessionService(store: store).servers.first?.activeEndpoint == .remote)
    }

    @Test("switching back to LAN persists and a LAN-only server never flips")
    func switchBackAndLanOnly() throws {
        let remoteActive = seededServer(endpoint: .remote)
        let lanOnly = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (service, _, suiteName) = try makeSeededService([remoteActive, lanOnly])
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let backToLan = try service.switchEndpoint(of: remoteActive.id)
        #expect(backToLan.activeEndpoint == .lan)
        #expect(backToLan.activeHost == "nas.local")

        let unchanged = try service.switchEndpoint(of: lanOnly.id)
        #expect(unchanged.activeEndpoint == .lan)
        #expect(unchanged.activeHost == "nas.local")
    }
}

@Suite("Library endpoint switching")
@MainActor
struct LibraryEndpointSwitchTests {
    private func seededServer(endpoint: ServerConfig.Endpoint) -> ServerConfig {
        ServerConfig(
            id: UUID(), host: "nas.local", username: "user",
            remoteHost: "100.64.0.5", activeEndpoint: endpoint
        )
    }

    /// A coordinator over an isolated session store. The seeded servers
    /// have no Keychain password, so share enumeration fails fast with
    /// `missingPassword` — a deterministic stand-in for a dead address
    /// that never touches the network.
    private func makeLibraryCoordinator(
        seed: [ServerConfig]
    ) throws -> (LibraryCoordinator, SMBSessionService, () -> Void) {
        let suiteName = "LibraryEndpointSwitchTests-\(UUID().uuidString)"
        let settingsSuite = "\(suiteName)-settings"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ServerStore(defaults: defaults)
        try store.save(seed)
        let service = SMBSessionService(store: store)
        let settings = SettingsService(defaults: UserDefaults(suiteName: settingsSuite)!)
        let cache = makeTestCache()
        let preheat = PreheatService(settings: settings, cacheStore: cache)
        let coordinator = LibraryCoordinator(
            sessionService: service,
            cache: cache,
            readerCoordinator: ReaderCoordinator(cache: cache, preheatService: preheat, settings: settings),
            preheatService: preheat,
            vaultService: VaultService(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("CoveTests-\(UUID().uuidString)")
            )
        )
        let cleanup: () -> Void = {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
        }
        return (coordinator, service, cleanup)
    }

    @Test("switching flips the stored endpoint and re-enumerates at the new address", .timeLimit(.minutes(1)))
    func switchFlipsAndReenumerates() async throws {
        let server = seededServer(endpoint: .lan)
        let (coordinator, service, cleanup) = try makeLibraryCoordinator(seed: [server])
        defer { cleanup() }
        var alerts = 0
        coordinator.onError = { _, _ in alerts += 1 }

        coordinator.switchEndpoint(of: server)

        // The flip lands synchronously before enumeration starts.
        #expect(service.servers.first?.activeEndpoint == .remote)
        // Enumeration ran and failed (no password in the test keychain);
        // the failure surfaces as the grid placeholder, never as an alert.
        // Wait past the loading placeholder for the terminal failure state.
        try await waitUntil {
            coordinator.shareGridViewModel.state.placeholder?.kind
                == .failure(symbol: "exclamationmark.triangle")
        }
        let placeholder = coordinator.shareGridViewModel.state.placeholder
        #expect(placeholder?.kind == .failure(symbol: "exclamationmark.triangle"))
        #expect(placeholder?.action == .retry)
        // Already on remote, so no switch hint is suggested again.
        #expect(placeholder?.message.contains("已配置远程地址") == false)
        #expect(alerts == 0)
    }

    @Test("a share enumeration failure suggests the idle remote address", .timeLimit(.minutes(1)))
    func enumerationFailureHintsAtRemote() async throws {
        let server = seededServer(endpoint: .lan)
        let (coordinator, service, cleanup) = try makeLibraryCoordinator(seed: [server])
        defer { cleanup() }
        var alerts = 0
        coordinator.onError = { _, _ in alerts += 1 }

        coordinator.enumerateShares(of: server)

        try await waitUntil {
            coordinator.shareGridViewModel.state.placeholder?.kind
                == .failure(symbol: "exclamationmark.triangle")
        }
        let placeholder = coordinator.shareGridViewModel.state.placeholder
        #expect(placeholder?.action == .retry)
        #expect((placeholder?.message ?? "").contains("已配置远程地址"))
        #expect(alerts == 0)
        // The hint is advisory only: nothing flipped.
        #expect(service.servers.first?.activeEndpoint == .lan)
    }

    @Test("a LAN-only server never flips and its failures carry no hint", .timeLimit(.minutes(1)))
    func lanOnlyNeverFlips() async throws {
        let server = ServerConfig(id: UUID(), host: "nas.local", username: "user")
        let (coordinator, service, cleanup) = try makeLibraryCoordinator(seed: [server])
        defer { cleanup() }

        coordinator.switchEndpoint(of: server)

        #expect(service.servers.first?.activeEndpoint == .lan)
        try await waitUntil {
            coordinator.shareGridViewModel.state.placeholder?.kind
                == .failure(symbol: "exclamationmark.triangle")
        }
        #expect(coordinator.shareGridViewModel.state.placeholder?.message.contains("已配置远程地址") == false)
    }
}

/// Polls `condition` on the main actor until it holds, yielding between
/// checks so queued main-actor continuations can run. Throws (and thus
/// fails the test) on timeout instead of hanging. Same helper as in
/// ViewModelTests; both files keep a private copy.
@MainActor
private func waitUntil(
    _ message: @autoclosure () -> String = "condition not met before timeout",
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        if ContinuousClock.now > deadline {
            throw WaitTimeout(message: message())
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct WaitTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
