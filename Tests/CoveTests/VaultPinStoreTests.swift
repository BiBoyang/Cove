import Foundation
import Testing
@testable import Cove

/// Pure value semantics of `VaultPins`: ordering, cap, dedupe, alias
/// rules, and the plist round-trip. No AppKit, no UserDefaults.
@Suite("Vault pins value")
struct VaultPinsValueTests {
    @Test("add appends in order and refuses duplicates")
    func addAndDedupe() {
        var pins = VaultPins()
        #expect(pins.add(path: "/Movies") == true)
        #expect(pins.add(path: "/Comics") == true)
        // Duplicate: no second row, order untouched.
        #expect(pins.add(path: "/Movies") == false)
        #expect(pins.entries.map(\.path) == ["/Movies", "/Comics"])
    }

    @Test("the cap of 8 is enforced and refuses the ninth pin")
    func cap() {
        var pins = VaultPins()
        for index in 1...VaultPins.maxCount {
            #expect(pins.add(path: "/dir\(index)") == true)
        }
        #expect(pins.entries.count == VaultPins.maxCount)
        #expect(pins.add(path: "/one-too-many") == false)
        #expect(pins.entries.count == VaultPins.maxCount)
    }

    @Test("remove drops only the matching entry; empty paths are refused")
    func remove() {
        var pins = VaultPins()
        pins.add(path: "/a")
        pins.add(path: "/b")
        pins.remove(path: "/a")
        #expect(pins.entries.map(\.path) == ["/b"])
        #expect(pins.contains(path: "/a") == false)
        #expect(pins.add(path: "") == false)
    }

    @Test("setAlias sets, trims, and clears on empty input")
    func alias() {
        var pins = VaultPins()
        pins.add(path: "/Movies")
        pins.setAlias("  动画  ", forPath: "/Movies")
        #expect(pins.entries[0].alias == "动画")
        // Unknown path is a no-op, not a crash.
        pins.setAlias("x", forPath: "/nope")
        #expect(pins.entries.count == 1)
        // Empty (and whitespace-only) restores nil = the folder name.
        pins.setAlias("", forPath: "/Movies")
        #expect(pins.entries[0].alias == nil)
        pins.setAlias("   ", forPath: "/Movies")
        #expect(pins.entries[0].alias == nil)
    }

    @Test("plist round-trip preserves order and aliases")
    func plistRoundTrip() {
        var pins = VaultPins()
        pins.add(path: "/Movies")
        pins.add(path: "/Comics/DC")
        pins.setAlias("漫画", forPath: "/Comics/DC")
        let restored = VaultPins(plist: pins.plist)
        #expect(restored == pins)
        #expect(restored.entries.map(\.path) == ["/Movies", "/Comics/DC"])
        #expect(restored.entries[1].alias == "漫画")
        #expect(restored.entries[0].alias == nil)
    }

    @Test("plist init drops malformed rows and normalizes empty aliases")
    func malformedPlist() {
        let pins = VaultPins(plist: [
            ["path": "/ok"],
            ["alias": "no path"],
            ["path": "", "alias": "empty path"],
            ["path": "/clean", "alias": ""],
        ])
        #expect(pins.entries == [
            VaultPins.Entry(path: "/ok", alias: nil),
            VaultPins.Entry(path: "/clean", alias: nil),
        ])
    }
}

/// The UserDefaults shell on an isolated suite: mutations persist across
/// store instances and never touch the standard domain.
@Suite("Vault pin store shell")
@MainActor
struct VaultPinStoreShellTests {
    @Test("add/remove/alias persist through an isolated suite")
    func persistence() {
        let suiteName = "VaultPinStoreShellTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = VaultPinStore(defaults: defaults)

        store.add(path: "/Movies")
        store.add(path: "/Comics")
        store.setAlias("动画", forPath: "/Movies")

        // A fresh shell over the same suite sees the same pins.
        let reloaded = VaultPinStore(defaults: defaults).load()
        #expect(reloaded.entries == [
            VaultPins.Entry(path: "/Movies", alias: "动画"),
            VaultPins.Entry(path: "/Comics", alias: nil),
        ])

        store.remove(path: "/Comics")
        #expect(VaultPinStore(defaults: defaults).load().entries.map(\.path) == ["/Movies"])

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("a fresh suite starts empty")
    func emptySuite() {
        let suiteName = "VaultPinStoreShellTests-empty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        #expect(VaultPinStore(defaults: defaults).load().entries.isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
