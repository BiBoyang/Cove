import Foundation

/// Pinned destination of the sidebar's bottom bar (home / vault /
/// settings); `none` marks a server-driven pane (share grid or browser)
/// on screen.
enum SidebarDestination: Equatable {
    case none
    case home
    case vault
    case settings
    /// A user-added local folder is on screen (TASK-local-folder-browse);
    /// the id anchors the future sidebar row's highlight. No bottom-bar
    /// row lights for it today (SidebarBottomBar compares per row).
    case localFolder(id: String)
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

/// One user-added local folder as rendered by the sidebar's "本地文件夹"
/// section: the stable id (anchors the open intent and the highlight), the
/// display name, and whether the stored bookmark currently resolves (an
/// unresolved one greys the row out and offers the re-pick menu item).
/// Pure value — no AppKit types, per AGENTS.md rule 16.
struct LocalFolderRow: Equatable, Sendable {
    var id: String
    var name: String
    var isAvailable: Bool
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

    /// User-added local folders rendered in the table's second section,
    /// below the servers (TASK-local-folder-sidebar); row order = add
    /// order. The section header stays even with zero folders so its add
    /// button is always reachable.
    private(set) var localFolders: [LocalFolderRow] = []

    /// The pin whose subtree contains the browsed vault path, for the
    /// bar's "current pin" capsule; nil at the vault root, on unpinned
    /// paths, or outside the vault. Pure value, no AppKit (rule 16).
    private(set) var activePinPath: String? {
        didSet { onActivePinChange?(activePinPath) }
    }

    /// Row layout: row 0 is the "服务器" header, rows 1...S are servers,
    /// row S+1 is the "本地文件夹" header (always present, even with zero
    /// folders, so its add button stays reachable), rows S+2... are the
    /// local folders. The vault and settings destinations live outside the
    /// table, pinned in the sidebar's bottom bar.
    var rowCount: Int { servers.count + 2 + localFolders.count }

    /// The "本地文件夹" section header's row, derived from the server
    /// count; everything below it is a local folder row.
    private var localFolderHeaderRow: Int { servers.count + 1 }

    var onStateChange: (([ServerConfig]) -> Void)? {
        didSet { onStateChange?(servers) }
    }
    var onActiveDestinationChange: ((SidebarDestination) -> Void)? {
        didSet { onActiveDestinationChange?(activeDestination) }
    }
    var onPinsChange: (([VaultPinRow]) -> Void)? {
        didSet { onPinsChange?(pins) }
    }
    var onLocalFoldersChange: (([LocalFolderRow]) -> Void)? {
        didSet { onLocalFoldersChange?(localFolders) }
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
        // The pin capsule is vault-only: leaving the vault drops it, so
        // the bar can never light a pin row next to another destination.
        // Vault entry re-pins via loadDirectory after this assignment.
        if destination != .vault {
            activePinPath = nil
        }
    }

    func update(pins: [VaultPinRow]) {
        self.pins = pins
        onPinsChange?(pins)
    }

    func update(localFolders: [LocalFolderRow]) {
        self.localFolders = localFolders
        onLocalFoldersChange?(localFolders)
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

    /// Both section headers ("服务器" at row 0, "本地文件夹" below the
    /// servers) are group rows.
    func isGroupRow(_ row: Int) -> Bool {
        row == 0 || row == localFolderHeaderRow
    }

    func isLocalFolderHeaderRow(_ row: Int) -> Bool {
        row == localFolderHeaderRow
    }

    func server(atTableRow row: Int) -> ServerConfig? {
        guard row >= 1, servers.indices.contains(row - 1) else { return nil }
        return servers[row - 1]
    }

    func localFolder(atTableRow row: Int) -> LocalFolderRow? {
        let index = row - localFolderHeaderRow - 1
        guard localFolders.indices.contains(index) else { return nil }
        return localFolders[index]
    }

    /// The table row of a local folder id, for highlight sync; nil when
    /// the entry is gone (e.g. removed while it is being browsed).
    func tableRow(forLocalFolderID id: String) -> Int? {
        localFolders.firstIndex(where: { $0.id == id }).map { localFolderHeaderRow + 1 + $0 }
    }
}
