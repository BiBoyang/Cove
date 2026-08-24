import Foundation

@MainActor
protocol PreferencesSettingsManaging: AnyObject {
    var cacheCapacityGB: Int { get set }
    var cacheTTLDays: Int { get set }
    var preheatEnabled: Bool { get set }
    var preheatRateLimitMBps: Double { get set }
    var preheatFolders: [String] { get set }
    var vaultRootBookmark: Data? { get set }
}

extension SettingsService: PreferencesSettingsManaging {}

@MainActor
final class PreferencesViewModel {
    struct State: Sendable {
        let capacityGB: Int
        let ttlDays: Int
        let preheatEnabled: Bool
        let rateLimitMBps: Double
        let folders: [String]
        let originalUsageBytes: Int64?
        let displayUsageBytes: Int64?
        let vaultPath: String
    }

    private let settings: any PreferencesSettingsManaging
    private let cache: any PreferencesCacheManaging
    private let vault: VaultService
    /// Monotonic token for usage/clear requests. Every new request bumps
    /// it and captures the value; a result may only write state (or clear
    /// `usageTask`) while it still owns the newest generation, so a slow
    /// superseded task can never overwrite the user's latest numbers.
    private var usageGeneration = 0
    private var usageTask: Task<Void, Never>?
    private var originalUsageBytes: Int64?
    private var displayUsageBytes: Int64?

    var onStateChange: ((State) -> Void)? {
        didSet { publish() }
    }

    /// Fires when a clear owned by the current generation fails; the
    /// window turns the message into a user-facing alert. Errors from
    /// superseded tasks are silently dropped.
    var onClearError: ((_ message: String) -> Void)?

    var state: State {
        State(
            capacityGB: settings.cacheCapacityGB,
            ttlDays: settings.cacheTTLDays,
            preheatEnabled: settings.preheatEnabled,
            rateLimitMBps: settings.preheatRateLimitMBps,
            folders: settings.preheatFolders,
            originalUsageBytes: originalUsageBytes,
            displayUsageBytes: displayUsageBytes,
            vaultPath: vault.displayPath
        )
    }

    init(
        settings: any PreferencesSettingsManaging,
        cache: any PreferencesCacheManaging,
        vault: VaultService
    ) {
        self.settings = settings
        self.cache = cache
        self.vault = vault
    }

    /// The current vault root, for "在 Finder 中打开".
    var vaultRootURL: URL { vault.rootURL }

    /// Persists a user-chosen vault root as a security-scoped bookmark so
    /// sandboxed relaunches keep access. Only new downloads go there —
    /// files at the old location are never migrated (task decision).
    @discardableResult
    func chooseVaultRoot(_ url: URL) -> Bool {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }
        settings.vaultRootBookmark = bookmark
        publish()
        return true
    }

    func reload() {
        publish()
        refreshUsage()
    }

    @discardableResult
    func setCapacity(text: String) -> Bool {
        guard let value = Int(text), value >= 1 else { return false }
        settings.cacheCapacityGB = value
        publish()
        return true
    }

    @discardableResult
    func setTTL(text: String) -> Bool {
        guard let value = Int(text), value >= 1 else { return false }
        settings.cacheTTLDays = value
        publish()
        return true
    }

    @discardableResult
    func setRateLimit(text: String) -> Bool {
        guard let value = Double(text), value >= 0 else { return false }
        settings.preheatRateLimitMBps = value
        publish()
        return true
    }

    func setPreheatEnabled(_ enabled: Bool) {
        settings.preheatEnabled = enabled
        publish()
    }

    @discardableResult
    func addFolder(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var folders = settings.preheatFolders
        guard !path.isEmpty, !folders.contains(path) else { return false }
        folders.append(path)
        settings.preheatFolders = folders
        publish()
        return true
    }

    @discardableResult
    func removeFolder(at index: Int) -> Bool {
        var folders = settings.preheatFolders
        guard folders.indices.contains(index) else { return false }
        folders.remove(at: index)
        settings.preheatFolders = folders
        publish()
        return true
    }

    func refreshUsage() {
        usageGeneration += 1
        let generation = usageGeneration
        usageTask?.cancel()
        originalUsageBytes = nil
        displayUsageBytes = nil
        publish()
        let cache = cache
        usageTask = Task.detached(priority: .utility) { [weak self] in
            let usage = (try? cache.usage()) ?? (original: 0, display: 0)
            await self?.applyUsage(usage, generation: generation)
        }
    }

    func clearCache() {
        usageGeneration += 1
        let generation = usageGeneration
        usageTask?.cancel()
        let cache = cache
        usageTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try cache.clearAll()
            } catch {
                await self?.applyClearFailure(error, generation: generation)
            }
            // Even after a failed clear, refresh so the labels show the
            // real remaining usage instead of stale numbers.
            let usage = (try? cache.usage()) ?? (original: 0, display: 0)
            await self?.applyUsage(usage, generation: generation)
        }
    }

    private func applyUsage(
        _ usage: (original: Int64, display: Int64),
        generation: Int
    ) {
        guard generation == usageGeneration else { return }
        usageTask = nil
        originalUsageBytes = usage.original
        displayUsageBytes = usage.display
        publish()
    }

    private func applyClearFailure(_ error: Error, generation: Int) {
        guard generation == usageGeneration else { return }
        onClearError?(error.localizedDescription)
    }

    private func publish() {
        onStateChange?(state)
    }
}
