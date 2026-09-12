import Foundation

/// Sidebar quick-access pins pointing at vault subfolders, as an ordered
/// [{path, alias?}] list. Pure value layer factored out of the
/// UserDefaults shell for unit testing (same discipline as
/// `ShareOpenRecords`). Paths are vault-relative in the LocalFileSource
/// form (leading "/"), so a vault-root move never invalidates them.
///
/// Display-level data only (folder path + optional alias, no secrets), so
/// `UserDefaults` is the sanctioned home (AGENTS.md rule 5). Pins are
/// never auto-removed: a missing folder is the caller's grey-out signal,
/// not this layer's business.
struct VaultPins: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// Vault-relative folder path, "/" prefix (LocalFileSource form).
        var path: String
        /// User-chosen display alias; nil shows the folder name.
        var alias: String?
    }

    /// Hard cap (decision 6, 2026-09-12): more rows would crowd the
    /// sidebar's bottom bar.
    static let maxCount = 8

    private(set) var entries: [Entry] = []

    init() {}

    /// Rebuilds from the persisted plist form. Malformed rows (no path)
    /// are dropped so one bad record cannot poison the whole list.
    init(plist: [[String: String]]) {
        entries = plist.compactMap { row in
            guard let path = row["path"], !path.isEmpty else { return nil }
            let alias = row["alias"].flatMap { $0.isEmpty ? nil : $0 }
            return Entry(path: path, alias: alias)
        }
    }

    /// Persisted plist form: ordered [{path, alias?}]; the alias key is
    /// omitted when nil.
    var plist: [[String: String]] {
        entries.map { entry in
            var row = ["path": entry.path]
            if let alias = entry.alias {
                row["alias"] = alias
            }
            return row
        }
    }

    func contains(path: String) -> Bool {
        entries.contains { $0.path == path }
    }

    /// Appends a pin at the end (row order = pin order). Refuses
    /// duplicates and entries beyond the cap; the boolean tells the caller
    /// whether the list changed.
    @discardableResult
    mutating func add(path: String) -> Bool {
        guard !path.isEmpty, !contains(path: path), entries.count < Self.maxCount else {
            return false
        }
        entries.append(Entry(path: path, alias: nil))
        return true
    }

    mutating func remove(path: String) {
        entries.removeAll { $0.path == path }
    }

    /// Sets or clears the alias of one pin. An empty/whitespace string
    /// clears (UI rule: empty input restores the folder's own name).
    mutating func setAlias(_ alias: String, forPath path: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        entries[index].alias = trimmed.isEmpty ? nil : trimmed
    }
}

/// UserDefaults persistence shell over `VaultPins`; same pattern as
/// `ShareOpenStore` (injected defaults so tests run on isolated suites).
/// Every mutation loads-mutates-saves, keeping the pure value the single
/// source of truth in between.
@MainActor
final class VaultPinStore {
    private enum Keys {
        static let entries = "cove.vaultPins.entries"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> VaultPins {
        VaultPins(plist: defaults.array(forKey: Keys.entries) as? [[String: String]] ?? [])
    }

    @discardableResult
    func add(path: String) -> Bool {
        var pins = load()
        guard pins.add(path: path) else { return false }
        save(pins)
        return true
    }

    func remove(path: String) {
        var pins = load()
        pins.remove(path: path)
        save(pins)
    }

    func setAlias(_ alias: String, forPath path: String) {
        var pins = load()
        pins.setAlias(alias, forPath: path)
        save(pins)
    }

    private func save(_ pins: VaultPins) {
        defaults.set(pins.plist, forKey: Keys.entries)
    }
}
