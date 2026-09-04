import AppKit
import SnapKit

/// Servers feature modal sheet collecting server address / username /
/// password when adding a server, or just the optional remote address when
/// editing one (host, username, and password are unchanged by an edit).
@MainActor
final class AddServerSheetController: NSWindowController {
    typealias FormResult = AddServerViewModel.FormResult

    /// What the sheet hands back on confirm; cancel delivers nil.
    enum Outcome {
        case add(FormResult)
        case editRemote(ServerConfig, remoteHost: String?)
    }

    private enum Mode {
        case add
        case editRemote(ServerConfig)
    }

    private let mode: Mode
    private let viewModel = AddServerViewModel()
    private let hostField = NSTextField()
    private let remoteHostField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let hintLabel = NSTextField(labelWithString: "")

    private var completion: ((Outcome?) -> Void)?

    init() {
        mode = .add
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 210),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "添加服务器"
        super.init(window: window)
        buildForm()
    }

    init(editRemote server: ServerConfig) {
        mode = .editRemote(server)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑远程地址"
        super.init(window: window)
        buildForm()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func beginSheet(on parent: NSWindow, completion: @escaping (Outcome?) -> Void) {
        self.completion = completion
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
    }

    private func buildForm() {
        guard let contentView = window?.contentView else { return }

        hostField.placeholderString = "例如 192.168.1.10 或 nas.local"
        remoteHostField.placeholderString = "例如 Tailscale IP 或公网地址"
        usernameField.placeholderString = ""
        passwordField.placeholderString = ""

        let fields: [NSTextField]
        var firstField = remoteHostField
        let rows: [[NSView]]
        switch mode {
        case .add:
            fields = [hostField, remoteHostField, usernameField, passwordField]
            firstField = hostField
            rows = [
                [makeLabel("服务器地址"), hostField],
                [makeLabel("远程地址（可选）"), remoteHostField],
                [makeLabel("用户名"), usernameField],
                [makeLabel("密码"), passwordField],
            ]
        case .editRemote(let server):
            fields = [remoteHostField]
            rows = [
                [makeLabel("远程地址（可选）"), remoteHostField],
            ]
            remoteHostField.stringValue = server.remoteHost ?? ""
        }
        for field in fields {
            field.delegate = self
            field.snp.makeConstraints { make in
                make.width.equalTo(260)
            }
        }

        let grid = NSGridView(views: rows)
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
        var confirmTitle = "添加"
        if case .editRemote = mode { confirmTitle = "保存" }
        let confirmButton = PillButton(title: confirmTitle, style: .primary)
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
            make.leading.equalTo(firstField)
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
        switch mode {
        case .add:
            switch viewModel.submit(
                host: hostField.stringValue,
                remoteHost: remoteHostField.stringValue,
                username: usernameField.stringValue,
                password: passwordField.stringValue
            ) {
            case .success(let result):
                close(with: .add(result))
            case .failure(let error):
                showHint(error.message)
            }
        case .editRemote(let server):
            close(with: .editRemote(server, remoteHost: remoteHostField.stringValue.trimmedNonEmpty))
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

    private func close(with outcome: Outcome?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        completion?(outcome)
        completion = nil
    }
}

extension AddServerSheetController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        hintLabel.isHidden = true
    }
}
