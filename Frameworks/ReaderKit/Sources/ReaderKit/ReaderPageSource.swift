import Foundation

/// Supplies the original bytes for the pages in a Reader document.
///
/// Concrete adapters (directory files, CBZ entries, and future sources) stay
/// outside ReaderKit. ReaderKit therefore has no knowledge of SMB, ZIP,
/// caching, or AppKit.
public protocol ReaderPageSource: Sendable {
    var document: ReaderDocument { get }

    func loadOriginalData(at index: Int) async throws -> Data
}
