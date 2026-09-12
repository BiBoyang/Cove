import Foundation

/// Pinned destination of the sidebar's bottom bar (vault / settings);
/// `none` marks a server-driven pane (share grid or browser) on screen.
enum SidebarDestination: Equatable {
    case none
    case vault
    case settings
}

@MainActor
final class ServerListViewModel {
    private(set) var servers: [ServerConfig] = []

    /// Which pinned destination is on screen; drives the bottom bar's
    /// highlight. Server destinations leave it at `.none`.
    private(set) var activeDestination: SidebarDestination = .none {
        didSet { onActiveDestinationChange?(activeDestination) }
    }

    /// Row layout: row 0 is the "服务器" header, rows 1...N are servers.
    /// The vault and settings destinations live outside the table, pinned
    /// in the sidebar's bottom bar.
    var rowCount: Int { servers.count + 1 }

    var onStateChange: (([ServerConfig]) -> Void)? {
        didSet { onStateChange?(servers) }
    }
    var onActiveDestinationChange: ((SidebarDestination) -> Void)? {
        didSet { onActiveDestinationChange?(activeDestination) }
    }

    func update(servers: [ServerConfig]) {
        self.servers = servers
        onStateChange?(servers)
    }

    func setActiveDestination(_ destination: SidebarDestination) {
        activeDestination = destination
    }

    func isGroupRow(_ row: Int) -> Bool {
        row == 0
    }

    func server(atTableRow row: Int) -> ServerConfig? {
        guard row >= 1, servers.indices.contains(row - 1) else { return nil }
        return servers[row - 1]
    }
}
