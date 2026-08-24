import AppKit
import SnapKit

/// Servers feature modal sheet collecting server address / username / password.
@MainActor
final class AddServerSheetController: NSWindowController {
    typealias FormResult = AddServerViewModel.FormResult

    private let viewModel = AddServerViewModel()
    private let hostField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let hintLabel = NSTextField(labelWithString: "")

    private var completion: ((FormResult?) -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 176),
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
        usernameField.placeholderString = ""
        passwordField.placeholderString = ""

        for field in [hostField, usernameField, passwordField] as [NSTextField] {
            field.delegate = self
            field.snp.makeConstraints { make in
                make.width.equalTo(260)
            }
        }

        let grid = NSGridView(views: [
            [makeLabel("服务器地址"), hostField],
            [makeLabel("用户名"), usernameField],
            [makeLabel("密码"), passwordField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8

        // Validation feedback: specific, red, hidden until needed. Any edit
        // hides it again (see controlTextDidChange).
        hintLabel.textColor = .systemRed
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.isHidden = true

        let cancelButton = PillButton(title: "取消", style: .secondary)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        let confirmButton = PillButton(title: "添加", style: .primary)
        confirmButton.target = self
        confirmButton.action = #selector(confirm)
        confirmButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        contentView.addSubview(grid)
        contentView.addSubview(hintLabel)
        contentView.addSubview(buttonRow)
        grid.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(16)
            make.centerX.equalToSuperview()
        }
        hintLabel.snp.makeConstraints { make in
            make.top.equalTo(grid.snp.bottom).offset(6)
            make.leading.equalTo(hostField)
        }
        buttonRow.snp.makeConstraints { make in
            make.top.equalTo(hintLabel.snp.bottom).offset(10)
            make.trailing.equalTo(grid)
            make.bottom.equalToSuperview().offset(-14)
        }
    }

    private func makeLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    @objc private func confirm() {
        switch viewModel.submit(
            host: hostField.stringValue,
            username: usernameField.stringValue,
            password: passwordField.stringValue
        ) {
        case .success(let result):
            close(with: result)
        case .failure(let error):
            showHint(error.message)
        }
    }

    @objc private func cancel() {
        close(with: nil)
    }

    private func showHint(_ text: String) {
        NSSound.beep()
        hintLabel.stringValue = text
        hintLabel.isHidden = false
    }

    private func close(with result: FormResult?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        completion?(result)
        completion = nil
    }
}

extension AddServerSheetController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        hintLabel.isHidden = true
    }
}
