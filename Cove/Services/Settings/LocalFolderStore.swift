import Foundation
import TraceKit

/// Local folders added by the user as first-class sources
/// (TASK-local-folder-store), as an ordered [{id, name, bookmark}] list.
/// Pure value layer factored out of the UserDefaults shell for unit
/// testing (same discipline as `VaultPins`).
///
/// Each entry holds a security-scoped bookmark for a folder the user
/// picked via NSOpenPanel — the sandbox only grants
/// `com.apple.security.files.user-selected.read-write`, so the bookmark
/// is what restores access across launches (same semantics as
/// `VaultService.resolveRoot`). Display-level data only (folder name +
/// bookmark, no secrets), so `UserDefaults` is the sanctioned home
/// (AGENTS.md rule 5).
struct LocalFolders: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// Stable UUID string, generated once at add time and never
        /// changed: it anchors `LocalFileSource(sourceID: "local://<id>")`,
        /// which is the cache key and progress-record identity.
        var id: String
        /// Display name (the folder's own name by default).
        var name: String
        /// Security-scoped bookmark data, base64-encoded for plist
        /// storage.
        var bookmark: String
    }

    /// Hard cap: more rows would crowd the sidebar's source list.
    static let maxCount = 16

    private(set) var entries: [Entry] = []

    init() {}

    /// Rebuilds from the persisted plist form. Malformed rows (missing/
    /// empty fields, non-UUID id, non-base64 bookmark) are dropped so one
    /// bad record cannot poison the whole list.
    init(plist: [[String: String]]) {
        entries = plist.compactMap { row in
            guard let id = row["id"], UUID(uuidString: id) != nil,
                  let name = row["name"], !name.isEmpty,
                  let bookmark = row["bookmark"], !bookmark.isEmpty,
                  Data(base64Encoded: bookmark) != nil else { return nil }
            return Entry(id: id, name: name, bookmark: bookmark)
        }
    }

    /// Persisted plist form: ordered [{id, name, bookmark}].
    var plist: [[String: String]] {
        entries.map { ["id": $0.id, "name": $0.name, "bookmark": $0.bookmark] }
    }

    func contains(id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    /// Appends a folder at the end (row order = sidebar order). Refuses a
    /// bookmark already stored (the same bookmark resolves to the same
    /// path, so one path never appears twice) and entries beyond the cap.
    /// Returns the new entry's id on success, nil on refusal.
    @discardableResult
    mutating func add(name: String, bookmark: Data) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let encoded = bookmark.base64EncodedString()
        guard !trimmed.isEmpty, !bookmark.isEmpty,
              !entries.contains(where: { $0.bookmark == encoded }),
              entries.count < Self.maxCount else { return nil }
        let id = UUID().uuidString
        entries.append(Entry(id: id, name: trimmed, bookmark: encoded))
        return id
    }

    mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    /// Replaces the bookmark of one entry (the re-pick path for an
    /// invalid bookmark). Refuses an unknown id and a bookmark that
    /// duplicates another entry.
    @discardableResult
    mutating func replace(id: String, bookmark: Data) -> Bool {
        let encoded = bookmark.base64EncodedString()
        guard !bookmark.isEmpty,
              let index = entries.firstIndex(where: { $0.id == id }),
              !entries.contains(where: { $0.id != id && $0.bookmark == encoded }) else {
            return false
        }
        entries[index].bookmark = encoded
        return true
    }
}

/// Observable resolution state of one local folder's bookmark: a stored
/// bookmark that fails to resolve is NOT the same as a working one — the
/// former surfaces as a re-pick hint (same modelling as
/// `VaultRootStatus`).
enum LocalFolderStatus: Equatable, Sendable {
    /// The stored bookmark resolved; the folder is accessible.
    case ready
    /// The stored bookmark is missing or failed to resolve; the folder
    /// stays listed but needs a re-pick.
    case bookmarkInvalid

    /// Pure classification so resolution outcomes are unit-testable
    /// without the real bookmark API.
    static func classify(bookmark: Data?, resolvedURL: URL?) -> LocalFolderStatus {
        guard let bookmark, !bookmark.isEmpty else { return .bookmarkInvalid }
        return resolvedURL != nil ? .ready : .bookmarkInvalid
    }
}

/// UserDefaults persistence shell over `LocalFolders`, plus security-
/// scoped bookmark resolution; same patterns as `VaultPinStore`
/// (injected defaults so tests run on isolated suites, every mutation
/// loads-mutates-saves) and `VaultService.resolveRoot`.
@MainActor
final class LocalFolderStore {
    private enum Keys {
        static let entries = "cove.localFolders.entries"
    }

    private let defaults: UserDefaults
    private let logger = TraceLogger(category: "LocalFolders")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LocalFolders {
        LocalFolders(plist: defaults.array(forKey: Keys.entries) as? [[String: String]] ?? [])
    }

    @discardableResult
    func add(name: String, bookmark: Data) -> String? {
        var folders = load()
        guard let id = folders.add(name: name, bookmark: bookmark) else { return nil }
        save(folders)
        return id
    }

    func remove(id: String) {
        var folders = load()
        folders.remove(id: id)
        save(folders)
    }

    @discardableResult
    func replace(id: String, bookmark: Data) -> Bool {
        var folders = load()
        guard folders.replace(id: id, bookmark: bookmark) else { return false }
        save(folders)
        return true
    }

    /// Resolves one entry's security-scoped bookmark. On success the
    /// access grant is kept for the process lifetime — the grant is cheap
    /// and the folder is read repeatedly (same trade-off as the vault
    /// root). A stale bookmark resolves fine but is logged at notice
    /// level; re-saving it is the caller's job.
    func resolve(id: String) -> (url: URL?, status: LocalFolderStatus) {
        guard let entry = load().entries.first(where: { $0.id == id }),
              let bookmark = Data(base64Encoded: entry.bookmark) else {
            return (nil, .bookmarkInvalid)
        }
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        )
        let status = LocalFolderStatus.classify(bookmark: bookmark, resolvedURL: url)
        guard let url else {
            logger.error("Local folder bookmark failed to resolve; a re-pick is needed", privacy: .public)
            return (nil, status)
        }
        _ = url.startAccessingSecurityScopedResource()
        if isStale {
            logger.notice("Local folder bookmark is stale; re-saving is the caller's job", privacy: .public)
        }
        return (url, status)
    }

    private func save(_ folders: LocalFolders) {
        defaults.set(folders.plist, forKey: Keys.entries)
    }
}
