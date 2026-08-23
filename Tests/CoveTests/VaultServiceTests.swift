import Foundation
import SourceKit
import Synchronization
import Testing
@testable import Cove

@Suite("Vault service")
@MainActor
struct VaultServiceTests {
    private let remoteMtime = Date(timeIntervalSince1970: 1_700_000_000)

    /// In-memory remote: full file paths mapped to bytes; directories are
    /// derived. Counts reads so skip-unchanged can be asserted.
    private final class FakeRemote: Sendable {
        struct Blob: Sendable {
            var bytes: Data
            var modified: Date
        }

        private let files = Mutex<[String: Blob]>([:])
        private let reads = Mutex(0)

        var readCount: Int { reads.withLock { $0 } }

        func setFile(_ path: String, bytes: Data, modified: Date) {
            files.withLock { $0[path] = Blob(bytes: bytes, modified: modified) }
        }

        func bytes(at path: String) -> Data? {
            files.withLock { $0[path]?.bytes }
        }

        /// Immediate children of `path`: file entries come from `files`,
        /// directory entries are implied by deeper paths.
        func list(at path: String) async throws -> [ContentItem] {
            let prefix = path == "/" ? "/" : path + "/"
            var children: [String: ContentItem] = [:]
            for (filePath, blob) in files.withLock({ $0 }) {
                guard filePath.hasPrefix(prefix) else { continue }
                let remainder = String(filePath.dropFirst(prefix.count))
                let components = remainder.split(separator: "/")
                guard let first = components.first else { continue }
                let name = String(first)
                if components.count > 1 {
                    children[name] = ContentItem(
                        name: name, path: prefix + name, isDirectory: true,
                        size: 0, modifiedDate: nil
                    )
                } else {
                    children[name] = ContentItem(
                        name: name, path: filePath, isDirectory: false,
                        size: Int64(blob.bytes.count), modifiedDate: blob.modified
                    )
                }
            }
            return Array(children.values)
        }

        func read(at path: String, range: Range<Int64>) async throws -> Data {
            reads.withLock { $0 += 1 }
            guard let blob = files.withLock({ $0[path] }) else {
                throw SourceError.pathNotFound(path)
            }
            // Honour the range like a real source: truncate to EOF.
            let bytes = blob.bytes
            let lower = min(Int(range.lowerBound), bytes.count)
            let upper = range.upperBound == Int64.max
                ? bytes.count
                : min(Int(range.upperBound), bytes.count)
            guard lower < upper else { return Data() }
            return Data(bytes[lower..<upper])
        }
    }

    private func makeVault() -> (VaultService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultServiceTests-\(UUID().uuidString)", isDirectory: true)
        return (VaultService(root: root), root)
    }

    @Test("a single file lands at <root>/<server>/<share>/<path> with the remote mtime")
    func singleFileDownload() async throws {
        let (service, root) = makeVault()
        let remote = FakeRemote()
        let bytes = Data("pdf-bytes".utf8)
        remote.setFile("/docs/a.pdf", bytes: bytes, modified: remoteMtime)
        let item = ContentItem(
            name: "a.pdf", path: "/docs/a.pdf", isDirectory: false,
            size: Int64(bytes.count), modifiedDate: remoteMtime
        )

        let result = try await service.download(
            item: item, serverLabel: "My NAS", share: "media",
            list: remote.list, read: remote.read
        )

        #expect(result.downloaded == 1)
        #expect(result.skipped == 0)
        let destination = root.appendingPathComponent("My NAS/media/docs/a.pdf")
        #expect(try Data(contentsOf: destination) == bytes)
        let values = try destination.resourceValues(forKeys: [.contentModificationDateKey])
        #expect(values.contentModificationDate == remoteMtime)
    }

