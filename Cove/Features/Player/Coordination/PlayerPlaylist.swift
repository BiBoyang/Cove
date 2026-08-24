import SourceKit

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

    /// Moves to the next video; returns false (and changes nothing) at the
    /// end of the queue.
    @discardableResult
    mutating func advance() -> Bool {
        guard canGoNext else { return false }
        currentIndex += 1
        return true
    }

    /// Moves to the previous video; returns false at the queue start.
    @discardableResult
    mutating func back() -> Bool {
        guard canGoPrevious else { return false }
        currentIndex -= 1
        return true
    }
}
