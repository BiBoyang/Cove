import Foundation
import KeychainKit
import SourceKit
import Synchronization
import TraceKit

enum SessionError: LocalizedError {
    case missingPassword
    case unknownServer

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            return "Keychain 中找不到该服务器的密码，请删除后重新添加。"
        case .unknownServer:
            return "找不到该服务器的配置，请刷新后重试。"
        }
    }
}

/// Sendable holder for the live interactive source. Background readers
/// (reader pipeline, thumbnails) go through it without touching the main
/// actor: a read hops straight onto the SMB actor.
private final class SMBReadRouter: Sendable {
    private let state = Mutex<(any ContentSource)?>(nil)

    func update(_ source: (any ContentSource)?) {
        state.withLock { $0 = source }
    }

    func read(at path: String) async throws -> Data {
        guard let source = state.withLock({ $0 }) else {
            throw SourceError.notConnected
        }
        return try await source.read(at: path)
    }

    func read(at path: String, range: Range<Int64>) async throws -> Data {
        guard let source = state.withLock({ $0 }) else {
            throw SourceError.notConnected
        }
        return try await source.read(at: path, range: range)
    }

    func list(at path: String) async throws -> [ContentItem] {
        guard let source = state.withLock({ $0 }) else {
            throw SourceError.notConnected
        }
        return try await source.list(at: path)
    }
}

/// Infrastructure service owning the SMB session lifecycle and persisted server list.
///
/// This is the only layer in the app target that talks to SourceKit;
/// view controllers must go through this service.
///
/// Two connections per session: the main `source` serves interactive
/// browsing/reading, and a second, independent `preheatSource` is built in
/// the background for the preheat pipeline. `SMBSource` is a serial actor,
/// so without the split a bulk preheat read would queue behind (and stall)
/// interactive `list`/`read` calls.
@MainActor
final class SMBSessionService {
    /// The preheat-side view of a session: an independent connection to the
    /// same share, reserved for background warming.
    typealias PreheatConnection = (source: any ContentSource, share: String)

    private static let keychainService = "com.biboyang.cove"

    private let logger = TraceLogger(category: "SMBSessionService")
    private let store: ServerStore

    private(set) var servers: [ServerConfig]
    /// The interactive source: an `SMBSource` for NAS shares, or a
    /// `LocalFileSource` while browsing the vault. Kept as the protocol so
    /// the whole downstream pipeline (list/read/sourceID) works unchanged.
    private var source: (any ContentSource)?
    /// Nonisolated view of `source` for background readers; written only
    /// from the main actor, alongside `source`.
    private let readRouter = SMBReadRouter()
    /// The dedicated preheat connection; nil until the background connect
    /// succeeds, and whenever the session is down.
    private var preheatSource: SMBSource?
    /// The in-flight background connect of the preheat connection; a new
    /// session cancels it.
    private var preheatConnectTask: Task<Void, Never>?

    /// Delivers the preheat connection once it is up, or nil when it goes
    /// away. Assigned by the coordinator; fires on the main actor.
    var onPreheatConnectionChanged: ((PreheatConnection?) -> Void)?

    init(store: ServerStore = ServerStore()) {
        self.store = store
        servers = store.load()
    }

    /// Adds a server: password goes to the Keychain, the rest to UserDefaults.
    @discardableResult
    func addServer(
        host: String,
        username: String,
        password: String,
        remoteHost: String? = nil
    ) throws -> ServerConfig {
        let config = ServerConfig(id: UUID(), host: host, username: username, remoteHost: remoteHost)
        try KeychainKit.savePassword(password, service: Self.keychainService, account: config.id.uuidString)
        servers.append(config)
        do {
            try store.save(servers)
        } catch {
            // Roll back both halves so a failed persist never leaves a
            // phantom server or an orphaned password behind.
            servers.removeAll { $0.id == config.id }
            try? KeychainKit.deletePassword(service: Self.keychainService, account: config.id.uuidString)
            throw error
        }
        logger.info("Added server \(host)", privacy: .private)
        return config
    }

