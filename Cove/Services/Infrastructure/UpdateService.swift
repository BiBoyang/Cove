import Foundation

/// Running-build version strings read from the bundle. MARKETING_VERSION
/// and CURRENT_PROJECT_VERSION are injected at build time (release CI
/// overrides them on the command line), so reading the built bundle is
/// always correct — no source constants to keep in sync.
enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}

/// Fault-tolerant three-segment version parsed from a release tag.
///
/// Tolerances (GitHub tags are free-form): an optional `v`/`V` prefix, a
/// leading-digit prefix per segment (`"3-beta"` → 3), missing trailing
/// segments (`"1.2"` → 1.2.0), and segments beyond the third are ignored.
/// Parsing fails only when no segment contains any digit (`"latest"`,
/// `""`); callers treat that as a check failure, never a crash.
struct SemanticVersion: Equatable, Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ raw: String) {
        var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let segments = text.split(separator: ".", omittingEmptySubsequences: false).prefix(3)
        var numbers: [Int] = []
        for segment in segments {
            let digits = segment.prefix { $0.isNumber && $0.isASCII }
            // Absurdly long digit runs (19+) overflow Int — clamp instead
            // of trapping, so no tag can ever crash the check.
            numbers.append(digits.isEmpty ? 0 : (Int(digits) ?? .max))
        }
        // A tag with no digit anywhere ("latest", "v", "") is not a version.
        guard text.contains(where: { $0.isNumber && $0.isASCII }) else { return nil }
        while numbers.count < 3 { numbers.append(0) }
        self.major = numbers[0]
        self.minor = numbers[1]
        self.patch = numbers[2]
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }
}

/// The subset of the GitHub `/releases/latest` payload the checker uses.
/// The endpoint only returns the latest stable release (never a draft or
/// prerelease), which is exactly the channel this app ships.
struct LatestRelease: Codable, Equatable, Sendable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// What the update check succeeded with: everything the three-state alert
/// and the release-page jump need.
struct UpdateCheckResult: Equatable, Sendable {
    /// Parsed version of the latest tag (compare-ready).
    let version: SemanticVersion
    /// Raw tag as published (display-ready, e.g. "v1.0.0").
    let tag: String
    /// Release page URL, opened by the alert's 前往下载 button.
    let pageURL: URL
}

enum UpdateCheckError: Error {
    /// Non-2xx API response (rate limit and offline proxies land here).
    case httpStatus(Int)
    /// The payload decoded but its tag is not a version.
    case unparseableTag(String)
    /// The payload decoded but its html_url is not a URL.
    case unparseableURL(String)
}

/// Manual-only update check against GitHub Releases (decision: no
/// background polling in 1.0). All network details — the endpoint, the
/// Accept/User-Agent headers (GitHub's API rejects UA-less clients with
/// 403) — stay in here; callers only see data or an error, so the
/// coordinator's alert flow never touches the network itself.
struct UpdateService: Sendable {
    /// Public, no auth, no user data in the request.
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/BiBoyang/Cove/releases/latest"
    )!

    private let fetcher: @Sendable () async throws -> Data

    init() {
        fetcher = {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.timeoutInterval = 15
            request.setValue("Cove/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateCheckError.httpStatus(http.statusCode)
            }
            return data
        }
    }

    /// Test seam: the injected fetcher replaces the network, so unit
    /// tests exercise parsing/comparison with zero real requests.
    init(fetcher: @escaping @Sendable () async throws -> Data) {
        self.fetcher = fetcher
    }

    /// Fetches and decodes the latest release into a compare-ready result.
    func latestRelease() async throws -> UpdateCheckResult {
        let data = try await fetcher()
        let release = try JSONDecoder().decode(LatestRelease.self, from: data)
        guard let version = SemanticVersion(release.tagName) else {
            throw UpdateCheckError.unparseableTag(release.tagName)
        }
        guard let pageURL = URL(string: release.htmlURL) else {
            throw UpdateCheckError.unparseableURL(release.htmlURL)
        }
        return UpdateCheckResult(version: version, tag: release.tagName, pageURL: pageURL)
    }
}
