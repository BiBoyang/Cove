import Foundation
import os.log

/// Shared logging constants.
public enum Trace {
    /// The os_log subsystem used across the whole app.
    public static let subsystem = "com.biboyang.cove"
}

/// Privacy level for interpolated log content.
///
/// A twin of `OSLogPrivacy`, which cannot be passed through at runtime:
/// os_log's string interpolation requires a compile-time constant and the
/// type is not `Equatable`, so callers pick from this enum and the logger
/// maps it onto static interpolation literals.
public enum TracePrivacy: Sendable {
    /// os_log default: dynamic content is redacted in persisted logs.
    case auto
    /// Always visible. Only for content safe to read back in Console.
    case `public`
    /// Always redacted unless attached to a debugger/streaming privately.
    case `private`
    /// Redacted even more aggressively than `.private`.
    case sensitive
}

/// Thin wrapper over `os.Logger` with explicit levels.
///
/// Privacy policy: interpolated content defaults to `.auto`, which os_log
/// redacts (`<private>`) in persisted logs. Hosts, share names, paths and
/// error details carry user data — pass `.private` (or keep the default) for
/// those, and reserve `.public` for content that is safe to read back in
/// Console. Never log credentials through this API.
public struct TraceLogger: Sendable {
    /// The os_log category this logger writes to.
    public let category: String

    private let logger: os.Logger

    public init(subsystem: String = Trace.subsystem, category: String) {
        self.category = category
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String, privacy: TracePrivacy = .auto) {
        log(.debug, message, privacy: privacy)
    }

    public func info(_ message: String, privacy: TracePrivacy = .auto) {
        log(.info, message, privacy: privacy)
    }

    public func notice(_ message: String, privacy: TracePrivacy = .auto) {
        log(.default, message, privacy: privacy)
    }

    public func error(_ message: String, privacy: TracePrivacy = .auto) {
        log(.error, message, privacy: privacy)
    }

    public func fault(_ message: String, privacy: TracePrivacy = .auto) {
        log(.fault, message, privacy: privacy)
    }

    /// Maps the runtime privacy choice onto static interpolation literals,
    /// which is the only form os_log accepts.
    private func log(_ level: OSLogType, _ message: String, privacy: TracePrivacy) {
        switch privacy {
        case .auto:
            logger.log(level: level, "\(message, privacy: .auto)")
        case .public:
            logger.log(level: level, "\(message, privacy: .public)")
        case .private:
            logger.log(level: level, "\(message, privacy: .private)")
        case .sensitive:
            logger.log(level: level, "\(message, privacy: .sensitive)")
        }
    }
}
