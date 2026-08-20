import Foundation
import SourceKit

/// smb-spike: SMB connectivity probe.
///
/// Usage: smb-spike <host> <share> <user> <password> <path>
///
/// Connects to the share, lists the directory at <path> (name + size per
/// entry), then reads the first 64 KB of the first file and reports the
/// elapsed time and throughput.
@main
struct SMBSpike {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 6 else {
            FileHandle.standardError.write(Data("Usage: smb-spike <host> <share> <user> <password> <path>\n".utf8))
            exit(2)
        }
        let (host, share, user, password, path) = (args[1], args[2], args[3], args[4], args[5])

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
            let data = try await source.readRange(at: first.path, maxLength: probeLength)
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
}
