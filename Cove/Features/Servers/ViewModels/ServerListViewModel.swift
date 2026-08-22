import Foundation

@MainActor
final class ServerListViewModel {
    private(set) var servers: [ServerConfig] = []

    var onStateChange: (([ServerConfig]) -> Void)? {
        didSet { onStateChange?(servers) }
    }

    func update(servers: [ServerConfig]) {
        self.servers = servers
        onStateChange?(servers)
    }

    func server(atTableRow row: Int) -> ServerConfig? {
        guard row >= 1, servers.indices.contains(row - 1) else { return nil }
        return servers[row - 1]
    }
}
