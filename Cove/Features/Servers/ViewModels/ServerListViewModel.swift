import Foundation

/// Pinned destination of the sidebar's bottom bar (home / vault /
/// settings); `none` marks a server-driven pane (share grid or browser)
/// on screen.
enum SidebarDestination: Equatable {
    case none
    case home
    case vault
    case settings
}

/// One vault pin as rendered by the sidebar's bottom bar: the stored
/// vault-relative path, the display title (alias ?? folder name), and
/// whether the target folder currently exists on disk. Pure value — no
/// AppKit types, per AGENTS.md rule 16.
struct VaultPinRow: Equatable, Sendable {
    var path: String
    var title: String
    var isAvailable: Bool

    init(path: String, alias: String?, isAvailable: Bool) {
        self.path = path
        let trimmed = alias?.trimmingCharacters(in: .whitespaces) ?? ""
        self.title = trimmed.isEmpty ? Self.folderName(for: path) : trimmed
        self.isAvailable = isAvailable
    }

    /// Folder name shown when no alias is set: the last path component.
    static func folderName(for path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

@MainActor
final class ServerListViewModel {
    private(set) var servers: [ServerConfig] = []

    /// Which pinned destination is on screen; drives the bottom bar's
    /// highlight. Server destinations leave it at `.none`.
    private(set) var activeDestination: SidebarDestination = .none {
        didSet { onActiveDestinationChange?(activeDestination) }
    }

    /// Vault quick-access pins shown between the vault and settings rows
    /// of the bottom bar; row order = pin order.
    private(set) var pins: [VaultPinRow] = []

    /// The pin whose subtree contains the browsed vault path, for the
    /// bar's "current pin" capsule; nil at the vault root, on unpinned
    /// paths, or outside the vault. Pure value, no AppKit (rule 16).
    private(set) var activePinPath: String? {
        didSet { onActivePinChange?(activePinPath) }
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
    var onPinsChange: (([VaultPinRow]) -> Void)? {
        didSet { onPinsChange?(pins) }
    }
    var onActivePinChange: ((String?) -> Void)? {
        didSet { onActivePinChange?(activePinPath) }
    }

    func update(servers: [ServerConfig]) {
        self.servers = servers
        onStateChange?(servers)
    }

    func setActiveDestination(_ destination: SidebarDestination) {
        activeDestination = destination
    }

    func update(pins: [VaultPinRow]) {
        self.pins = pins
        onPinsChange?(pins)
    }

    func setActivePinPath(_ path: String?) {
        activePinPath = path
    }

    /// The pin whose subtree contains `path`: an exact match or any path
    /// below it; the deepest (longest) pin wins when pins nest. Nil for
    /// the vault root or unpinned subtrees.
    static func activePin(forPath path: String, pinnedPaths: [String]) -> String? {
        var best: String?
        for pin in pinnedPaths where path == pin || path.hasPrefix(pin + "/") {
            if pin.count > (best?.count ?? 0) { best = pin }
        }
        return best
    }

    func isGroupRow(_ row: Int) -> Bool {
        row == 0
    }

    func server(atTableRow row: Int) -> ServerConfig? {
        guard row >= 1, servers.indices.contains(row - 1) else { return nil }
        return servers[row - 1]
    }
}