    /// Removes a server: drops the persisted entry and its Keychain password.
    func removeServer(id: UUID) throws {
        guard let index = servers.firstIndex(where: { $0.id == id }) else {
            throw SessionError.unknownServer
        }
        let removed = servers.remove(at: index)
        do {
            try store.save(servers)
        } catch {
            servers.insert(removed, at: index)
            throw error
        }
        // Best effort: an orphaned Keychain item is harmless (keyed by a
        // UUID nothing references anymore).
        try? KeychainKit.deletePassword(service: Self.keychainService, account: id.uuidString)
        logger.info("Removed server \(removed.host)", privacy: .private)
    }

    /// Sets (or clears) a server's optional remote address. Clearing it
    /// while the remote endpoint is active pins the endpoint back to LAN.
    @discardableResult
    func updateRemoteHost(_ remoteHost: String?, for serverID: UUID) throws -> ServerConfig {
        let trimmed = remoteHost?.trimmedNonEmpty
        return try updateConfig(id: serverID) { config in
            config.remoteHost = trimmed
            if trimmed == nil { config.activeEndpoint = .lan }
        }
    }

    /// Mutates one stored config in place. Rolls the list back when the
    /// persist fails so a failed save never leaves divergent state.
    @discardableResult
    private func updateConfig(
        id: UUID,
        _ change: (inout ServerConfig) -> Void
    ) throws -> ServerConfig {
        guard let index = servers.firstIndex(where: { $0.id == id }) else {
            throw SessionError.unknownServer
        }
        let original = servers[index]
        change(&servers[index])
        do {
            try store.save(servers)
        } catch {
            servers[index] = original
            throw error
        }
        logger.info("Updated server \(servers[index].displayName)", privacy: .private)
        return servers[index]
    }

