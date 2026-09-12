import Foundation
import Testing
@testable import Cove

/// Update-check pure trio: version parsing/comparison, release JSON
/// decoding, and the fetcher-injected service seam. No test touches the
/// network — every payload arrives through the injected fetcher.
@Suite("Update check")
struct UpdateServiceTests {

    // MARK: - SemanticVersion

    @Test("v-prefix tolerance: v1.2.3, V1.2.3 and 1.2.3 parse equal")
    func vPrefixTolerance() {
        let plain = SemanticVersion("1.2.3")
        #expect(plain != nil)
        #expect(SemanticVersion("v1.2.3") == plain)
        #expect(SemanticVersion("V1.2.3") == plain)
    }

    @Test("equal strings compare equal")
    func equality() {
        #expect(SemanticVersion("0.7.0") == SemanticVersion("v0.7.0"))
        #expect(SemanticVersion("0.7.0") == SemanticVersion(major: 0, minor: 7, patch: 0))
    }

    @Test("older/newer across each segment, numerically not lexicographically")
    func ordering() {
        let base = SemanticVersion("v0.7.0")!
        #expect(base < SemanticVersion("v0.7.1")!)
        #expect(base < SemanticVersion("v0.8.0")!)
        #expect(base < SemanticVersion("v1.0.0")!)
        // 10 > 9 numerically; a lexicographic string compare would flip it.
        #expect(SemanticVersion("v0.7.0")! < SemanticVersion("v0.10.0")!)
        #expect(SemanticVersion("v0.6.9")! < base)
        #expect(!(base < SemanticVersion("0.7.0")!))
    }

    @Test("missing trailing segments default to zero")
    func missingSegments() {
        #expect(SemanticVersion("1.2") == SemanticVersion("1.2.0"))
        #expect(SemanticVersion("v2") == SemanticVersion("2.0.0"))
    }

    @Test("non-numeric segments tolerate to numeric prefix or zero")
    func nonNumericSegments() {
        #expect(SemanticVersion("v1.0.0-beta") == SemanticVersion("1.0.0"))
        #expect(SemanticVersion("1.2.x") == SemanticVersion("1.2.0"))
        #expect(SemanticVersion("2026.09.12-release") == SemanticVersion("2026.9.12"))
    }

    @Test("oversized digit segments clamp to Int.max instead of trapping")
    func oversizedSegments() {
        let huge = SemanticVersion("v99999999999999999999999.0.0")
        #expect(huge != nil)
        #expect(huge! > SemanticVersion("0.7.0")!)
    }

    @Test("abnormal strings fail to parse")
    func abnormalStrings() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("   ") == nil)
        #expect(SemanticVersion("v") == nil)
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("not.a.version") == nil)
    }

    @Test("comparison outcomes: newer / equal / older against a running version")
    func comparisonOutcomes() {
        let running = SemanticVersion("0.7.0")!
        #expect(SemanticVersion("v0.8.0")! > running)
        #expect(SemanticVersion("v0.7.0")! == running)
        #expect(SemanticVersion("v0.6.9")! < running)
    }

    // MARK: - LatestRelease decoding via the injected fetcher

    private func makeService(returning payload: String) -> UpdateService {
        let data = Data(payload.utf8)
        return UpdateService(fetcher: { data })
    }

    @Test("decodes a full release payload into a compare-ready result")
    func decodeSuccess() async throws {
        let service = makeService(returning: """
            {"tag_name": "v0.8.0", "html_url": "https://github.com/BiBoyang/Cove/releases/tag/v0.8.0", \
            "draft": false, "prerelease": false, "name": "Cove 0.8.0", "target_commitish": "main"}
            """)
        let result = try await service.latestRelease()
        #expect(result.version == SemanticVersion("0.8.0"))
        #expect(result.tag == "v0.8.0")
        #expect(result.pageURL.absoluteString == "https://github.com/BiBoyang/Cove/releases/tag/v0.8.0")
    }

    @Test("missing tag_name or html_url fails decoding")
    func decodeMissingFields() async {
        let missingURL = makeService(returning: #"{"tag_name": "v0.8.0"}"#)
        await #expect(throws: DecodingError.self) { try await missingURL.latestRelease() }
        let missingTag = makeService(returning: #"{"html_url": "https://example.com"}"#)
        await #expect(throws: DecodingError.self) { try await missingTag.latestRelease() }
    }

    @Test("non-JSON payload fails decoding")
    func decodeBadData() async {
        let service = makeService(returning: "<html>404</html>")
        await #expect(throws: DecodingError.self) { try await service.latestRelease() }
    }

    @Test("a payload whose tag is not a version throws unparseableTag")
    func unparseableTag() async {
        let service = makeService(returning: #"{"tag_name": "latest", "html_url": "https://example.com"}"#)
        do {
            _ = try await service.latestRelease()
            Issue.record("expected unparseableTag, got a result")
        } catch let UpdateCheckError.unparseableTag(tag) {
            #expect(tag == "latest")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("fetcher errors propagate to the caller (the offline path)")
    func fetcherErrorPropagates() async {
        struct Boom: Error {}
        let service = UpdateService(fetcher: { throw Boom() })
        do {
            _ = try await service.latestRelease()
            Issue.record("expected Boom, got a result")
        } catch is Boom {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
