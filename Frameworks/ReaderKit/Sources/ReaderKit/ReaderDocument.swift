import Foundation

/// Ordered pages that a Reader session can present.
public struct ReaderDocument: Sendable, Hashable {
    public let pages: [ReaderPage]

    public init(pages: [ReaderPage]) {
        self.pages = pages
    }
}
