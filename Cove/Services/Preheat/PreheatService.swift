import CacheKit
import Foundation
import PreheatKit
import SourceKit
import TraceKit

/// Preheat service: builds a `PreheatScheduler` whenever the
/// dedicated preheat connection (see `SMBSessionService`) comes up, and
/// applies the settings page's enable/rate-limit/folder values live.
///
/// A1 scope: only user-configured `preheatFolders` are preheated, and
/// preheating only ever targets the currently connected share — folder
/// entries naming another share are skipped, and nothing auto-connects at
/// launch. Directory-level preheating is deliberately off in A1.
@MainActor
final class PreheatService {
    /// Supplies the display-variant width (screen backing pixels) used for
    /// display-pool keys. Set by the window layer at startup; evaluated on
    /// the main actor each time a scheduler is built.
    var displayWidthProvider: @MainActor () -> Int = { 3024 }

    private let logger = TraceLogger(category: "preheat.service")
    private let settings: SettingsService
    private let cacheStore: CacheStore
    private var scheduler: PreheatScheduler?
    /// The live preheat connection and the share it points at.
    private var connection: (source: any ContentSource, share: String)?
    /// In-flight breadth-first enumeration of the configured folders.
    private var folderTask: Task<Void, Never>?
    /// The folder list as last submitted, so unrelated settings changes do
    /// not re-enumerate the NAS.
    private var submittedFolders: [String] = []

    init(settings: SettingsService, cacheStore: CacheStore) {
        self.settings = settings
        self.cacheStore = cacheStore
        settings.addChangeObserver { [weak self] in
            self?.settingsDidChange()
        }
    }

    // MARK: - Connection lifecycle (called by the coordinator)

    /// The preheat connection is up: (re)build the scheduler and kick off
    /// folder preheating.
    func connectionReady(source: any ContentSource, share: String) {
        connection = (source, share)
        rebuildScheduler()
        submitUserFolders()
    }

    /// The preheat connection went away (disconnect / share switch).
    func connectionClosed() {
        connection = nil
        teardown()
    }

    // MARK: - Settings

    private func settingsDidChange() {
        if settings.preheatEnabled {
            // A live scheduler adopts the new limit without losing its queue.
            if scheduler == nil { rebuildScheduler() }
            if let scheduler {
                Task { await scheduler.setRateLimit(bytesPerSecond: Self.rateLimitBytes(from: settings)) }
            }
        } else {
            teardown()
        }
        let folders = settings.preheatFolders
        if folders != submittedFolders {
            submitUserFolders()
        }
    }

    private static func rateLimitBytes(from settings: SettingsService) -> Int64? {
        let mbps = settings.preheatRateLimitMBps
        return mbps > 0 ? Int64(mbps * 1024 * 1024) : nil
    }

    // MARK: - Internals

    private func rebuildScheduler() {
        teardownScheduler()
        guard settings.preheatEnabled, let connection else { return }
        // Fixed per scheduler, like the reader fixes its width per session.
        let width = max(1, displayWidthProvider())
        scheduler = PreheatScheduler(
            source: connection.source,
            cache: cacheStore,
            displayWidthProvider: { width },
            maxConcurrent: 2,
            rateLimitBytesPerSecond: Self.rateLimitBytes(from: settings)
        )
    }

    /// Breadth-first enumeration of every configured folder belonging to the
    /// connected share; results queue at `.userFolder` priority. Enumeration
    /// runs on the preheat connection, so it never stalls browsing.
    private func submitUserFolders() {
        folderTask?.cancel()
        guard let scheduler, let connection, settings.preheatEnabled else { return }
        let folders = settings.preheatFolders
        submittedFolders = folders
        guard !folders.isEmpty else { return }
        let source = connection.source
        let share = connection.share
        folderTask = Task {
            for folder in folders {
                guard let root = Self.resolve(folder: folder, share: share) else {
                    logger.notice(
                        "Skipping preheat folder outside the connected share: \(folder)",
                        privacy: .private
                    )
                    continue
                }
                do {
                    let images = try await FolderEnumerator.collectImages(source: source, root: root)
                    guard !Task.isCancelled else { return }
                    await scheduler.submit(images, priority: .userFolder)
                    logger.info(
                        "Preheat folder \(folder): queued \(images.count) images",
                        privacy: .private
                    )
                } catch {
                    if Task.isCancelled { return }
                    logger.error(
                        "Preheat folder enumeration failed for \(folder): \(error.localizedDescription)",
                        privacy: .private
                    )
                }
            }
        }
    }

    /// Maps "share/a/b" → "/a/b" when `share` matches the connected share,
    /// "/" for a bare share name, nil when the entry names a different share
    /// (v0 preheats the connected share only).
    static func resolve(folder: String, share: String) -> String? {
        let trimmed = folder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first, String(first) == share else { return nil }
        let rest = parts.dropFirst().joined(separator: "/")
        return rest.isEmpty ? "/" : "/" + rest
    }

    /// Stops enumeration and scheduling; forgets the submitted folder list so
    /// a later re-enable re-enumerates from scratch.
    private func teardown() {
        submittedFolders = []
        folderTask?.cancel()
        folderTask = nil
        teardownScheduler()
    }

    private func teardownScheduler() {
        guard let scheduler else { return }
        self.scheduler = nil
        Task { await scheduler.cancelAll() }
    }
}
