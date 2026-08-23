import Foundation
import Synchronization
import TraceKit

/// Bridges mpv's synchronous `stream_cb` protocol onto Cove's async
/// ranged reads (`ContentSource.read(at:range:)`, surfaced by
/// `SMBSessionService.makeRangedFileReader()`).
///
/// Threading model (the core design constraint of this spike):
///
/// - mpv invokes the read/seek/size/close callbacks of a single stream
///   *serially* on its own demuxer thread. Nothing outside these comments
///   assumes more concurrency than that.
/// - `read_fn` runs on that mpv thread (NOT a Swift cooperative pool
///   thread): it parks the mpv thread on a `DispatchSemaphore` with a 30s
///   timeout while a `Task.detached` performs the async ranged read on the
///   global executor, writes the result into a `ResultBox` and signals.
/// - After the wait returns, the mpv thread itself memcpy's the box's
///   `Data` into mpv's buffer and returns the byte count. Timeout or read
///   failure returns -1, which mpv treats as a stream error.
///
/// Deadlock argument:
///
/// - The only thread ever blocked is mpv's own demuxer thread. The async
///   work is scheduled on Swift's global executor, which never depends on
///   that thread making progress.
/// - The `SMBSource` actor is only ever *awaited*, never blocked, so it
///   keeps serving other callers (browser, thumbnails) while mpv waits.
/// - The main thread only issues non-blocking mpv commands and receives
///   events via the wakeup callback; it never joins mpv's IO.
///
/// Buffer ownership:
///
/// - The detached `Task` writes only the `ResultBox`; it never touches
///   mpv's buffer. The memcpy happens on the mpv thread after `wait`
///   returns, so a timeout or a concurrent close can never produce a
///   use-after-free. If the wait times out, the Task still holds the box
///   alive and simply writes a result nobody will read.
///
/// Known cost:
///
/// - Every `read(at:range:)` on `SMBSource` costs two SMB round trips
///   (stat + ranged read). If playback stutters on the NAS, tune mpv's
///   `cache` / `demuxer-readahead` options first; do not add caching in
///   this layer.
final class VideoStreamBridge {
    /// Async ranged read over the live SMB session; never touches the
    /// main actor (it snapshots the live source and hops straight onto
    /// the SMB actor).
    typealias RangedReader = @Sendable (_ path: String, _ range: Range<Int64>) async throws -> Data

    /// Custom URI scheme registered with mpv. The URI is only a label —
    /// the bridge already knows the single path it serves — but it must
    /// round-trip through mpv's protocol dispatch, so the path travels
    /// percent-encoded in the URI.
    static let scheme = "covesmb"

    /// Hard cap on one mpv read. On timeout the read returns -1 and mpv
    /// retries/fails the stream; nothing is left dangling.
    static let readTimeout: TimeInterval = 30

    /// Attempts per read before reporting a fatal stream error to mpv;
    /// see `StreamContext.read` for why transient failures are absorbed.
    static let maxReadAttempts = 3

    let path: String
    let size: Int64
    let reader: RangedReader

    /// Retained `Unmanaged` self passed to mpv as the `open_fn` user data.
    /// Released by `detach()` after the mpv handle is destroyed.
    private var registrationCookie: UnsafeMutableRawPointer?

    private let logger = TraceLogger(category: "VideoStream")

    /// Weak references to every stream context this bridge has handed to
    /// mpv, so teardown can wake their parked reads (see
    /// `cancelInFlightReads`). Entries nil themselves out as mpv closes
    /// streams; pruned lazily on each access.
    private let liveContexts = Mutex<[WeakContextBox]>([])

    init(path: String, size: Int64, reader: @escaping RangedReader) {
        self.path = path
        self.size = size
        self.reader = reader
    }

