import UIKit
import AsyncDisplayKit
import Display
import AppBundle
import ComponentFlow
import ComponentDisplayAdapters
import GlassBackgroundComponent

/// The composer, laid out like Telegram's iOS 26 ChatTextInputPanelNode: an attachment button (Telegram's paperclip),
/// a growing text field, and a microphone that turns into the send button once there is text. Every shape is glass inside
/// one GlassBackgroundContainerView, so iOS merges and morphs them. Editing a message adds Telegram's accessory bar
/// above the field.
final class ChatInputPanelNode: ASDisplayNode, UITextViewDelegate {
    private var theme: TauTheme
    private let glassContainer: GlassBackgroundContainerView
    private let attachBackgroundView: GlassBackgroundView
    private let attachIconView: UIImageView
    private let fieldBackgroundView: GlassBackgroundView
    private let textView: UITextView
    private let placeholderLabel: UILabel
    private let micBackgroundView: GlassBackgroundView
    private let micIconView: UIImageView
    private let sendBackgroundView: GlassBackgroundView
    private let sendIconView: UIImageView
    /// Stops the agent; takes the microphone's place while it works and the field is empty.
    private let stopBackgroundView: GlassBackgroundView
    private let stopIconView: UIImageView
    private let accessoryView: EditAccessoryView

    var sendMessage: ((String) -> Void)?
    var attachPressed: (() -> Void)?
    var micPressed: (() -> Void)?
    var stopPressed: (() -> Void)?

    /// The agent is working: the empty field's action is Stop.
    var isBusy: Bool = false {
        didSet {
            if self.isBusy != oldValue {
                self.requestLayout?(.animated(duration: 0.25, curve: .spring))
            }
        }
    }
    var cancelEditing: (() -> Void)?
    /// The text changed height, the send button appeared, or editing began; the owner lays out again.
    var requestLayout: ((ContainedViewLayoutTransition) -> Void)?

    private var currentTextHeight: CGFloat = 0.0
    private enum Action {
        case microphone
        case send
        case stop
    }
    private var action: Action = .microphone
    private var validWidth: CGFloat?
    private(set) var editingText: String?

    // Telegram ChatTextInputPanelNode: 40 pt controls, 6 pt between glass shapes.
    private static let controlSize: CGFloat = 40.0
    private static let spacing: CGFloat = 6.0
    private static let fieldMaxLines: CGFloat = 6.0
    private static let font = Font.regular(17.0)
    private static let textInsets = UIEdgeInsets(top: 10.0, left: 16.0, bottom: 10.0, right: 16.0)
    private static let accessoryHeight: CGFloat = 46.0

