import Foundation
import SourceKit

/// smb-spike: SMB connectivity probe.
///
/// Usage:
///   smb-spike <host> <share> <user> <password> <path>
///     Connects to the share, lists the directory at <path> (name + size per
///     entry), then reads the first 64 KB of the first file and reports the
///     elapsed time and throughput.
///   smb-spike <host> <share> <user> <password> --read <file> [capMB]
///     Streams the file in 1 MB chunks (up to capMB, default 256) and reports
///     per-chunk latency plus overall throughput.
///   smb-spike <host> - <user> <password> --shares
///     Enumerates the server's browsable shares (name + comment). The share
///     argument is ignored in this mode; pass a placeholder such as `-`.
@main
struct SMBSpike {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 6 else {
            FileHandle.standardError.write(Data("""
            Usage: smb-spike <host> <share> <user> <password> <path>
                   smb-spike <host> <share> <user> <password> --read <file> [capMB]
                   smb-spike <host> - <user> <password> --shares

            """.utf8))
            exit(2)
        }
        let (host, share, user, password) = (args[1], args[2], args[3], args[4])

        if args[5] == "--shares" {
            await sharesProbe(host: host, user: user, password: password)
            return
        }

        if args[5] == "--read" {
            guard args.count >= 7 else {
                FileHandle.standardError.write(Data("Usage: smb-spike <host> <share> <user> <password> --read <file> [capMB]\n".utf8))
                exit(2)
            }
            let capMB = args.count >= 8 ? Int64(args[7]) ?? 256 : 256
            await readProbe(host: host, share: share, user: user, password: password,
                            file: args[6], capBytes: capMB * 1024 * 1024)
            return
        }

        let path = args[5]

        let source = SMBSource(host: host, share: share, username: user, password: password)
        do {
            print("Connecting to smb://\(host)/\(share) as \(user)...")
            try await source.connect()
            print("Connected. Listing \(path):")

            let items = try await source.list(at: path)
            for item in items {
                let kind = item.isDirectory ? "d" : "-"
                let size = item.isDirectory ? "<dir>" : String(item.size)
                print("  \(kind) \(size)\t\(item.name)")
            }

            guard let first = items.first(where: { !$0.isDirectory }) else {
                print("No regular file in \(path); skipping read probe.")
                await source.disconnect()
                return
            }

            let probeLength = 64 * 1024
            let clock = ContinuousClock()
            let start = clock.now
            let data = try await source.read(at: first.path, range: 0..<Int64(probeLength))
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let throughput = seconds > 0 ? Double(data.count) / seconds : 0
            print(String(
                format: "Read %d bytes from %@ in %.3fs (%.1f KB/s)",
                data.count, first.path, seconds, throughput / 1024
            ))

            await source.disconnect()
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Enumerates the server's browsable shares and prints name + comment.
    private static func sharesProbe(host: String, user: String, password: String) async {
        let server = SMBServer(host: host, username: user, password: password)
        do {
            print("Enumerating shares on smb://\(host) as \(user)...")
            let shares = try await server.listShares()
            guard !shares.isEmpty else {
                print("No browsable shares.")
                return
            }
            for share in shares {
                print("  \(share.name)\t\(share.comment)")
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Streams `file` in 1 MB chunks and reports chunk latency + throughput.
    private static func readProbe(host: String, share: String, user: String, password: String,
                                  file: String, capBytes: Int64) async {
        let source = SMBSource(host: host, share: share, username: user, password: password)
        do {
            print("Connecting to smb://\(host)/\(share) as \(user)...")
            let connectStart = ContinuousClock.now
            try await source.connect()
            let connectElapsed = ContinuousClock.now - connectStart
            print(String(format: "Connected in %.3fs. Reading %@ (cap %lld MB)...",
                         Self.seconds(connectElapsed), file, capBytes / 1024 / 1024))

            let chunkSize = 1024 * 1024
            var offset: Int64 = 0
            var totalRead: Int64 = 0
            let totalStart = ContinuousClock.now

            while totalRead < capBytes {
                let remaining = capBytes - totalRead
                let length = min(Int64(chunkSize), remaining)
                let chunkStart = ContinuousClock.now
                let data = try await source.read(at: file, range: offset..<(offset + length))
                let chunkElapsed = ContinuousClock.now - chunkStart
                guard !data.isEmpty else { break }
                totalRead += Int64(data.count)
                offset += Int64(data.count)
                print(String(format: "  chunk @%lld: %d bytes in %.3fs (%.1f MB/s)",
                             offset - Int64(data.count), data.count,
                             Self.seconds(chunkElapsed),
                             Double(data.count) / Self.seconds(chunkElapsed) / 1024 / 1024))
                if Int64(data.count) < length { break }  // EOF
            }

            let totalSeconds = Self.seconds(ContinuousClock.now - totalStart)
            print(String(format: "Total: %lld bytes in %.3fs (%.2f MB/s)",
                         totalRead, totalSeconds,
                         totalSeconds > 0 ? Double(totalRead) / totalSeconds / 1024 / 1024 : 0))
            await source.disconnect()
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
