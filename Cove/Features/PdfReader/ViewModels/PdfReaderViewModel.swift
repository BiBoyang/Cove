import Foundation
import PDFKit

/// Loading state machine for the PDF reader window.
///
/// The window opens in `loading` while the whole document is obtained
/// (an original-pool cache hit returns instantly), then either presents the
/// built `PDFDocument` or shows the failure message. Cancellation on window
/// close is handled here; the controller only renders state.
@MainActor
final class PdfReaderViewModel {
    enum State {
        case loading
        case ready(PDFDocument)
        case failed(String)
    }

    /// Terminal failure, forwarded by the coordinator to the shared error
    /// pipeline in addition to the in-window message.
    enum Failure {
        /// The byte provider threw (download / cache read failure).
        case load(Error)
        /// Bytes arrived but `PDFDocument(data:)` rejected them.
        case invalidDocument
    }

    let title: String
    private let bytesProvider: @Sendable () async throws -> Data

    private(set) var state: State = .loading
    var onStateChange: ((State) -> Void)?
    var onFailure: ((Failure) -> Void)?

    private var loadTask: Task<Void, Never>?
    private var isTornDown = false

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    init(title: String, bytesProvider: @escaping @Sendable () async throws -> Data) {
        self.title = title
        self.bytesProvider = bytesProvider
    }

    func start() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await bytesProvider()
                try Task.checkCancellation()
                guard let document = PDFDocument(data: data) else {
                    fail("文件损坏或不是有效的 PDF。", failure: .invalidDocument)
                    return
                }
                transition(to: .ready(document))
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                fail("PDF 加载失败，请关闭后重试。", failure: .load(error))
            }
        }
    }

    /// Test seam: awaits the in-flight load so state assertions are
    /// deterministic without polling.
    func waitForLoad() async {
        await loadTask?.value
    }

    func tearDown() {
        isTornDown = true
        loadTask?.cancel()
        loadTask = nil
    }

    private func transition(to newState: State) {
        guard !isTornDown else { return }
        state = newState
        onStateChange?(newState)
    }

    private func fail(_ message: String, failure: Failure) {
        transition(to: .failed(message))
        guard !isTornDown else { return }
        onFailure?(failure)
    }
}