    init(theme: TauTheme) {
        self.theme = theme
        self.glassContainer = GlassBackgroundContainerView(spacing: 7.0)
        self.attachBackgroundView = GlassBackgroundView()
        self.fieldBackgroundView = GlassBackgroundView()
        self.micBackgroundView = GlassBackgroundView()
        self.sendBackgroundView = GlassBackgroundView()
        self.stopBackgroundView = GlassBackgroundView()
        self.stopIconView = UIImageView()
        self.stopIconView.contentMode = .center
        self.attachIconView = UIImageView()
        self.attachIconView.contentMode = .center
        self.micIconView = UIImageView()
        self.micIconView.contentMode = .center
        self.sendIconView = UIImageView()
        self.sendIconView.contentMode = .center
        self.accessoryView = EditAccessoryView()

        self.textView = UITextView()
        self.textView.backgroundColor = .clear
        self.textView.font = ChatInputPanelNode.font
        self.textView.textContainerInset = ChatInputPanelNode.textInsets
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.isScrollEnabled = false
        self.textView.scrollsToTop = false

        self.placeholderLabel = UILabel()
        self.placeholderLabel.font = ChatInputPanelNode.font
        self.placeholderLabel.text = "Message"

        super.init()
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.glassContainer)
        let content = self.glassContainer.contentView
        content.addSubview(self.accessoryView)
        content.addSubview(self.attachBackgroundView)
        self.attachBackgroundView.contentView.addSubview(self.attachIconView)
        content.addSubview(self.fieldBackgroundView)
        self.fieldBackgroundView.contentView.addSubview(self.placeholderLabel)
        self.fieldBackgroundView.contentView.addSubview(self.textView)
        content.addSubview(self.micBackgroundView)
        self.micBackgroundView.contentView.addSubview(self.micIconView)
        content.addSubview(self.sendBackgroundView)
        self.sendBackgroundView.contentView.addSubview(self.sendIconView)
        content.addSubview(self.stopBackgroundView)
        self.stopBackgroundView.contentView.addSubview(self.stopIconView)
        self.stopBackgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.stopTapped)))
        self.stopBackgroundView.alpha = 0.0

        self.textView.delegate = self
        self.attachBackgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.attachTapped)))
        self.micBackgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.micTapped)))
        self.sendBackgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.sendPressed)))
        self.accessoryView.cancel = { [weak self] in
            self?.cancelEditing?()
        }
        self.sendBackgroundView.alpha = 0.0
        self.accessoryView.alpha = 0.0
        for (view, identifier) in [(self.attachBackgroundView, "attach"), (self.micBackgroundView, "microphone"), (self.sendBackgroundView, "send"), (self.stopBackgroundView, "stop")] as [(UIView, String)] {
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = identifier
            view.accessibilityLabel = identifier.capitalized
            view.accessibilityTraits = .button
        }
        self.applyTheme()
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        if self.isNodeLoaded {
            self.applyTheme()
        }
    }

    private func applyTheme() {
        let chat = self.theme.chat
        self.attachIconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/IconAttachment"), color: chat.panelControlColor)
        self.micIconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/IconMicrophone"), color: chat.panelControlColor)
        self.sendIconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/SendIcon"), color: chat.actionControlForegroundColor)
        self.stopIconView.image = generateImage(CGSize(width: 14.0, height: 14.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(chat.actionControlForegroundColor.cgColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: 3.0).cgPath)
            context.fillPath()
        })
        self.textView.textColor = chat.inputTextColor
        self.textView.tintColor = self.theme.accentColor
        self.textView.keyboardAppearance = self.theme.overallDarkAppearance ? .dark : .default
        self.placeholderLabel.textColor = chat.inputPlaceholderColor
        self.accessoryView.update(theme: self.theme)
    }

    var text: String {
        return self.textView.text ?? ""
    }

    func activateInput() {
        self.textView.becomeFirstResponder()
    }

    func deactivateInput() {
        self.textView.resignFirstResponder()
    }

    func setText(_ text: String) {
        self.textView.text = text
        self.textViewDidChange(self.textView)
    }

    /// Show Telegram's "Edit Message" bar for `original`, or hide it with nil.
    func setEditing(_ original: String?) {
        self.editingText = original
        self.accessoryView.setText(original ?? "")
        self.requestLayout?(.animated(duration: 0.4, curve: .spring))
    }

    @objc private func stopTapped() {
        self.stopPressed?()
    }

    @objc private func attachTapped() {
        self.attachPressed?()
    }

    @objc private func micTapped() {
        self.micPressed?()
    }

    @objc private func sendPressed() {
        let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        self.sendMessage?(text)
        self.textView.text = ""
        self.textViewDidChange(self.textView)
    }

    func textViewDidChange(_ textView: UITextView) {
        self.placeholderLabel.isHidden = !textView.text.isEmpty
        let hasText = !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let width = self.validWidth else {
            return
        }
        if hasText != (self.action == .send) || self.measureTextHeight(width: width) != self.currentTextHeight {
            self.requestLayout?(.animated(duration: 0.4, curve: .spring))
        }
    }

    private func fieldWidth(_ width: CGFloat) -> CGFloat {
        let size = ChatInputPanelNode.controlSize
        let spacing = ChatInputPanelNode.spacing
        return width - (size + spacing) * 2.0
    }

    private func measureTextHeight(width: CGFloat) -> CGFloat {
        let insets = ChatInputPanelNode.textInsets
        let textWidth = self.fieldWidth(width) - insets.left - insets.right
        let maxHeight = ceil(ChatInputPanelNode.font.lineHeight * ChatInputPanelNode.fieldMaxLines)
        let text = self.text.isEmpty ? " " : self.text
        let bounds = (text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: ChatInputPanelNode.font], context: nil)
        return min(maxHeight, ceil(bounds.height))
    }

    /// Lays the panel out in `width` and returns its height.
    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.validWidth = width
        let hasText = !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let action: Action = hasText ? .send : (self.isBusy ? .stop : .microphone)
        let previousAction = self.action
        self.action = action
        let size = ChatInputPanelNode.controlSize
        let spacing = ChatInputPanelNode.spacing
        let insets = ChatInputPanelNode.textInsets
        let isDark = self.theme.overallDarkAppearance
        let componentTransition = ComponentTransition(transition)

        let accessoryHeight: CGFloat = self.editingText == nil ? 0.0 : ChatInputPanelNode.accessoryHeight + spacing
        let textHeight = self.measureTextHeight(width: width)
        self.currentTextHeight = textHeight
        let fieldHeight = max(size, textHeight + insets.top + insets.bottom)
        self.textView.isScrollEnabled = textHeight >= ceil(ChatInputPanelNode.font.lineHeight * ChatInputPanelNode.fieldMaxLines)

        let panelSize = CGSize(width: width, height: accessoryHeight + fieldHeight)
        componentTransition.setFrame(view: self.glassContainer, frame: CGRect(origin: CGPoint(), size: panelSize))
        self.glassContainer.update(size: panelSize, isDark: isDark, transition: componentTransition)

        let accessoryFrame = CGRect(x: size + spacing, y: 0.0, width: self.fieldWidth(width), height: ChatInputPanelNode.accessoryHeight)
        componentTransition.setFrame(view: self.accessoryView, frame: accessoryFrame)
        self.accessoryView.layout(size: accessoryFrame.size, isDark: isDark, transition: componentTransition)
        componentTransition.setAlpha(view: self.accessoryView, alpha: self.editingText == nil ? 0.0 : 1.0)

        // Controls stay on the last line as the field grows, as Telegram's do.
        let controlsY = accessoryHeight + fieldHeight - size
        let attachFrame = CGRect(origin: CGPoint(x: 0.0, y: controlsY), size: CGSize(width: size, height: size))
        componentTransition.setFrame(view: self.attachBackgroundView, frame: attachFrame)
        self.attachBackgroundView.update(size: attachFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: componentTransition)
        self.attachIconView.frame = CGRect(origin: CGPoint(), size: attachFrame.size)

        let fieldFrame = CGRect(origin: CGPoint(x: attachFrame.maxX + spacing, y: accessoryHeight), size: CGSize(width: self.fieldWidth(width), height: fieldHeight))
        componentTransition.setFrame(view: self.fieldBackgroundView, frame: fieldFrame)
        self.fieldBackgroundView.update(size: fieldFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: componentTransition)
        componentTransition.setFrame(view: self.textView, frame: CGRect(origin: CGPoint(), size: fieldFrame.size))
        self.placeholderLabel.frame = CGRect(origin: CGPoint(x: insets.left, y: insets.top), size: CGSize(width: fieldFrame.width - insets.left - insets.right, height: ceil(ChatInputPanelNode.font.lineHeight)))

        // The microphone and the send button share a spot; one replaces the other with Telegram's scale and fade
        // (ChatTextInputActionButtonsNode).
        let actionFrame = CGRect(origin: CGPoint(x: width - size, y: controlsY), size: CGSize(width: size, height: size))
        for view in [self.micBackgroundView, self.sendBackgroundView, self.stopBackgroundView] {
            view.center = actionFrame.center
            view.bounds = CGRect(origin: CGPoint(), size: actionFrame.size)
        }
        self.micBackgroundView.update(size: actionFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: componentTransition)
        self.sendBackgroundView.update(size: actionFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .custom(style: .default, color: self.theme.chat.actionControlFillColor)), isInteractive: true, transition: componentTransition)
        self.stopBackgroundView.update(size: actionFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .custom(style: .default, color: self.theme.chat.actionControlFillColor)), isInteractive: true, transition: componentTransition)
        self.micIconView.frame = CGRect(origin: CGPoint(), size: actionFrame.size)
        self.sendIconView.frame = CGRect(origin: CGPoint(), size: actionFrame.size)
        self.stopIconView.frame = CGRect(origin: CGPoint(), size: actionFrame.size)
        let views: [Action: UIView] = [.microphone: self.micBackgroundView, .send: self.sendBackgroundView, .stop: self.stopBackgroundView]
        if action != previousAction && transition.isAnimated, let shown = views[action], let hidden = views[previousAction] {
            shown.alpha = 1.0
            hidden.alpha = 0.0
            shown.layer.animateScale(from: 0.2, to: 1.0, duration: 0.25, timingFunction: kCAMediaTimingFunctionSpring)
            shown.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
            hidden.layer.animateScale(from: 1.0, to: 0.2, duration: 0.2)
            hidden.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15)
        } else {
            for (key, view) in views {
                view.alpha = key == action ? 1.0 : 0.0
            }
        }

        return panelSize.height
    }
}

