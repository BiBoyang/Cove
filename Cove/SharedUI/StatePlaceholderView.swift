import AppKit
import SnapKit

/// The shared empty/loading/failure placeholder: a centered symbol (or
/// spinner) over a title, a one-line message, and an optional action
/// button. One component so every pane speaks the same state language
/// instead of hand-rolled labels (design tokens §6.1/§6.2).
@MainActor
final class StatePlaceholderView: NSView {
    enum Style: Equatable {
        /// Large monochrome symbol (e.g. empty folder, guidance).
        case symbol(String)
        /// Native spinner instead of a symbol — for actual in-flight work.
        case loading
    }

    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var actionButton: PillButton?
    var onAction: (() -> Void)?

    init(
        style: Style,
        title: String,
        message: String,
        actionTitle: String? = nil
    ) {
        super.init(frame: .zero)

        switch style {
        case .symbol(let name):
            iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: CoveStyle.symbolHero, weight: .light))
            iconView.contentTintColor = .tertiaryLabelColor
        case .loading:
            spinner.style = .spinning
            spinner.controlSize = .large
            spinner.startAnimation(nil)
        }

        titleLabel.stringValue = title
        titleLabel.font = CoveStyle.titleFont
        titleLabel.alignment = .center

        messageLabel.stringValue = message
        messageLabel.font = CoveStyle.captionFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.addArrangedSubview(style == .loading ? spinner : iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)

        if let actionTitle {
            let button = PillButton(title: actionTitle, style: .primary)
            button.target = self
            button.action = #selector(handleAction)
            stack.addArrangedSubview(button)
            stack.setCustomSpacing(18, after: messageLabel)
            actionButton = button
        }

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualTo(360)
        }

        // Symbols and spinners read best at a consistent modest size.
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
            spinner.widthAnchor.constraint(equalToConstant: 32),
            spinner.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func handleAction() {
        onAction?()
    }
}