    /// The `covesmb://` URI to hand to mpv's `loadfile` for this stream.
    var uri: String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "\(Self.scheme)://\(encoded)"
    }

    /// Registers the custom protocol on an initialized mpv handle.
    /// The caller must keep this bridge alive until `detach()` is called
    /// after `mpv_terminate_destroy`.
    func register(handle: OpaquePointer) {
        let cookie = Unmanaged.passRetained(self).toOpaque()
        registrationCookie = cookie
        mpv_stream_cb_add_ro(handle, Self.scheme, cookie, coveStreamOpen)
    }

    /// Drops the registration retain. Call only after the mpv handle has
    /// been destroyed, so `open_fn` can never fire again.
    func detach() {
        guard let cookie = registrationCookie else { return }
        registrationCookie = nil
        Unmanaged<VideoStreamBridge>.fromOpaque(cookie).release()
    }

    /// `open_fn` body, called on an mpv thread. Zero IO: validates the
    /// scheme and installs the per-open stream state as the cookie.
    fileprivate func openStream(uri: String, info: UnsafeMutablePointer<mpv_stream_cb_info>) -> CInt {
        guard uri.hasPrefix("\(Self.scheme)://") else { return -1 }
        // Spike observability: an open with no follow-up reads means mpv
        // stalled before demuxing; reads with no app-side playback events
        // mean the stall is downstream (decode/render).
        logger.info("stream opened, size \(self.size)")
        let context = StreamContext(path: path, size: size, reader: reader)
        liveContexts.withLock { boxes in
            boxes.removeAll { $0.context == nil }
            boxes.append(WeakContextBox(context))
        }
        info.pointee.cookie = Unmanaged.passRetained(context).toOpaque()
        info.pointee.read_fn = coveStreamRead
        info.pointee.seek_fn = coveStreamSeek
        info.pointee.size_fn = coveStreamSize
        info.pointee.close_fn = coveStreamClose
        return 0
    }

    /// Wakes every parked read so mpv's demuxer thread unwinds
    /// immediately. Must be called *before* `mpv_terminate_destroy`: that
    /// call joins mpv's threads from the caller's thread, and a read parked
    /// on a stalled NAS would otherwise hold the join (and with it the main
    /// thread) for up to `readTimeout`.
    func cancelInFlightReads() {
        let contexts = liveContexts.withLock { boxes -> [StreamContext] in
            boxes.removeAll { $0.context == nil }
            return boxes.compactMap { $0.context }
        }
        for context in contexts {
            context.close()
        }
    }
}

/// Weak box so the bridge can reach live stream contexts without
/// extending their lifetime (mpv owns them via the cookie retain).
/// `@unchecked Sendable`: every access is serialized by the bridge's
/// `liveContexts` mutex, which the compiler cannot see.
private final class WeakContextBox: @unchecked Sendable {
    weak var context: StreamContext?

    init(_ context: StreamContext) {
        self.context = context
    }
}

/// Per-open stream state shared between mpv's serial callbacks.
/// All mutable state lives behind a `Mutex`; the callbacks never perform
/// IO under the lock (seek/size/close are pure state transitions).
/// Internal (not private) so CoveTests can drive the read mapping with a
/// fake `RangedReader` — no mpv handle required.
final class StreamContext: Sendable {
    private struct State {
        var position: Int64 = 0
        var closed = false
        /// Semaphore of the currently parked `read`, if any. `close` and
        /// `cancelInFlightReads` signal it so a read parked on a stalled
        /// NAS wakes immediately instead of riding out the 30s timeout —
        /// which is what bounds `mpv_terminate_destroy`'s join latency.
        var parkedRead: DispatchSemaphore?
        /// Completed reads, for sparse progress logging.
        var readCount = 0
    }

    let path: String
    let size: Int64
    let reader: VideoStreamBridge.RangedReader
    private let state = Mutex(State())
    /// Failure/slowness telemetry for the mpv thread; numbers only, no
    /// paths (this context serves exactly one file anyway).
    private let logger = TraceLogger(category: "VideoStream")

    init(path: String, size: Int64, reader: @escaping VideoStreamBridge.RangedReader) {
        self.path = path
        self.size = size
        self.reader = reader
    }

    /// Result slot for one in-flight read. `@unchecked Sendable` under a
    /// single-writer discipline: only the detached Task writes it, and the
    /// mpv thread reads it strictly after the semaphore signal (which
    /// creates the required happens-before edge).
    private final class ResultBox: @unchecked Sendable {
        var result: Result<Data, Error>?
    }

    /// Synchronous read serving mpv's demuxer thread. See the threading
    /// model comment on `VideoStreamBridge`.
    func read(into buffer: UnsafeMutablePointer<CChar>, maxCount: UInt64) -> Int64 {
        let range: Range<Int64>? = state.withLock { state in
            guard !state.closed, state.position < size else { return nil }
            let requested = Int64(clamping: maxCount)
            let end = min(state.position + requested, size)
            return state.position..<end
        }
        // Position at EOF or stream closed: EOF (0) for a clean end,
        // -1 only once closed mid-flight.
        guard let range else {
            return state.withLock { $0.closed ? -1 : 0 }
        }

        // Retry transient failures before reporting a stream error to mpv
        // (which -1 always is, and always fatal to playback). One bridge
        // read fans out to a dozen SMB round trips via the ranged reader
        // (open + fstat + ~1MiB chunks + close), so a long video exercises
        // the network thousands of times — without retries a single
        // transient error kills playback, which small files never run long
        // enough to hit.
        for attempt in 1...VideoStreamBridge.maxReadAttempts {
            if let data = attemptRead(range: range, attempt: attempt) {
                // The source may legally return fewer bytes than requested
                // (truncation at EOF); never write more than we asked for.
                let count = min(Int64(data.count), Int64(range.count))
                guard count > 0 else { return 0 }
                data.withUnsafeBytes { raw in
                    buffer.update(from: raw.bindMemory(to: CChar.self).baseAddress!, count: Int(count))
                }
                let (position, reads) = state.withLock { state -> (Int64, Int) in
                    state.position = range.lowerBound + count
                    state.readCount += 1
                    return (state.position, state.readCount)
                }
                // Spike observability: first read plus a low-frequency
                // heartbeat, so "reads flowing" is distinguishable from
                // "mpv never called us" in the logs.
                if reads == 1 || reads % 128 == 0 {
                    logger.info("read #\(reads): \(count) bytes at offset \(range.lowerBound) (position now \(position))")
                }
                return count
            }
            if state.withLock({ $0.closed }) {
                return -1
            }
        }
        return -1
    }

