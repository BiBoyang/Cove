import AMSMB2
import Foundation

/// One share advertised by an SMB server.
public struct SMBShareInfo: Sendable, Hashable {
    /// Share name; can be passed to `SMBSource(host:share:...)`.
    public let name: String
    /// Server-provided remark; may be empty.
    public let comment: String

    public init(name: String, comment: String) {
        self.name = name
        self.comment = comment
    }

    /// Whether the share is worth showing in a browser UI: `IPC$` and the
    /// administrative shares (names ending in `$`) are noise there.
    public var isBrowsable: Bool {
        !name.hasSuffix("$")
    }

    /// Keeps only the browsable shares, preserving order.
    public static func browsable(_ shares: [SMBShareInfo]) -> [SMBShareInfo] {
        shares.filter(\.isBrowsable)
    }
}

/// Server-level SMB session: enumerates the shares of a server without
/// attaching to any of them.
///
/// Each `listShares()` call spins up a fresh `SMB2Manager`: AMSMB2's share
/// enumeration internally connects to `IPC$` and tears that connection down
/// when done, so there is no session worth keeping between calls. The type
/// itself only holds credentials and is therefore `Sendable`.
public struct SMBServer: Sendable {
    public let host: String
    public let username: String
    private let password: String

    public init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }

    /// Lists the server's browsable shares (name + comment).
    public func listShares() async throws -> [SMBShareInfo] {
        guard let url = URL(string: "smb://\(host)") else {
            throw SourceError.connectionFailed("invalid host: \(host)")
        }
        let credential = URLCredential(user: username, password: password, persistence: .none)
        guard let client = SMB2Manager(url: url, credential: credential) else {
            throw SourceError.connectionFailed("could not create SMB client for \(host)")
        }
        let shares: [(name: String, comment: String)]
        do {
            shares = try await client.listShares(enumerateHidden: false)
        } catch {
            throw SMBErrorMapper.connectError(error, host: host, resource: "IPC$")
        }
        // AMSMB2 already drops hidden shares via the MSRPC props when
        // `enumerateHidden` is false; the name-based filter below guards
        // servers that advertise `IPC$` or admin shares without the flag.
        return SMBShareInfo.browsable(shares.map { SMBShareInfo(name: $0.name, comment: $0.comment) })
    }
}
