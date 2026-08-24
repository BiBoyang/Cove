import AppKit
import SnapKit

/// Preferences feature window (Cmd+,): cache budget/TTL/usage/clear, and
/// preheat enable/rate-limit/folders. Values persist via `SettingsService`
/// (UserDefaults); changes apply live through the didChange notification.
/// Deliberately plain — a single column of labeled rows, no tabs.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let viewModel: PreferencesViewModel

    // Cache section
    private let capacityField = NSTextField()
    private let ttlField = NSTextField()
    private let originalUsageLabel = NSTextField(labelWithString: "")
    private let displayUsageLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "立即清理", target: nil, action: nil)

    // Preheat section
    private let preheatCheckbox = NSButton(checkboxWithTitle: "启用预热", target: nil, action: nil)
    private let rateLimitField = NSTextField()
    private let folderField = NSTextField()
    private let folderTableView = NSTableView()
    private let addFolderButton = NSButton(title: "添加", target: nil, action: nil)
    private let removeFolderButton = NSButton(title: "删除", target: nil, action: nil)

    // Vault section
    private let vaultPathLabel = NSTextField(labelWithString: "")
    private let chooseVaultButton = NSButton(title: "更改…", target: nil, action: nil)
    private let revealVaultButton = NSButton(title: "在 Finder 中打开", target: nil, action: nil)

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(viewModel: PreferencesViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
        viewModel.onStateChange = { [weak self] state in
            self?.render(state)
        }
        viewModel.onClearError = { [weak self] message in
            self?.showClearError(message)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Re-read everything: settings may have changed while the window was
        // closed, and the usage numbers move constantly.
        viewModel.reload()
    }

    // MARK: - Layout

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        configureNumberField(capacityField, allowsFloat: false)
        configureNumberField(ttlField, allowsFloat: false)
        configureNumberField(rateLimitField, allowsFloat: true)

        for label in [originalUsageLabel, displayUsageLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }

        preheatCheckbox.target = self
        preheatCheckbox.action = #selector(preheatToggled(_:))
        clearButton.target = self
        clearButton.action = #selector(clearCache(_:))
        clearButton.bezelStyle = .rounded
        addFolderButton.target = self
        addFolderButton.action = #selector(addFolder(_:))
        addFolderButton.bezelStyle = .rounded
        removeFolderButton.target = self
        removeFolderButton.action = #selector(removeFolder(_:))
        removeFolderButton.bezelStyle = .rounded

        vaultPathLabel.font = .systemFont(ofSize: 11)
        vaultPathLabel.textColor = .secondaryLabelColor
        vaultPathLabel.lineBreakMode = .byTruncatingMiddle
        vaultPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseVaultButton.target = self
        chooseVaultButton.action = #selector(chooseVaultLocation(_:))
        chooseVaultButton.bezelStyle = .rounded
        revealVaultButton.target = self
        revealVaultButton.action = #selector(revealVaultLocation(_:))
        revealVaultButton.bezelStyle = .rounded

        // Return in the input field adds the folder.
        folderField.placeholderString = "公共空间/动漫/xxx"
        folderField.target = self
        folderField.action = #selector(addFolder(_:))
        folderField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        folderTableView.addTableColumn(column)
        folderTableView.headerView = nil
        folderTableView.dataSource = self
        folderTableView.delegate = self

        let folderScrollView = NSScrollView()
        folderScrollView.documentView = folderTableView
        folderScrollView.hasVerticalScroller = true
        folderScrollView.borderType = .bezelBorder

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(20)
        }

        stack.addArrangedSubview(makeHeader("缓存"))
        stack.addArrangedSubview(makeRow(
            makeLabel("容量上限 (GB)"), capacityField,
            makeLabel("保留时长 (天)"), ttlField
        ))
        stack.addArrangedSubview(originalUsageLabel)
        stack.addArrangedSubview(displayUsageLabel)
        stack.addArrangedSubview(clearButton)

        stack.setCustomSpacing(16, after: clearButton)
        stack.addArrangedSubview(makeHeader("预热"))
        stack.addArrangedSubview(preheatCheckbox)
        stack.addArrangedSubview(makeRow(makeLabel("限速 (MB/s，0 为不限)"), rateLimitField))
        stack.addArrangedSubview(makeLabel("预热文件夹（含共享名，如 公共空间/动漫/xxx；仅对当前连接的共享生效）"))
        stack.addArrangedSubview(folderScrollView)
        let inputRow = makeRow(folderField, addFolderButton, removeFolderButton)
        stack.addArrangedSubview(inputRow)

        // These two span the full width; everything else hugs its content.
        folderScrollView.snp.makeConstraints { make in
            make.width.equalTo(stack)
            make.height.equalTo(150)
        }
        inputRow.snp.makeConstraints { make in
            make.width.equalTo(stack)
        }

        stack.setCustomSpacing(16, after: inputRow)
        stack.addArrangedSubview(makeHeader("本地仓库"))
        let vaultRow = makeRow(makeLabel("位置"), vaultPathLabel, chooseVaultButton, revealVaultButton)
        stack.addArrangedSubview(vaultRow)
        stack.addArrangedSubview(makeLabel("更改位置只影响新下载，旧位置的文件不会迁移。"))
        vaultRow.snp.makeConstraints { make in
            make.width.equalTo(stack)
        }
    }

    private func configureNumberField(_ field: NSTextField, allowsFloat: Bool) {
        let formatter = NumberFormatter()
        formatter.allowsFloats = allowsFloat
        formatter.minimum = NSNumber(value: allowsFloat ? 0 : 1)
        field.formatter = formatter
        field.delegate = self
        field.snp.makeConstraints { make in
            make.width.equalTo(64)
        }
    }

    private func makeHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .bold)
        return label
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func makeRow(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // MARK: - Values

    private func render(_ state: PreferencesViewModel.State) {
        capacityField.stringValue = String(state.capacityGB)
        ttlField.stringValue = String(state.ttlDays)
        let rate = state.rateLimitMBps
        rateLimitField.stringValue = rate == rate.rounded() ? String(Int(rate)) : String(rate)
        preheatCheckbox.state = state.preheatEnabled ? .on : .off
        if let original = state.originalUsageBytes, let display = state.displayUsageBytes {
            originalUsageLabel.stringValue = "原始缓存：\(byteFormatter.string(fromByteCount: original))"
            displayUsageLabel.stringValue = "显示缓存：\(byteFormatter.string(fromByteCount: display))"
        } else {
            originalUsageLabel.stringValue = "原始缓存：统计中…"
            displayUsageLabel.stringValue = "显示缓存：统计中…"
        }
        vaultPathLabel.stringValue = state.vaultPath
        folderTableView.reloadData()
    }

    // MARK: - Actions

    @objc private func preheatToggled(_ sender: NSButton) {
        viewModel.setPreheatEnabled(sender.state == .on)
    }

    @objc private func clearCache(_ sender: NSButton) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清空图片缓存？"
        alert.informativeText = "将删除磁盘上的全部原始与显示缓存，之后浏览会重新下载。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.viewModel.clearCache()
        }
    }

    @objc private func addFolder(_ sender: Any?) {
        let path = folderField.stringValue
        guard viewModel.addFolder(path) else {
            if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { NSSound.beep() }
            return
        }
        folderField.stringValue = ""
    }

    @objc private func removeFolder(_ sender: Any?) {
        let row = folderTableView.selectedRow
        guard viewModel.removeFolder(at: row) else {
            NSSound.beep()
            return
        }
    }

    /// The panel grants sandbox access to the chosen directory; the VM
    /// persists it as a security-scoped bookmark.
    @objc private func chooseVaultLocation(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if !self.viewModel.chooseVaultRoot(url) { NSSound.beep() }
        }
    }

    @objc private func revealVaultLocation(_ sender: Any?) {
        let root = viewModel.vaultRootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private func revert(_ field: NSTextField, to text: String) {
        NSSound.beep()
        field.stringValue = text
    }

    /// A clear owned by the current view-model generation failed; the
    /// numbers refresh to the real remaining usage afterwards.
    private func showClearError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清空缓存失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}

extension PreferencesWindowController: NSTextFieldDelegate {
    /// Numeric fields commit on Return or focus loss; invalid input is
    /// rejected with a beep and the field reverts to the stored value.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let state = viewModel.state
        switch field {
        case capacityField:
            if !viewModel.setCapacity(text: capacityField.stringValue) {
                revert(capacityField, to: String(state.capacityGB))
            }
        case ttlField:
            if !viewModel.setTTL(text: ttlField.stringValue) {
                revert(ttlField, to: String(state.ttlDays))
            }
        case rateLimitField:
            if !viewModel.setRateLimit(text: rateLimitField.stringValue) {
                let rate = state.rateLimitMBps
                revert(rateLimitField, to: rate == rate.rounded() ? String(Int(rate)) : String(rate))
            }
        default:
            break
        }
    }
}

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.state.folders.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FolderCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(label)
            cell.textField = label
            label.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(6)
                make.trailing.equalToSuperview().offset(-6)
                make.centerY.equalToSuperview()
            }
        }
        cell.textField?.stringValue = viewModel.state.folders[row]
        return cell
    }
}
