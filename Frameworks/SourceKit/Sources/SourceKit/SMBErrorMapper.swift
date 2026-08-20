import Foundation

/// Maps AMSMB2/libSMB2 errors onto `SourceError`.
///
/// AMSMB2 surfaces server errors as `POSIXError`; libsmb2 maps the SMB
/// status codes onto errno values. Shared by `SMBSource` (share-level
/// sessions) and `SMBServer` (server-level enumeration).
enum SMBErrorMapper {
    /// Maps errors thrown while establishing a session or attaching to a
    /// resource (a share, or `IPC$` for share enumeration).
    static func connectError(_ error: Error, host: String, resource: String) -> SourceError {
        guard let posix = error as? POSIXError else {
            return .connectionFailed("\(host): \(error.localizedDescription)")
        }
        switch posix.code {
        case .EACCES, .EPERM, .EAUTH:
            return .authenticationFailed
        case .ENOENT, .ENODEV:
            return .pathNotFound(resource)
        // Transport-level failures: the credentials and paths were never
        // evaluated, so reporting anything but a connection problem would
        // mislead the user.
        case .ETIMEDOUT, .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH,
             .ENOTCONN, .ECONNRESET, .EPIPE, .EHOSTDOWN:
            return .connectionFailed("\(host): \(String(describing: posix.code))")
        default:
            return .connectionFailed("\(host): \(String(describing: posix.code))")
        }
    }

    /// Maps errors thrown by operations on an already-connected share.
    static func pathError(_ error: Error, path: String, operation: String) -> SourceError {
        guard let posix = error as? POSIXError else {
            return .operationFailed("\(operation) \(path): \(error.localizedDescription)")
        }
        switch posix.code {
        case .ENOENT:
            return .pathNotFound(path)
        case .EACCES, .EPERM:
            return .permissionDenied(path)
        // Transport-level failures mid-operation mean the session is gone,
        // not that the path is bad — surface them as connection problems.
        case .ENOTCONN, .ETIMEDOUT, .ECONNRESET, .ECONNABORTED,
             .ENETDOWN, .ENETRESET, .EPIPE, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH:
            return .connectionFailed("\(operation) \(path): \(String(describing: posix.code))")
        default:
            return .operationFailed("\(operation) \(path): \(String(describing: posix.code))")
        }
    }
}
