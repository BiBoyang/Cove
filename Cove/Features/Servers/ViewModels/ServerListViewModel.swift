import Foundation

@MainActor
final class ServerListViewModel {
    private(set) var servers: [ServerConfig] = []

    /// Row layout: row 0 is the "服务器" header, rows 1...N are servers,
    /// then a "本地" header, the fixed vault row, and the fixed settings row.
    var rowCount: Int { servers.count + 4 }
    var vaultHeaderRow: Int { servers.count + 1 }
    var vaultRow: Int { servers.count + 2 }
    var settingsRow: Int { servers.count + 3 }

    var onStateChange: (([ServerConfig]) -> Void)? {
        didSet { onStateChange?(servers) }
    }

    func update(servers: [ServerConfig]) {
        self.servers = servers
        onStateChange?(servers)
    }

    func isGroupRow(_ row: Int) -> Bool {
        row == 0 || row == vaultHeaderRow
    }

    func isVaultRow(_ row: Int) -> Bool {
        row == vaultRow
    }

    func isSettingsRow(_ row: Int) -> Bool {
        row == settingsRow
    }

    func server(atTableRow row: Int) -> ServerConfig? {
        guard row >= 1, servers.indices.contains(row - 1) else { return nil }
        return servers[row - 1]
    }
}