    /// Enumerates the browsable shares of a stored server. Does not touch
    /// the active share session: enumeration uses its own short-lived
    /// server-level connection (see `SMBServer`).
    func enumerateShares(for serverID: UUID) async throws -> [SMBShareInfo] {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            throw SessionError.unknownServer
        }
        let password = try passwordFor(server)
        logger.info("Enumerating shares on \(server.host)", privacy: .private)
        do {
            return try await SMBServer(
                host: server.host,
                username: server.username,
                password: password
            ).listShares()
        } catch {
            logger.error("Share enumeration failed for \(server.host): \(error.localizedDescription)", privacy: .private)
            throw error
        }
    }

    /// Connects to one share of a server, replacing any active session.
    func connect(to server: ServerConfig, share: String) async throws {
        let password = try passwordFor(server)
        logger.info("Connecting to \(server.host)/\(share)", privacy: .private)
        let newSource = SMBSource(
            host: server.host,
            share: share,
            username: server.username,
            password: password
        )
        do {
            try await newSource.connect()
        } catch {
            logger.error("Connect failed for \(server.host)/\(share): \(error.localizedDescription)", privacy: .private)
            throw error
        }
        // Swap first so the new session is usable immediately; the old one
        // is torn down off the critical path and must not block us.
        let old = source
        source = newSource
        readRouter.update(newSource)
        if let old {
            Task { await old.disconnect() }
        }
        // Rebuild the preheat connection for the new share in the background.
        startPreheatConnection(host: server.host, share: share, username: server.username, password: password)
    }

    func list(at path: String) async throws -> [ContentItem] {
        guard let source else { throw SourceError.notConnected }
        return try await source.list(at: path)
    }

    /// Connects a local source (the vault's `LocalFileSource`), replacing
    /// any active session. No password, no preheat connection — local reads
    /// are cheap and the vault never enters any cache pool.
    func connectLocal(_ newSource: any ContentSource) async throws {
        try await newSource.connect()
        logger.info("Connected local source \(newSource.sourceID)", privacy: .public)
        // Same swap discipline as `connect(to:share:)`: usable immediately,
        // old session torn down off the critical path.
        let old = source
        source = newSource
        readRouter.update(newSource)
        if let old {
            Task { await old.disconnect() }
        }
        preheatConnectTask?.cancel()
        preheatConnectTask = nil
        tearDownPreheatConnection()
    }

    /// A whole-file read closure that never touches the main actor: it
    /// snapshots the live source and hops straight onto the SMB actor.
    /// Injected into reader content sources and the thumbnail pipeline so
    /// background reads stay responsive while the main thread is busy
    /// laying out scrolling UI.
    func makeFileReader() -> @Sendable (String) async throws -> Data {
        { [readRouter] path in
            try await readRouter.read(at: path)
        }
    }

    /// A ranged-read closure with the same non-main-actor routing as
    /// `makeFileReader()`. Drives the video player's mpv stream bridge:
    /// mpv's demuxer issues the byte ranges it needs and this hops them
    /// straight onto the SMB actor.
    func makeRangedFileReader() -> @Sendable (String, Range<Int64>) async throws -> Data {
        { [readRouter] path, range in
            try await readRouter.read(at: path, range: range)
        }
    }

    /// A directory-listing closure with the same background routing as the
    /// readers. Bulk walkers (vault downloads) use it so a recursive
    /// enumeration never queues on the main actor.
    func makeLister() -> @Sendable (String) async throws -> [ContentItem] {
        { [readRouter] path in
            try await readRouter.list(at: path)
        }
    }

    /// Cache-key identity of the active share, e.g. `"smb://host/share"`;
    /// `nil` while no share is connected.
    var currentSourceID: String? {
        source?.sourceID
    }

    func disconnect() async {
        preheatConnectTask?.cancel()
        preheatConnectTask = nil
        tearDownPreheatConnection()
        // Clear the reader-facing snapshot first so new reads fail fast
        // while the graceful teardown waits for in-flight ones.
        readRouter.update(nil)
        let old = source
        source = nil
        await old?.disconnect()
    }

    // MARK: - Preheat connection

    /// Connects a second, independent `SMBSource` to the same share for the
    /// preheat pipeline. Best effort: a failure only disables preheating for
    /// this session — browsing is unaffected. Any previous preheat connection
    /// (or in-flight attempt) is replaced.
    private func startPreheatConnection(host: String, share: String, username: String, password: String) {
        preheatConnectTask?.cancel()
        tearDownPreheatConnection()
        preheatConnectTask = Task { [weak self] in
            let preheat = SMBSource(host: host, share: share, username: username, password: password)
            do {
                try await preheat.connect()
            } catch {
                if !Task.isCancelled {
                    self?.logger.error(
                        "Preheat connection failed for \(host)/\(share): \(error.localizedDescription)",
                        privacy: .private
                    )
                }
                await preheat.disconnect()
                return
            }
            // A newer session may have superseded this attempt while the
            // connect was in flight; never install a stale connection.
            guard !Task.isCancelled, let self else {
                await preheat.disconnect()
                return
            }
            self.preheatSource = preheat
            self.logger.info("Preheat connection ready for \(host)/\(share)", privacy: .private)
            let connection: PreheatConnection = (source: preheat, share: share)
            self.onPreheatConnectionChanged?(connection)
        }
    }

    /// Tears down the preheat connection, if any, and notifies the pipeline.
    private func tearDownPreheatConnection() {
        let old = preheatSource
        preheatSource = nil
        guard let old else { return }
        onPreheatConnectionChanged?(nil)
        Task { await old.disconnect() }
    }

    private func passwordFor(_ server: ServerConfig) throws -> String {
        guard let password = try KeychainKit.readPassword(
            service: Self.keychainService,
            account: server.id.uuidString
        ) else {
            throw SessionError.missingPassword
        }
        return password
    }
}
