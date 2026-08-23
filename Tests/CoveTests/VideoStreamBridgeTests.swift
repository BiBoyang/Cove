import Foundation
import Synchronization
import Testing
@testable import Cove

/// Drives `StreamContext`'s read mapping directly with fake ranged readers
/// — no mpv handle involved. The fake readers answer immediately, so the
/// 30s read timeout never comes into play here.
@Suite("Video stream bridge read mapping")
struct VideoStreamBridgeTests {
    /// Records the ranges a fake reader was asked for.
    private final class RangeRecorder: @unchecked Sendable {
        private(set) var ranges: [Range<Int64>] = []
        func record(_ range: Range<Int64>) { ranges.append(range) }
    }

    private final class Int64Box: @unchecked Sendable {
        var value: Int64?
    }

    /// Synchronous read against a fresh buffer; returns the byte count mpv
    /// would get plus the bytes that were copied into its buffer.
    private func read(_ context: StreamContext, maxCount: UInt64) -> (result: Int64, bytes: [UInt8]) {
        let capacity = Int(maxCount)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: max(1, capacity))
        defer { buffer.deallocate() }
        let result = context.read(into: buffer, maxCount: maxCount)
        var bytes: [UInt8] = []
        if result > 0 {
            bytes = UnsafeRawBufferPointer(start: buffer, count: Int(result)).map { $0 }
        }
        return (result, bytes)
    }

    @Test("reads map the position to ranges and advance it")
    func readsAdvancePosition() {
        let recorder = RangeRecorder()
        let context = StreamContext(path: "/v.mp4", size: 100) { _, range in
            recorder.record(range)
            return Data(repeating: 0xAB, count: Int(range.count))
        }

        let first = read(context, maxCount: 10)
        let second = read(context, maxCount: 10)

        #expect(first.result == 10)
        #expect(first.bytes == [UInt8](repeating: 0xAB, count: 10))
        #expect(second.result == 10)
        #expect(recorder.ranges == [0..<10, 10..<20])
    }

    @Test("reads clamp at EOF and then report a clean end")
    func eofClamping() {
        let recorder = RangeRecorder()
        let context = StreamContext(path: "/v.mp4", size: 100) { _, range in
            recorder.record(range)
            return Data(repeating: 0x00, count: Int(range.count))
        }
        #expect(context.seek(to: 95) == 95)

        let clipped = read(context, maxCount: 10)
        #expect(clipped.result == 5)
        #expect(recorder.ranges == [95..<100])

        let atEnd = read(context, maxCount: 10)
        #expect(atEnd.result == 0)
    }

    @Test("a short read passes through and advances by the delivered count")
    func shortRead() {
        let recorder = RangeRecorder()
        let delivered = Mutex(3)
        let context = StreamContext(path: "/v.mp4", size: 100) { _, range in
            recorder.record(range)
            let count = min(delivered.withLock { $0 }, Int(range.count))
            return Data(repeating: 0x01, count: count)
        }

        let first = read(context, maxCount: 10)
        #expect(first.result == 3)

        // The position advanced by 3, not by the requested 10.
        delivered.withLock { $0 = 10 }
        let second = read(context, maxCount: 10)
        #expect(second.result == 10)
        #expect(recorder.ranges == [0..<10, 3..<13])
    }

    @Test("transient failures are retried before the read succeeds")
    func retriesTransientFailure() {
        let attempts = Mutex(0)
        let context = StreamContext(path: "/v.mp4", size: 100) { _, range in
            let attempt = attempts.withLock { value -> Int in
                value += 1
                return value
            }
            if attempt == 1 { throw NSError(domain: "test", code: 1) }
            return Data(repeating: 0x02, count: Int(range.count))
        }

        let result = read(context, maxCount: 8)
        #expect(result.result == 8)
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test("a persistent failure gives up after three attempts with -1")
    func persistentFailure() {
        let attempts = Mutex(0)
        let context = StreamContext(path: "/v.mp4", size: 100) { _, _ in
            attempts.withLock { $0 += 1 }
            throw NSError(domain: "test", code: 2)
        }

        let result = read(context, maxCount: 8)
        #expect(result.result == -1)
        #expect(attempts.withLock { $0 } == VideoStreamBridge.maxReadAttempts)
    }

    @Test("close wakes a parked read, which then fails the stream")
    func closeWakesParkedRead() {
        let gate = DispatchSemaphore(value: 0)
        let context = StreamContext(path: "/v.mkv", size: 100) { _, _ in
            gate.wait()
            return Data(count: 4)
        }
        let result = Int64Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 16)
            defer { buffer.deallocate() }
            result.value = context.read(into: buffer, maxCount: 16)
            done.signal()
        }

        // Let the read park on the bridge semaphore, then close.
        Thread.sleep(forTimeInterval: 0.2)
        context.close()

        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(result.value == -1)
        // Release the detached reader task so nothing outlives the test.
        gate.signal()
    }

    @Test("a read issued after close fails immediately")
    func readAfterClose() {
        let context = StreamContext(path: "/v.mp4", size: 100) { _, range in
            Data(count: Int(range.count))
        }
        context.close()
        #expect(read(context, maxCount: 8).result == -1)
    }

    @Test("seek clamps to file bounds and fails once closed")
    func seekClamping() {
        let context = StreamContext(path: "/v.mp4", size: 100) { _, range in
            Data(count: Int(range.count))
        }
        #expect(context.seek(to: -5) == 0)
        #expect(context.seek(to: 200) == 100)
        #expect(context.seek(to: 50) == 50)
        context.close()
        #expect(context.seek(to: 10) == -1)
    }
}
