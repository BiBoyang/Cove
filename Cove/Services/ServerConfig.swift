import Foundation

/// Persisted NAS server configuration.
///
/// The password is deliberately NOT part of this model; it lives in the
/// Keychain, keyed by `id` (see `SMBSessionService`).
struct ServerConfig: Codable, Equatable, Sendable {
    let id: UUID
    var host: String
    var share: String
    var username: String

    var displayName: String {
        "\(username)@\(host) / \(share)"
    }
}

/// Persists the server list in `UserDefaults` (JSON-encoded).
final class ServerStore {
    private let key = "cove.servers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [ServerConfig] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ServerConfig].self, from: data)) ?? []
    }

    func save(_ servers: [ServerConfig]) {
        defaults.set(try? JSONEncoder().encode(servers), forKey: key)
    }
}
