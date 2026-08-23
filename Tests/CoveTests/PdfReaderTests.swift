import Foundation
import PDFKit
import SourceKit
import Synchronization
import Testing
@testable import Cove

@Suite("PDF reader")
@MainActor
struct PdfReaderViewModelTests {
    private func makeItem(byteCount: Int) -> ContentItem {
        ContentItem(
            name: "doc.pdf", path: "/doc.pdf", isDirectory: false,
            size: Int64(byteCount), modifiedDate: nil
        )
    }

    @Test("loading transitions to ready when the bytes build a document")
    func loadSuccess() async {
        let bytes = makeTestPDFData()
        let viewModel = PdfReaderViewModel(title: "doc.pdf") { bytes }

        #expect(viewModel.isLoading)
        viewModel.start()
        await viewModel.waitForLoad()

        guard case .ready(let document) = viewModel.state else {
            Issue.record("expected ready, got \(viewModel.state)")
            return
        }
        #expect(document.pageCount == 1)
    }

    @Test("a provider error lands in failed and reports .load")
    func loadFailure() async {
        struct TestError: Error {}
        let viewModel = PdfReaderViewModel(title: "doc.pdf") { throw TestError() }
        var reported: PdfReaderViewModel.Failure?
        viewModel.onFailure = { reported = $0 }

        viewModel.start()
        await viewModel.waitForLoad()

        guard case .failed = viewModel.state else {
            Issue.record("expected failed, got \(viewModel.state)")
            return
        }
        guard case .load = reported else {
            Issue.record("expected .load failure")
            return
        }
    }

    @Test("bytes that are not a PDF land in failed and report .invalidDocument")
    func invalidDocument() async {
        let viewModel = PdfReaderViewModel(title: "doc.pdf") { Data("not a pdf".utf8) }
        var reported: PdfReaderViewModel.Failure?
        viewModel.onFailure = { reported = $0 }

        viewModel.start()
        await viewModel.waitForLoad()

        guard case .failed = viewModel.state else {
            Issue.record("expected failed, got \(viewModel.state)")
            return
        }
        guard case .invalidDocument = reported else {
            Issue.record("expected .invalidDocument failure")
            return
        }
    }

    @Test("a second open hits the original pool without downloading again")
    func cacheHitSkipsDownload() async {
        let cache = makeTestCache()
        let bytes = makeTestPDFData()
        let item = makeItem(byteCount: bytes.count)
        let reads = Mutex(0)
        let fileReader: @Sendable (String) async throws -> Data = { _ in
            reads.withLock { $0 += 1 }
            return bytes
        }

        // Two independent opens (fresh view models) over the same cache and
        // counting reader — the second must be served from the original
        // pool written by the first.
        for _ in 0..<2 {
            let viewModel = PdfReaderViewModel(title: item.name) {
                try await ReaderContent.originalBytes(
                    for: item, fileReader: fileReader, cache: cache, sourceID: "s"
                )
            }
            viewModel.start()
            await viewModel.waitForLoad()
            guard case .ready = viewModel.state else {
                Issue.record("expected ready, got \(viewModel.state)")
                return
            }
        }

        #expect(reads.withLock { $0 } == 1)
    }
}

/// Valid one-page PDF bytes, produced by PDFKit itself so the fixture can
/// never drift from what `PDFDocument(data:)` accepts.
private func makeTestPDFData() -> Data {
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    guard let data = document.dataRepresentation() else {
        fatalError("PDFKit failed to serialize an empty one-page document")
    }
    return data
}
