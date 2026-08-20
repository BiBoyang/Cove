import AppKit

/// Modal sheet collecting server address / share / username / password.
@MainActor
final class AddServerSheetController: NSWindowController {
    struct FormResult {
        let host: String
        let share: String
        let username: String
        let password: String
    }

    private let hostField = NSTextField()
    private let shareField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()

    private var completion: ((FormResult?) -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 190),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "添加服务器"
        super.init(window: window)
        buildForm()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func beginSheet(on parent: NSWindow, completion: @escaping (FormResult?) -> Void) {
        self.completion = completion
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
    }

    private func buildForm() {
        guard let contentView = window?.contentView else { return }

        hostField.placeholderString = "例如 192.168.1.10 或 nas.local"
        shareField.placeholderString = "例如 media"
        usernameField.placeholderString = ""
        passwordField.placeholderString = ""

        let grid = NSGridView(views: [
            [makeLabel("服务器地址"), hostField],
            [makeLabel("共享名"), shareField],
            [makeLabel("用户名"), usernameField],
            [makeLabel("密码"), passwordField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        for field in [hostField, shareField, usernameField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        let confirmButton = NSButton(title: "添加", target: self, action: #selector(confirm))
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(grid)
        contentView.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            grid.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            buttonRow.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    @objc private func confirm() {
        let result = FormResult(
            host: hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            share: shareField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            username: usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: passwordField.stringValue
        )
        guard !result.host.isEmpty, !result.share.isEmpty, !result.username.isEmpty else {
            NSSound.beep()
            return
        }
        close(with: result)
    }

    @objc private func cancel() {
        close(with: nil)
    }

    private func close(with result: FormResult?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        completion?(result)
        completion = nil
    }
}
