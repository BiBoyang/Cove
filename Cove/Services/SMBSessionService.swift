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
        store.save(servers)
        logger.info("Added server \(host)")
        return config
    }

    /// Enumerates the browsable shares of a stored server. Does not touch
    /// the active share session: enumeration uses its own short-lived
    /// server-level connection (see `SMBServer`).
    func enumerateShares(for serverID: UUID) async throws -> [SMBShareInfo] {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            throw SessionError.unknownServer
        }
        let password = try passwordFor(server)
        logger.info("Enumerating shares on \(server.host)")
        do {
            return try await SMBServer(
                host: server.host,
                username: server.username,
                password: password
            ).listShares()
        } catch {
            logger.error("Share enumeration failed for \(server.host): \(error.localizedDescription)")
            throw error
        }
    }

    /// Connects to one share of a server, replacing any active session.
    func connect(to server: ServerConfig, share: String) async throws {
        let password = try passwordFor(server)
        logger.info("Connecting to \(server.host)/\(share)")
        let newSource = SMBSource(
            host: server.host,
            share: share,
            username: server.username,
            password: password
        )
        do {
            try await newSource.connect()
        } catch {
            logger.error("Connect failed for \(server.host)/\(share): \(error.localizedDescription)")
            throw error
        }
        if let old = source {
            source = nil
            await old.disconnect()
        }
        source = newSource
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
