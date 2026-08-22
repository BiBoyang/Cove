import Foundation

/// Minimal cache capability required by the Preferences feature.
///
/// The contract lives with the app's media-service boundary so a future
/// Preferences UI target does not force a dependency on CacheKit or on a
/// concrete service adapter.
protocol PreferencesCacheManaging: Sendable {
    func usage() throws -> (original: Int64, display: Int64)
    func clearAll() throws
}
