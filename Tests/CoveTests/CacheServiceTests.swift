import CacheKit
import Foundation
import Testing
@testable import Cove

/// The periodic background sweep: with preheating off or in vault-only
/// sessions the event-driven eviction triggers (init, settings change,
/// preheat batches) may never fire again after launch, so the service
/// sweeps on a fixed cadence instead.
@Suite("Cache service")
@MainActor
struct CacheServiceTests {
    @Test("the periodic sweep brings usage back within budget")
    func periodicSweepEvictsOverBudget() async throws {
        let suiteName = "CacheServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let interval = 0.05  // seconds; milliseconds-level for the test
        let settings = SettingsService(defaults: defaults)
        let service = CacheService(
            settings: settings,
            sweepInterval: interval,
            rootDirectory: root
        )
        // Let the init-time sweep and the first tick drain on the empty
        // store, so the over-budget data stored below can only be evicted
        // by a later periodic sweep.
        try await Task.sleep(for: .seconds(2 * interval))

        // The settings-backed budget is clamped to whole gigabytes, so the
        // test shrinks the policy directly through the store's public API.
        let budget: Int64 = 512
        let entryBytes = Data((0..<400).map { UInt8($0 % 251) })
        service.store.setPolicy(capacityBytes: budget, ttl: 24 * 60 * 60)
        for index in 0..<3 {
            let key = CacheKey.sourceFile(
                sourceID: "test://cache", path: "/entry-\(index).bin",
                fileSize: Int64(entryBytes.count), modified: Date(), variant: CacheKey.rawVariant
            )
            try service.store.store(entryBytes, forKey: key, pool: .original)
        }

        // Poll past several sweep intervals; the cache must settle within
        // budget well before the deadline.
        var usage = try service.store.currentSize(pool: nil)
        let deadline = Date().addingTimeInterval(5)
        while usage > budget, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            usage = try service.store.currentSize(pool: nil)
        }
        #expect(usage <= budget)
    }
}
