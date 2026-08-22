import Foundation
import SourceKit

/// Presentation state for the directory browser.
@MainActor
final class BrowserViewModel {
    struct State: Sendable {
        let items: [ContentItem]
        let path: String
        let title: String
        let canGoUp: Bool
    }

    private(set) var state = State(items: [], path: "", title: "", canGoUp: false)

    var onStateChange: ((State) -> Void)? {
        didSet { onStateChange?(state) }
    }

    var imageItems: [ContentItem] {
        state.items.filter { $0.fileType == .image }
    }

    func item(atPath path: String) -> ContentItem? {
        state.items.first { $0.path == path }
    }

    func display(items: [ContentItem], path: String, title: String) {
        state = State(
            items: Self.visibleItems(from: items),
            path: path,
            title: title,
            canGoUp: true
        )
        onStateChange?(state)
    }

    static func visibleItems(from items: [ContentItem]) -> [ContentItem] {
        items
            .filter { !$0.isMacOSNoise }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
