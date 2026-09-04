import Foundation

/// Infrastructure model for a persisted NAS server configuration.
///
/// The password is deliberately NOT part of this model; it lives in the
/// Keychain, keyed by `id` (see `SMBSessionService`). The share is not
/// stored either: shares are enumerated on connect and picked by the user.
struct ServerConfig: Codable, Equatable, Sendable {
    /// Which of the server's two addresses connections use.
    enum Endpoint: String, Codable, Sendable {
        case lan
        case remote
    }

    let id: UUID
    var host: String
    /// Optional remote address (Tailscale/WireGuard/public IP);
    /// nil means the server is LAN-only.
    var remoteHost: String?
    var username: String
    /// Sidebar label. Defaults to `host` when adding a server.
    var displayName: String
    /// The address connections use; persisted so a relaunch keeps the
    /// user's last choice. Pinned to `.lan` whenever `remoteHost` is nil.
    var activeEndpoint: Endpoint

    init(
        id: UUID,
        host: String,
        username: String,
        displayName: String? = nil,
        remoteHost: String? = nil,
        activeEndpoint: Endpoint = .lan
    ) {
        self.id = id
        self.host = host
        self.username = username
        self.displayName = displayName ?? host
        self.remoteHost = remoteHost?.trimmedNonEmpty
        self.activeEndpoint = self.remoteHost == nil ? .lan : activeEndpoint
    }

    /// Tolerates payloads written before `displayName`, `remoteHost`, and
    /// `activeEndpoint` existed. An unrecognized endpoint raw value falls
    /// back to `.lan` instead of failing the decode — one corrupt field
    /// must not wipe the whole stored list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        host = try container.decode(String.self, forKey: .host)
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost)?.trimmedNonEmpty
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? host
        let rawEndpoint = try container.decodeIfPresent(String.self, forKey: .activeEndpoint)
        activeEndpoint = (rawEndpoint.flatMap(Endpoint.init(rawValue:)) ?? .lan) == .remote && remoteHost != nil
            ? .remote
            : .lan
    }

    /// The address connections use right now: the remote address while the
    /// remote endpoint is active, the LAN host otherwise.
    var activeHost: String {
        activeEndpoint == .remote ? (remoteHost ?? host) : host
    }

    /// True when a remote address is configured but idle — the state in
    /// which connection failures suggest switching to it.
    var canSwitchToRemote: Bool {
        remoteHost != nil && activeEndpoint == .lan
    }
}

extension String {
    /// Whitespace-trimmed value, or nil when nothing remains.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
