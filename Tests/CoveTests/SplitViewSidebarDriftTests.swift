import AppKit
import Foundation
import Testing

@testable import Cove

/// Regression net for the main-window sidebar width drift (2026-09-07).
/// The settings pane's readable column used to fill via an optional
/// constraint coupled to the pane width (`width == pane - 40` at 999).
/// That coupling outranked the split view items' holding priority (250) and
/// dragged the divider whenever the pane mounted: the pane pulled itself to
/// its wanted width and the unconstrained sidebar absorbed the difference.
/// With a constant width target (`== 560` at 999) plus required bounds the
/// column still caps and fills identically, but the pane can no longer
/// exert width force on the split layout. The constraint-graph invariant is
/// asserted here; the rendered geometry (cap/fill parity) does not resolve
/// reliably off-screen and is covered by the manual acceptance checklist.
@Suite("Settings pane split view width behavior")
@MainActor
struct SettingsPaneSplitWidthTests {
    private func makePane() -> SettingsPaneViewController {
        SettingsPaneViewController(
            viewModel: PreferencesViewModel(
                settings: DriftProbeSettings(),
                cache: DriftProbeCache(),
                vault: VaultService(
                    root: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("cove-drift-test-vault")
                )
            )
        )
    }

    @Test("no optional width constraint couples the column to the pane width")
    func noOptionalWidthCouplingToPane() throws {
        let pane = makePane()
        let root = try #require(pane.view.subviews.first)

        // An optional (250 < p < 1000) width-to-width constraint lets the
        // pane's fitting wants reach the split view's divider arbitration,
        // which is how the sidebar drift happened.
        var offenders: [String] = []
        var queue: [NSView] = [root]
        while let view = queue.popLast() {
            queue.append(contentsOf: view.subviews)
            for constraint in view.constraints {
                guard constraint.firstAnchor is NSLayoutDimension,
                    constraint.secondAnchor is NSLayoutDimension
                else { continue }
                guard constraint.priority.rawValue > 250, constraint.priority.rawValue < 1000
                else { continue }
                offenders.append("\(constraint) @\(constraint.priority.rawValue)")
            }
        }
        #expect(offenders.isEmpty, "optional pane-coupled width constraints: \(offenders)")
    }
}

@MainActor
private final class DriftProbeSettings: PreferencesSettingsManaging {
    var cacheCapacityGB = 20
    var cacheTTLDays = 7
    var preheatEnabled = true
    var preheatRateLimitMBps = 0.0
    var preheatFolders: [String] = []
    var vaultRootBookmark: Data?
    var readerResumeOnOpen = true
}

private struct DriftProbeCache: PreferencesCacheManaging {
    func usage() throws -> (original: Int64, display: Int64) { (0, 0) }
    func clearAll() throws {}
}
