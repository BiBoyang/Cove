import Foundation
import KeychainKit
import SourceKit
import TraceKit

enum SessionError: LocalizedError {
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            return "Keychain 中找不到该服务器的密码，请删除后重新添加。"
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
    func addServer(host: String, share: String, username: String, password: String) throws -> ServerConfig {
        let config = ServerConfig(id: UUID(), host: host, share: share, username: username)
        try KeychainKit.savePassword(password, service: Self.keychainService, account: config.id.uuidString)
        servers.append(config)
        store.save(servers)
        logger.info("Added server \(host)/\(share)")
        return config
    }

    /// Connects to a server, replacing any active session.
    func connect(to server: ServerConfig) async throws {
        guard let password = try KeychainKit.readPassword(
            service: Self.keychainService,
            account: server.id.uuidString
        ) else {
            throw SessionError.missingPassword
        }
        logger.info("Connecting to \(server.host)/\(server.share)")
        let newSource = SMBSource(
            host: server.host,
            share: server.share,
            username: server.username,
            password: password
        )
        do {
            try await newSource.connect()
        } catch {
            logger.error("Connect failed for \(server.host)/\(server.share): \(error.localizedDescription)")
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
}
