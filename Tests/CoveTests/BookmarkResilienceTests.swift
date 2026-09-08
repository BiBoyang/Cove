import Foundation
import KeychainKit
import Security
import Testing
@testable import Cove

/// TASK-dev-bookmark-resilience: the "stored bookmark failed to resolve"
/// state is modelled separately from "no bookmark" so Preferences can
/// guide a re-pick, instead of silently falling back to the default root.
@Suite("Vault root status")
@MainActor
struct VaultRootStatusTests {
    @Test("classification: no bookmark vs resolved vs failed")
    func classify() {
        let url = URL(fileURLWithPath: "/tmp/vault")
        #expect(VaultRootStatus.classify(bookmark: nil, resolvedURL: nil) == .defaultRoot)
        #expect(VaultRootStatus.classify(bookmark: Data("bm".utf8), resolvedURL: url) == .bookmarkResolved)
        #expect(VaultRootStatus.classify(bookmark: Data("bm".utf8), resolvedURL: nil) == .bookmarkInvalid)
    }

    @Test("an unresolvable stored bookmark reports invalid and falls back to the default root")
    func invalidBookmarkIsObservable() throws {
        let suiteName = "VaultRootStatusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let settings = SettingsService(defaults: defaults)
        settings.vaultRootBookmark = Data("junk-bookmark".utf8)
        let vault = VaultService(settings: settings)

        #expect(vault.rootStatus == .bookmarkInvalid)
        #expect(vault.rootURL == VaultService.defaultRootURL)
    }

    @Test("no bookmark means the default root with no hint state")
    func noBookmarkIsDefault() {
        let suiteName = "VaultRootStatusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let vault = VaultService(settings: SettingsService(defaults: defaults))

        #expect(vault.rootStatus == .defaultRoot)
        #expect(vault.rootURL == VaultService.defaultRootURL)
    }

    @Test("re-picking the location rebuilds the bookmark and clears the invalid state")
    func repickRecovers() throws {
        let suiteName = "VaultRootStatusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let settings = SettingsService(defaults: defaults)
        settings.vaultRootBookmark = Data("junk-bookmark".utf8)
        let vault = VaultService(settings: settings)
        let viewModel = PreferencesViewModel(settings: settings, cache: StubCache(), vault: vault)
        #expect(viewModel.state.vaultBookmarkInvalid)

        // A container-local directory can be bookmarked without an open
        // panel — it stands in for the user's NSOpenPanel pick.
        let pick = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pick, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pick) }

        #expect(viewModel.chooseVaultRoot(pick))
        #expect(!viewModel.state.vaultBookmarkInvalid)
        #expect(vault.rootStatus == .bookmarkResolved)
        // Bookmark resolution may return symlink-resolved paths
        // (/var vs /private/var), so compare the resolved forms.
        #expect(vault.rootURL.resolvingSymlinksInPath() == pick.resolvingSymlinksInPath())
    }
}

/// Keychain read failures map to user-facing errors with a recovery path
/// (never a cryptic status code): -25300 keeps the existing wording, -128
/// (prompt denied) asks to retry, anything else points at the restart
/// self-heal.
@Suite("Keychain read error mapping")
struct KeychainReadErrorMappingTests {
    @Test("errSecItemNotFound keeps the existing missing-password wording")
    func itemNotFound() {
        let error = SessionError.keychainRead(.unhandled(status: errSecItemNotFound))
        #expect(error == .missingPassword)
        #expect(error.localizedDescription == "Keychain 中找不到该服务器的密码，请删除后重新添加。")
    }

    @Test("errSecUserCanceled guides a retry")
    func userCanceled() {
        let error = SessionError.keychainRead(.unhandled(status: errSecUserCanceled))
        #expect(error == .keychainPromptDenied)
        #expect(error.localizedDescription.contains("重试"))
    }

    @Test("any other status points at the restart self-heal")
    func otherStatus() {
        let error = SessionError.keychainRead(.unhandled(status: errSecAuthFailed))
        #expect(error == .keychainReadFailed)
        #expect(error.localizedDescription.contains("重启 App"))
    }

    @Test("success-with-empty-item (the 2026-09-05 error 0) is not silent")
    func unexpectedData() {
        let error = SessionError.keychainRead(.unexpectedData)
        #expect(error == .keychainReadFailed)
        #expect(error.localizedDescription.contains("重启 App"))
    }
}

private struct StubCache: PreferencesCacheManaging {
    func usage() throws -> (original: Int64, display: Int64) { (0, 0) }
    func clearAll() throws {}
}
