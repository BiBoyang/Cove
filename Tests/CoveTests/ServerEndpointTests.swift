import Foundation
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
}
