import Foundation
import os.log

/// Shared logging constants.
public enum Trace {
    /// The os_log subsystem used across the whole app.
    public static let subsystem = "com.biboyang.cove"
}

/// Thin wrapper over `os.Logger` with explicit levels.
///
/// Messages are emitted with `.public` privacy on purpose: Cove is a local
/// media tool and its log lines never contain credentials (never log
/// passwords or tokens through this API).
public struct TraceLogger: Sendable {
    /// The os_log category this logger writes to.
    public let category: String

    private let logger: os.Logger

    public init(subsystem: String = Trace.subsystem, category: String) {
        self.category = category
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    public func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
    }
}
