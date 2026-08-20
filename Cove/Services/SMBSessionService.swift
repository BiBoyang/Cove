import Foundation
import KeychainKit
import SourceKit
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

/// Owns the SMB session lifecycle and the persisted server list.
///
/// This is the only layer in the app target that talks to SourceKit;
/// view controllers must go through this service.
@MainActor
final class SMBSessionService {
    private static let keychainService = "com.biboyang.cove"

    private let logger = TraceLogger(category: "SMBSessionService")
    private let store = ServerStore()

    private(set) var servers: [ServerConfig]
    private var source: SMBSource?

    init() {
        servers = store.load()
    }

    /// Adds a server: password goes to the Keychain, the rest to UserDefaults.
    @discardableResult
    func addServer(host: String, username: String, password: String) throws -> ServerConfig {
        let config = ServerConfig(id: UUID(), host: host, username: username)
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
        if let old {
            Task { await old.disconnect() }
        }
    }

    func list(at path: String) async throws -> [ContentItem] {
        guard let source else { throw SourceError.notConnected }
        return try await source.list(at: path)
    }

    func readFile(at path: String) async throws -> Data {
        guard let source else { throw SourceError.notConnected }
        return try await source.read(at: path)
    }

    func disconnect() async {
        let old = source
        source = nil
        await old?.disconnect()
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
