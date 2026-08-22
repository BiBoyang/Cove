import Foundation

/// Add-server sheet view model: owns form validation so the window
/// controller only forwards raw field values and renders the outcome.
@MainActor
final class AddServerViewModel {
    /// Validated form values; host and username are whitespace-trimmed,
    /// the password is passed through untouched.
    struct FormResult: Equatable, Sendable {
        let host: String
        let username: String
        let password: String
    }

    enum ValidationError: Error, Equatable {
        case emptyHost
        case emptyUsername

        /// User-facing hint shown in the sheet.
        var message: String {
            switch self {
            case .emptyHost: return "请填写服务器地址"
            case .emptyUsername: return "请填写用户名"
            }
        }
    }

    /// Validates the raw field values, returning the trimmed form values
    /// or the first failing field.
    func submit(
        host: String,
        username: String,
        password: String
    ) -> Result<FormResult, ValidationError> {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .failure(.emptyHost) }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return .failure(.emptyUsername) }
        return .success(FormResult(host: host, username: username, password: password))
    }
}
