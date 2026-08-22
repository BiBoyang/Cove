import Foundation

/// Infrastructure model for a persisted NAS server configuration.
///
/// The password is deliberately NOT part of this model; it lives in the
/// Keychain, keyed by `id` (see `SMBSessionService`). The share is not
/// stored either: shares are enumerated on connect and picked by the user.
struct ServerConfig: Codable, Equatable, Sendable {
    let id: UUID
    var host: String
    var username: String
    /// Sidebar label. Defaults to `host` when adding a server.
    var displayName: String

    init(id: UUID, host: String, username: String, displayName: String? = nil) {
        self.id = id
        self.host = host
        self.username = username
        self.displayName = displayName ?? host
    }

    /// Tolerates payloads written before `displayName` existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        host = try container.decode(String.self, forKey: .host)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? host
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

    /// Persists the list. Encoding failures are thrown — the old `try?`
    /// variant could pass `nil` to `set(_:forKey:)`, which *removes* the
    /// key and silently wipes the store.
    func save(_ servers: [ServerConfig]) throws {
        let data = try JSONEncoder().encode(servers)
        defaults.set(data, forKey: key)
    }
}
