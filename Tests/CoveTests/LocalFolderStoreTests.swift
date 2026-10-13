import Foundation
import Testing
@testable import Cove

/// Pure value semantics of `LocalFolders`: ordering, cap, dedupe, replace
/// rules, and the plist round-trip. No AppKit, no UserDefaults.
@Suite("Local folders value")
struct LocalFoldersValueTests {
    private func bookmark(_ seed: String) -> Data {
        Data("bookmark-\(seed)".utf8)
    }

    @Test("add appends in order and returns a fresh UUID id")
    func addAndOrder() {
        var folders = LocalFolders()
        let first = folders.add(name: "Movies", bookmark: bookmark("a"))
        let second = folders.add(name: "Comics", bookmark: bookmark("b"))
        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
        #expect(UUID(uuidString: first ?? "") != nil)
        #expect(folders.entries.map(\.name) == ["Movies", "Comics"])
        #expect(folders.contains(id: first ?? ""))
    }

    @Test("add refuses a duplicate bookmark, empty name, and empty bookmark")
    func dedupeAndEmptyInput() {
        var folders = LocalFolders()
        let data = bookmark("same")
        #expect(folders.add(name: "Movies", bookmark: data) != nil)
        // Same bookmark = same resolved path: no second row.
        #expect(folders.add(name: "Alias", bookmark: data) == nil)
        #expect(folders.entries.count == 1)
        #expect(folders.add(name: "", bookmark: bookmark("b")) == nil)
        #expect(folders.add(name: "   ", bookmark: bookmark("b")) == nil)
        #expect(folders.add(name: "NoBookmark", bookmark: Data()) == nil)
        #expect(folders.entries.count == 1)
    }

    @Test("the cap of 16 is enforced and refuses the seventeenth folder")
    func cap() {
        var folders = LocalFolders()
        for index in 1...LocalFolders.maxCount {
            #expect(folders.add(name: "dir\(index)", bookmark: bookmark("\(index)")) != nil)
        }
        #expect(folders.entries.count == LocalFolders.maxCount)
        #expect(folders.add(name: "one-too-many", bookmark: bookmark("overflow")) == nil)
        #expect(folders.entries.count == LocalFolders.maxCount)
    }

    @Test("remove drops only the matching entry")
    func remove() {
        var folders = LocalFolders()
        let keep = folders.add(name: "a", bookmark: bookmark("a"))
        let drop = folders.add(name: "b", bookmark: bookmark("b"))
        folders.remove(id: drop ?? "")
        #expect(folders.entries.count == 1)
        #expect(folders.entries.first?.id == keep)
        // Unknown id is a no-op, not a crash.
        folders.remove(id: UUID().uuidString)
        #expect(folders.entries.count == 1)
    }

    @Test("replace swaps the bookmark but refuses duplicates and unknown ids")
    func replace() {
        var folders = LocalFolders()
        let first = folders.add(name: "a", bookmark: bookmark("a")) ?? ""
        let second = folders.add(name: "b", bookmark: bookmark("b")) ?? ""
        // #expect's function-call fast path passes an immutable value,
        // so mutating calls are evaluated into locals first.
        let replaced = folders.replace(id: first, bookmark: bookmark("a-new"))
        #expect(replaced)
        #expect(folders.entries[0].bookmark == bookmark("a-new").base64EncodedString())
        // Duplicating another entry's bookmark is refused.
        let duplicate = folders.replace(id: first, bookmark: bookmark("b"))
        #expect(!duplicate)
        // Unknown id and empty bookmark are refused.
        let unknownID = folders.replace(id: UUID().uuidString, bookmark: bookmark("x"))
        let emptyBookmark = folders.replace(id: second, bookmark: Data())
        #expect(!unknownID)
        #expect(!emptyBookmark)
        #expect(folders.entries.count == 2)
    }

    @Test("plist round-trip preserves order, names, and bookmarks")
    func plistRoundTrip() {
        var folders = LocalFolders()
        folders.add(name: "Movies", bookmark: bookmark("a"))
        folders.add(name: "漫画", bookmark: bookmark("b"))
        let restored = LocalFolders(plist: folders.plist)
        #expect(restored == folders)
        #expect(restored.entries.map(\.name) == ["Movies", "漫画"])
    }

