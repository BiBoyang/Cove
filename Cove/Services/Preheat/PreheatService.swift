import CacheKit
import Foundation
import PreheatKit
import SourceKit
import TraceKit

/// Preheat service: builds a `PreheatScheduler` whenever the
/// dedicated preheat connection (see `SMBSessionService`) comes up, and
/// applies the settings page's enable/rate-limit/folder values live.
///
/// A1 scope: user-configured `preheatFolders` are preheated, and
/// preheating only ever targets the currently connected share — folder
/// entries naming another share are skipped, and nothing auto-connects at
/// launch. A2 adds single-directory preheating on demand (the browser's
/// "preheat this folder" button) at `.currentDirectory` priority.
@MainActor
final class PreheatService {
    /// Snapshot of the active on-demand directory preheat, for the browser
    /// toolbar button. `remaining` counts only queued `.currentDirectory`
    /// jobs — in-flight ones (≤ maxConcurrent) are not included, so
    /// `isComplete` may flip while the last reads finish.
    struct DirectoryPreheatProgress: Sendable, Equatable {
        /// Images submitted for this directory; 0 while still enumerating.
        let total: Int
        /// Jobs still waiting in the `.currentDirectory` queue.
        let remaining: Int
        /// Jobs failed since this preheat started (global counter delta;
        /// concurrent userFolder failures bleed in slightly).
        let failed: Int
        let throughputBytesPerSecond: Double

        var isComplete: Bool { total > 0 && remaining == 0 }
    }
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
    /// The active on-demand directory preheat: path, submitted image count
    /// (0 while enumerating), and the scheduler's failed count at submit
    /// time, so the progress snapshot reports only this batch's failures.
    private var directoryPreheat: (path: String, total: Int, failedBaseline: Int)?
    /// In-flight single-level enumeration for the directory preheat.
    private var directoryTask: Task<Void, Never>?

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

    // MARK: - Directory preheat (browser "preheat this folder" button)

    /// Whether an on-demand directory preheat is active (enumerating,
    /// queued, or finished but not yet dismissed by navigation/cancel).
    var isDirectoryPreheatActive: Bool { directoryPreheat != nil }

    /// Preheats the images directly inside `path` — one level, no
    /// recursion — at `.currentDirectory` priority, so they jump ahead of
    /// queued userFolder work but behind the reader's `.immediate` jobs.
    /// Replaces any in-progress directory preheat. Safe no-op without a
    /// live scheduler/connection or when preheating is disabled.
    func preheatDirectory(path: String) {
        cancelDirectoryPreheat()
        guard let scheduler, let connection, settings.preheatEnabled else { return }
        // Mark active synchronously so the first progress poll sees a
        // (still enumerating, total 0) snapshot instead of "inactive".
        directoryPreheat = (path, 0, 0)
        let source = connection.source
        directoryTask = Task {
            do {
                let images = try await FolderEnumerator.listImages(source: source, directory: path)
                guard !Task.isCancelled else { return }
                guard !images.isEmpty else {
                    directoryPreheat = nil
                    return
                }
                let failedBaseline = await scheduler.failedCount
                directoryPreheat = (path, images.count, failedBaseline)
                await scheduler.submit(images, priority: .currentDirectory)
                logger.info(
                    "Preheat directory \(path): queued \(images.count) images",
                    privacy: .private
                )
            } catch {
                if Task.isCancelled { return }
                directoryPreheat = nil
                logger.error(
                    "Preheat directory enumeration failed for \(path): \(error.localizedDescription)",
                    privacy: .private
                )
            }
        }
    }

    /// Cancels the active directory preheat: stops the enumeration and
    /// drops the `.currentDirectory` queue without touching userFolder
    /// work. Safe no-op when nothing is active.
    func cancelDirectoryPreheat() {
        directoryTask?.cancel()
        directoryTask = nil
        directoryPreheat = nil
        if let scheduler {
            Task { await scheduler.cancel(priority: .currentDirectory) }
        }
    }

    /// Progress of the active directory preheat; nil when none is active
    /// (never started, cancelled, or enumeration failed).
    func directoryPreheatProgress() async -> DirectoryPreheatProgress? {
        guard let scheduler, let state = directoryPreheat else { return nil }
        let remaining = await scheduler.pendingCount(priority: .currentDirectory)
        let failed = await scheduler.failedCount - state.failedBaseline
        let throughput = await scheduler.throughputBytesPerSecond
        return DirectoryPreheatProgress(
            total: state.total,
            remaining: remaining,
            failed: max(0, failed),
            throughputBytesPerSecond: throughput
        )
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
        cancelDirectoryPreheat()
        teardownScheduler()
    }

    private func teardownScheduler() {
        guard let scheduler else { return }
        self.scheduler = nil
        Task { await scheduler.cancelAll() }
    }
}