    @Test("a directory downloads recursively across all file types")
    func directoryDownload() async throws {
        let (service, root) = makeVault()
        let remote = FakeRemote()
        remote.setFile("/comic/p1.jpg", bytes: Data("1".utf8), modified: remoteMtime)
        remote.setFile("/comic/sub/p2.png", bytes: Data("22".utf8), modified: remoteMtime)
        remote.setFile("/comic/notes.txt", bytes: Data("n".utf8), modified: remoteMtime)
        let item = ContentItem(
            name: "comic", path: "/comic", isDirectory: true, size: 0, modifiedDate: nil
        )

        let result = try await service.download(
            item: item, serverLabel: "nas", share: "s",
            list: remote.list, read: remote.read
        )

        #expect(result.downloaded == 3)
        #expect(!result.truncated)
        for relative in ["p1.jpg", "sub/p2.png", "notes.txt"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("nas/s/comic/\(relative)").path))
        }
    }

    @Test("unchanged files are skipped; a changed file is re-downloaded")
    func skipUnchanged() async throws {
        let (service, root) = makeVault()
        let remote = FakeRemote()
        remote.setFile("/a.txt", bytes: Data("old".utf8), modified: remoteMtime)
        remote.setFile("/b.txt", bytes: Data("bee".utf8), modified: remoteMtime)
        let dirItem = ContentItem(name: "/", path: "/", isDirectory: true, size: 0, modifiedDate: nil)

        let first = try await service.download(
            item: dirItem, serverLabel: "nas", share: "s",
            list: remote.list, read: remote.read
        )
        #expect(first.downloaded == 2)
        #expect(remote.readCount == 2)

        let second = try await service.download(
            item: dirItem, serverLabel: "nas", share: "s",
            list: remote.list, read: remote.read
        )
        #expect(second.skipped == 2)
        #expect(remote.readCount == 2)

        // b.txt changes on the NAS: new bytes and a newer mtime.
        let newerMtime = remoteMtime.addingTimeInterval(60)
        remote.setFile("/b.txt", bytes: Data("BEE!".utf8), modified: newerMtime)
        let third = try await service.download(
            item: dirItem, serverLabel: "nas", share: "s",
            list: remote.list, read: remote.read
        )
        #expect(third.downloaded == 1)
        #expect(third.skipped == 1)
        #expect(remote.readCount == 3)
        let updated = try Data(contentsOf: root.appendingPathComponent("nas/s/b.txt"))
        #expect(updated == Data("BEE!".utf8))
    }

    @Test("downloads stream in chunks and reassemble byte-exact across chunk boundaries")
    func chunkedDownload() async throws {
        let (service, root) = makeVault()
        let remote = FakeRemote()
        // One byte past a whole chunk, so the loop sees exactly one full
        // read plus one short read.
        let length = Int(VaultService.downloadChunkSize) + 123
        let bytes = Data((0..<length).map { UInt8($0 % 251) })
        remote.setFile("/movie.mkv", bytes: bytes, modified: remoteMtime)
        let item = ContentItem(
            name: "movie.mkv", path: "/movie.mkv", isDirectory: false,
            size: Int64(bytes.count), modifiedDate: remoteMtime
        )

        let result = try await service.download(
            item: item, serverLabel: "nas", share: "s",
            list: remote.list, read: remote.read
        )

        #expect(result.downloaded == 1)
        #expect(remote.readCount == 2)
        let written = try Data(contentsOf: root.appendingPathComponent("nas/s/movie.mkv"))
        #expect(written == bytes)
    }

    @Test("a failed read leaves no partial or temp file behind")
    func failureLeavesNoPartialFile() async throws {
        let (service, root) = makeVault()
        let remote = FakeRemote()
        let item = ContentItem(
            name: "a.txt", path: "/a.txt", isDirectory: false,
            size: 3, modifiedDate: remoteMtime
        )

        let result = try await service.download(
            item: item, serverLabel: "nas", share: "s",
            list: remote.list,
            read: { path, _ in throw SourceError.operationFailed("boom \(path)") }
        )

        #expect(result.failedPaths == ["/a.txt"])
        // The destination directory tree was created, but neither the
        // destination nor any leftover temp file exists.
        let allEntries = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        #expect(allEntries.allSatisfy { !$0.contains(".cove-tmp-") })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("nas/s/a.txt").path))
    }

    @Test("cancelling mid-run stops the download and keeps completed files")
    func cancellation() async throws {
        let (service, root) = makeVault()
        let remote = FakeRemote()
        remote.setFile("/f1.bin", bytes: Data("1".utf8), modified: remoteMtime)
        remote.setFile("/f2.bin", bytes: Data("2".utf8), modified: remoteMtime)
        let item = ContentItem(name: "/", path: "/", isDirectory: true, size: 0, modifiedDate: nil)

        let task = Task {
            try await service.download(
                item: item, serverLabel: "nas", share: "s",
                list: remote.list,
                read: { path, range in
                    // Mimic a source that honours cancellation mid-run.
                    try Task.checkCancellation()
                    return try await remote.read(at: path, range: range)
                }
            )
        }
        // Cancel once the first file has completed.
        while remote.readCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        do {
            _ = try await task.value
            // A cancel landing after the last check is a valid clean run;
            // what matters is that no partial state exists either way.
        } catch {
            #expect(error is CancellationError)
        }

        let allEntries = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        #expect(allEntries.allSatisfy { !$0.contains(".cove-tmp-") })
        // f1 (already read) is fully intact if it was written.
        let f1 = root.appendingPathComponent("nas/s/f1.bin")
        if FileManager.default.fileExists(atPath: f1.path) {
            #expect(try Data(contentsOf: f1) == Data("1".utf8))
        }
    }

    @Test("delete removes only the local copy")
    func deleteLocalOnly() async throws {
        let (service, root) = makeVault()
        let remote = FakeRemote()
        let bytes = Data("keep-me-on-nas".utf8)
        remote.setFile("/a.txt", bytes: bytes, modified: remoteMtime)
        let item = ContentItem(
            name: "a.txt", path: "/a.txt", isDirectory: false,
            size: Int64(bytes.count), modifiedDate: remoteMtime
        )
        _ = try await service.download(
            item: item, serverLabel: "nas", share: "s",
            list: remote.list, read: remote.read
        )
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("nas/s/a.txt").path))

        try service.delete(vaultRelativePath: "/nas/s/a.txt")

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("nas/s/a.txt").path))
        // The remote side is untouched (it never even saw the delete).
        #expect(remote.bytes(at: "/a.txt") == bytes)
    }

    @Test("delete refuses paths escaping the vault root")
    func deleteEscapeRefused() async throws {
        let (service, _) = makeVault()
        #expect(throws: SourceError.self) {
            try service.delete(vaultRelativePath: "/../outside")
        }
    }

    @Test("server labels are sanitized for the filesystem")
    func sanitize() {
        #expect(VaultService.sanitize("My NAS") == "My NAS")
        #expect(VaultService.sanitize("a/b:c") == "a-b-c")
        #expect(VaultService.sanitize("  ") == "unknown")
    }
}