    /// One read attempt: parks the mpv thread on the semaphore and returns
    /// the fetched bytes on success, nil on timeout/error/close (all logged
    /// except the close wake, which is normal teardown).
    private func attemptRead(range: Range<Int64>, attempt: Int) -> Data? {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let reader = reader
        let path = path
        // The Task retains the reader (and transitively the session
        // router) but not this context's cookie; a close during the
        // flight just means the result is written into a box nobody reads.
        Task.detached {
            do {
                box.result = .success(try await reader(path, range))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        // Publish the semaphore so close/cancel can wake this wait early.
        state.withLock { $0.parkedRead = semaphore }
        defer { state.withLock { $0.parkedRead = nil } }

        let started = Date()
        guard semaphore.wait(timeout: .now() + VideoStreamBridge.readTimeout) == .success else {
            if !state.withLock({ $0.closed }) {
                logger.error("read timed out after \(VideoStreamBridge.readTimeout)s at offset \(range.lowerBound) count \(range.count) (attempt \(attempt))")
            }
            return nil
        }
        if state.withLock({ $0.closed }) {
            return nil
        }
        guard case .success(let data) = box.result else {
            if case .failure(let error) = box.result {
                logger.error("read failed at offset \(range.lowerBound) count \(range.count) (attempt \(attempt)): \(error.localizedDescription)", privacy: .private)
            }
            return nil
        }

        // A large-file stream reads in multi-MB chunks over several SMB
        // round trips; surface (never hide) when that gets slow enough to
        // starve playback, so NAS latency problems show up in TraceKit.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 5 {
            logger.error("slow read: \(range.count) bytes at offset \(range.lowerBound) took \(Int(elapsed))s")
        }
        return data
    }

    /// Absolute seek (mpv's stream seek is always SEEK_SET). Lock-protected
    /// state update only — no IO — so it can never stall the demuxer.
    func seek(to offset: Int64) -> Int64 {
        // Explicit Int64 annotation: as a discarded statement the closure
        // would otherwise infer Int from the -1 literal.
        let newPosition: Int64 = state.withLock { state in
            guard !state.closed else { return -1 }
            state.position = max(0, min(offset, size))
            return state.position
        }
        // Spike observability: moov-at-end MP4s show up here as a seek to
        // ~EOF right after open, before any demux reads.
        logger.info("seek to \(offset)")
        return newPosition
    }

    var fileSize: Int64 { size }

    /// Close is a state flip plus an early wake of a parked read: no join
    /// of the in-flight Task (it holds its own references and will write
    /// into an unread box), so mpv's thread returns immediately and
    /// teardown can never deadlock.
    func close() {
        state.withLock { state in
            state.closed = true
            state.parkedRead?.signal()
        }
    }
}

// MARK: - C entry points (non-capturing @convention(c); all state via cookie)

private func coveStreamOpen(
    userData: UnsafeMutableRawPointer?,
    uri: UnsafeMutablePointer<CChar>?,
    info: UnsafeMutablePointer<mpv_stream_cb_info>?
) -> CInt {
    guard let userData, let uri, let info else { return -1 }
    let bridge = Unmanaged<VideoStreamBridge>.fromOpaque(userData).takeUnretainedValue()
    return bridge.openStream(uri: String(cString: uri), info: info)
}

private func coveStreamRead(
    cookie: UnsafeMutableRawPointer?,
    buffer: UnsafeMutablePointer<CChar>?,
    nbytes: UInt64
) -> Int64 {
    guard let cookie, let buffer else { return -1 }
    let context = Unmanaged<StreamContext>.fromOpaque(cookie).takeUnretainedValue()
    return context.read(into: buffer, maxCount: nbytes)
}

private func coveStreamSeek(cookie: UnsafeMutableRawPointer?, offset: Int64) -> Int64 {
    guard let cookie else { return -1 }
    let context = Unmanaged<StreamContext>.fromOpaque(cookie).takeUnretainedValue()
    return context.seek(to: offset)
}

private func coveStreamSize(cookie: UnsafeMutableRawPointer?) -> Int64 {
    guard let cookie else { return -1 }
    let context = Unmanaged<StreamContext>.fromOpaque(cookie).takeUnretainedValue()
    return context.fileSize
}

private func coveStreamClose(cookie: UnsafeMutableRawPointer?) {
    guard let cookie else { return }
    let unmanaged = Unmanaged<StreamContext>.fromOpaque(cookie)
    unmanaged.takeUnretainedValue().close()
    // Balance the passRetained from open_fn — only after mpv promises
    // never to touch this cookie again.
    unmanaged.release()
}