/// Telegram's "Edit Message" bar above the input field: an accent line, a title, the original text and a close button.
private final class EditAccessoryView: UIView {
    private let backgroundView = GlassBackgroundView()
    private let lineView = UIView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    var cancel: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.backgroundView)
        self.backgroundView.contentView.addSubview(self.lineView)
        self.backgroundView.contentView.addSubview(self.titleLabel)
        self.backgroundView.contentView.addSubview(self.textLabel)
        self.backgroundView.contentView.addSubview(self.closeButton)
        self.lineView.layer.cornerRadius = 1.5
        self.titleLabel.font = Font.semibold(14.0)
        self.titleLabel.text = "Edit Message"
        self.textLabel.font = Font.regular(14.0)
        self.closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)), for: .normal)
        self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func closePressed() {
        self.cancel?()
    }

    func update(theme: TauTheme) {
        self.lineView.backgroundColor = theme.accentColor
        self.titleLabel.textColor = theme.accentColor
        self.textLabel.textColor = theme.chat.inputTextColor
        self.closeButton.tintColor = theme.chat.panelControlColor
    }

    func setText(_ text: String) {
        if !text.isEmpty {
            self.textLabel.text = text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    func layout(size: CGSize, isDark: Bool, transition: ComponentTransition) {
        transition.setFrame(view: self.backgroundView, frame: CGRect(origin: CGPoint(), size: size))
        self.backgroundView.update(size: size, cornerRadius: 20.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: false, transition: transition)
        self.lineView.frame = CGRect(x: 14.0, y: 8.0, width: 3.0, height: size.height - 16.0)
        self.titleLabel.frame = CGRect(x: 25.0, y: 6.0, width: size.width - 70.0, height: 18.0)
        self.textLabel.frame = CGRect(x: 25.0, y: 23.0, width: size.width - 70.0, height: 18.0)
        self.closeButton.frame = CGRect(x: size.width - 40.0, y: 0.0, width: 36.0, height: size.height)
    }
}