    @Test("plist init drops malformed rows")
    func malformedPlist() {
        let valid = bookmark("ok").base64EncodedString()
        let folders = LocalFolders(plist: [
            ["id": UUID().uuidString, "name": "ok", "bookmark": valid],
            ["name": "no id", "bookmark": valid],
            ["id": "not-a-uuid", "name": "bad id", "bookmark": valid],
            ["id": UUID().uuidString, "bookmark": valid],
            ["id": UUID().uuidString, "name": "", "bookmark": valid],
            ["id": UUID().uuidString, "name": "no bookmark"],
            ["id": UUID().uuidString, "name": "bad base64", "bookmark": "!!!not-base64!!!"],
        ])
        #expect(folders.entries.count == 1)
        #expect(folders.entries.first?.name == "ok")
    }
}

/// `LocalFolderStatus.classify`: no bookmark vs resolved vs failed.
@Suite("Local folder status")
struct LocalFolderStatusTests {
    @Test("classification covers the three inputs")
    func classify() {
        let url = URL(fileURLWithPath: "/tmp/local")
        #expect(LocalFolderStatus.classify(bookmark: nil, resolvedURL: nil) == .bookmarkInvalid)
        #expect(LocalFolderStatus.classify(bookmark: Data("bm".utf8), resolvedURL: url) == .ready)
        #expect(LocalFolderStatus.classify(bookmark: Data("bm".utf8), resolvedURL: nil) == .bookmarkInvalid)
    }
}

/// The UserDefaults shell on an isolated suite: mutations persist across
/// store instances, and resolve() round-trips a real security-scoped
/// bookmark. Never touches the standard domain.
@Suite("Local folder store shell")
@MainActor
struct LocalFolderStoreShellTests {
    private func makeSuite(_ label: String) -> (String, UserDefaults) {
        let name = "LocalFolderStoreShellTests-\(label)-\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test("add/replace/remove persist through an isolated suite")
    func persistence() {
        let (suiteName, defaults) = makeSuite("persistence")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalFolderStore(defaults: defaults)

        let first = store.add(name: "Movies", bookmark: Data("bm-a".utf8))
        store.add(name: "Comics", bookmark: Data("bm-b".utf8))
        #expect(first != nil)

        let reloaded = LocalFolderStore(defaults: defaults).load()
        #expect(reloaded.entries.map(\.name) == ["Movies", "Comics"])

        #expect(store.replace(id: first ?? "", bookmark: Data("bm-a2".utf8)))
        store.remove(id: first ?? "")
        let afterRemove = LocalFolderStore(defaults: defaults).load()
        #expect(afterRemove.entries.map(\.name) == ["Comics"])
    }

    @Test("a fresh suite starts empty")
    func emptySuite() {
        let (suiteName, defaults) = makeSuite("empty")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(LocalFolderStore(defaults: defaults).load().entries.isEmpty)
    }

    @Test("resolve returns invalid for unknown ids and junk bookmarks")
    func resolveInvalid() {
        let (suiteName, defaults) = makeSuite("invalid")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalFolderStore(defaults: defaults)

        let unknown = store.resolve(id: UUID().uuidString)
        #expect(unknown.url == nil)
        #expect(unknown.status == .bookmarkInvalid)

        // A base64-valid blob that is not a bookmark resolves to nil.
        let id = store.add(name: "Junk", bookmark: Data("junk-bookmark".utf8)) ?? ""
        let junk = store.resolve(id: id)
        #expect(junk.url == nil)
        #expect(junk.status == .bookmarkInvalid)
    }

    @Test("resolve round-trips a real security-scoped bookmark")
    func resolveReady() throws {
        let (suiteName, defaults) = makeSuite("ready")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A container-local directory can be bookmarked without an open
        // panel — it stands in for the user's NSOpenPanel pick (same
        // pattern as VaultRootStatusTests).
        let pick = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pick, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pick) }
        let bookmark = try pick.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let store = LocalFolderStore(defaults: defaults)
        let id = store.add(name: "Pick", bookmark: bookmark)
        #expect(id != nil)

        let resolved = store.resolve(id: id ?? "")
        #expect(resolved.status == .ready)
        // Bookmark resolution may return symlink-resolved paths
        // (/var vs /private/var), so compare the resolved forms.
        #expect(resolved.url?.resolvingSymlinksInPath() == pick.resolvingSymlinksInPath())
    }
}
