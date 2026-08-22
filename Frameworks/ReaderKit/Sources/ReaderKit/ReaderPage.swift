import Foundation

/// A page exposed by a Reader document. The identifier is stable for the
/// source and is not a presentation-layer index.
public struct ReaderPage: Sendable, Hashable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
