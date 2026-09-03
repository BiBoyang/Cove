import SourceKit

/// How the queue behaves when a video ends (and how prev/next step).
/// UI labels are Chinese; identifiers stay English.
enum PlayMode: Sendable, Equatable, CaseIterable {
    /// Play the current video, park on its last frame at the end.
    case single
    /// Replay the current video forever.
    case repeatOne
    /// Advance through the queue in order; park at the queue's end.
    case list
    /// Advance in order and wrap back to the first video.
    case listLoop
    /// Pick a random different video at every advance.
    case shuffle
}

/// The player's sibling-video queue: a snapshot of the browser's video
/// items at open time plus the current position. Pure value type so the
/// advance/clamp rules are unit-testable without AppKit or mpv.
struct PlayerPlaylist: Sendable {
    let items: [ContentItem]
    private(set) var currentIndex: Int

    /// Positions the queue on `selectedPath`; an unknown path falls back to
    /// the first item so a stale snapshot can never crash the open.
    init(items: [ContentItem], selectedPath: String) {
        self.items = items
        currentIndex = items.firstIndex { $0.path == selectedPath } ?? 0
    }

    var current: ContentItem? {
        items.isEmpty ? nil : items[currentIndex]
    }

    var canGoPrevious: Bool { currentIndex > 0 }
    var canGoNext: Bool { currentIndex < items.count - 1 }

    /// Positions the queue at `index` (coordinator-driven jumps; the index
    /// math for steps/auto-advance stays in the mode functions below).
    /// Out-of-range indices are ignored.
    mutating func setCurrentIndex(_ index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    /// Index the coordinator should move to when the current video ends
    /// cleanly, or nil when playback should just stay parked. `repeatOne`
    /// returns the current index (replay in place); `shuffle` never returns
    /// the current index while another video exists.
    func autoAdvanceIndex(mode: PlayMode) -> Int? {
        guard !items.isEmpty else { return nil }
        switch mode {
        case .single:
            return nil
        case .repeatOne:
            return currentIndex
        case .list:
            return canGoNext ? currentIndex + 1 : nil
        case .listLoop:
            return (currentIndex + 1) % items.count
        case .shuffle:
            return randomIndex(avoiding: currentIndex)
        }
    }

    /// Index for a manual prev/next step under `mode`, or nil when the step
    /// runs past the queue's edge and the mode does not wrap. Shuffle treats
    /// both directions as "jump to a random other video"; list-loop wraps
    /// past either edge.
    func stepIndex(delta: Int, mode: PlayMode) -> Int? {
        guard !items.isEmpty else { return nil }
        if mode == .shuffle, items.count > 1 {
            return randomIndex(avoiding: currentIndex)
        }
        let target = currentIndex + delta
        guard items.indices.contains(target) else {
            if mode == .listLoop {
                return (target + items.count) % items.count
            }
            return nil
        }
        return target
    }

    /// A random valid index that is not `excluding` (nil when the queue has
    /// no other entry).
    private func randomIndex(avoiding excluding: Int) -> Int? {
        guard items.count > 1 else { return nil }
        // Rejection sampling is fine at playlist sizes.
        while true {
            let candidate = Int.random(in: items.indices)
            if candidate != excluding { return candidate }
        }
    }
}
