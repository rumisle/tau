import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import ComponentDisplayAdapters
import GlassBackgroundComponent

/// The message composer: a growing text field in a glass capsule and a round send button, laid out like Telegram's
/// iOS 26 input panel. The controller node positions it above the keyboard.
final class ChatInputPanelNode: ASDisplayNode, UITextViewDelegate {
    private let theme: TauTheme
    private let fieldBackgroundView: GlassBackgroundView
    private let textView: UITextView
    private let placeholderLabel: UILabel
    private let sendBackgroundView: GlassBackgroundView
    private let sendButton: HighlightableButtonNode
    private let sendIconNode: ASImageNode

    var sendMessage: ((String) -> Void)?
    /// The text changed height; the owner lays out again with this transition.
    var requestLayout: ((ContainedViewLayoutTransition) -> Void)?

    private var currentTextHeight: CGFloat = 0.0
    private var validWidth: CGFloat?

    private static let fieldMinHeight: CGFloat = 40.0
    private static let fieldMaxLines: CGFloat = 6.0
    private static let font = Font.regular(17.0)
    private static let textInsets = UIEdgeInsets(top: 10.0, left: 14.0, bottom: 10.0, right: 14.0)

    init(theme: TauTheme) {
        self.theme = theme
        self.fieldBackgroundView = GlassBackgroundView()
        self.sendBackgroundView = GlassBackgroundView()

        self.textView = UITextView()
        self.textView.backgroundColor = .clear
        self.textView.font = ChatInputPanelNode.font
        self.textView.textColor = theme.chat.inputTextColor
        self.textView.tintColor = theme.accentColor
        self.textView.textContainerInset = ChatInputPanelNode.textInsets
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.isScrollEnabled = false
        self.textView.scrollsToTop = false
        self.textView.keyboardAppearance = theme.overallDarkAppearance ? .dark : .default

        self.placeholderLabel = UILabel()
        self.placeholderLabel.font = ChatInputPanelNode.font
        self.placeholderLabel.textColor = theme.chat.inputPlaceholderColor
        self.placeholderLabel.text = "Message"

        self.sendButton = HighlightableButtonNode()
        self.sendIconNode = ASImageNode()
        self.sendIconNode.displaysAsynchronously = false
        self.sendIconNode.isUserInteractionEnabled = false
        self.sendIconNode.image = generateImage(CGSize(width: 40.0, height: 40.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(theme.chat.actionControlFillColor.cgColor)
            context.fillEllipse(in: CGRect(origin: CGPoint(), size: size).insetBy(dx: 3.0, dy: 3.0))
            if let arrow = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .semibold))?.withTintColor(theme.chat.actionControlForegroundColor, renderingMode: .alwaysOriginal) {
                UIGraphicsPushContext(context)
                arrow.draw(at: CGPoint(x: (size.width - arrow.size.width) / 2.0, y: (size.height - arrow.size.height) / 2.0))
                UIGraphicsPopContext()
            }
        })

        super.init()

        self.view.addSubview(self.fieldBackgroundView)
        self.fieldBackgroundView.contentView.addSubview(self.placeholderLabel)
        self.fieldBackgroundView.contentView.addSubview(self.textView)
        self.view.addSubview(self.sendBackgroundView)
        self.addSubnode(self.sendButton)
        self.sendButton.addSubnode(self.sendIconNode)

        self.textView.delegate = self
        self.sendButton.addTarget(self, action: #selector(self.sendPressed), forControlEvents: .touchUpInside)
        self.updateSendState(animated: false)
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
        self.updateSendState(animated: true)
        if let width = self.validWidth, self.measureTextHeight(width: width) != self.currentTextHeight {
            self.requestLayout?(.animated(duration: 0.2, curve: .easeInOut))
        }
    }

    private func updateSendState(animated: Bool) {
        let enabled = !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.2, curve: .easeInOut) : .immediate
        transition.updateAlpha(node: self.sendIconNode, alpha: enabled ? 1.0 : 0.4)
        self.sendButton.isEnabled = enabled
    }

    private func fieldWidth(_ width: CGFloat) -> CGFloat {
        return width - 40.0 - 8.0
    }

    private func measureTextHeight(width: CGFloat) -> CGFloat {
        let textWidth = self.fieldWidth(width) - ChatInputPanelNode.textInsets.left - ChatInputPanelNode.textInsets.right
        let lineHeight = ChatInputPanelNode.font.lineHeight
        let maxHeight = ceil(lineHeight * ChatInputPanelNode.fieldMaxLines)
        let text = self.text.isEmpty ? " " : self.text
        let bounds = (text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: ChatInputPanelNode.font], context: nil)
        return min(maxHeight, ceil(bounds.height))
    }

    /// Lays the panel out in `width` (already inside the safe area margins) and returns its height.
    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.validWidth = width
        let textHeight = self.measureTextHeight(width: width)
        self.currentTextHeight = textHeight
        let insets = ChatInputPanelNode.textInsets
        let fieldHeight = max(ChatInputPanelNode.fieldMinHeight, textHeight + insets.top + insets.bottom)
        self.textView.isScrollEnabled = textHeight >= ceil(ChatInputPanelNode.font.lineHeight * ChatInputPanelNode.fieldMaxLines)

        let fieldFrame = CGRect(origin: CGPoint(), size: CGSize(width: self.fieldWidth(width), height: fieldHeight))
        let componentTransition = ComponentTransition(transition)
        componentTransition.setFrame(view: self.fieldBackgroundView, frame: fieldFrame)
        self.fieldBackgroundView.update(size: fieldFrame.size, cornerRadius: ChatInputPanelNode.fieldMinHeight / 2.0, isDark: self.theme.overallDarkAppearance, tintColor: GlassBackgroundView.TintColor(kind: .panel), isInteractive: true, transition: componentTransition)
        componentTransition.setFrame(view: self.textView, frame: CGRect(origin: CGPoint(), size: fieldFrame.size))
        self.placeholderLabel.frame = CGRect(origin: CGPoint(x: insets.left, y: insets.top), size: CGSize(width: fieldFrame.width - insets.left - insets.right, height: ceil(ChatInputPanelNode.font.lineHeight)))

        let sendFrame = CGRect(origin: CGPoint(x: width - 40.0, y: fieldHeight - 40.0), size: CGSize(width: 40.0, height: 40.0))
        componentTransition.setFrame(view: self.sendBackgroundView, frame: sendFrame)
        self.sendBackgroundView.update(size: sendFrame.size, cornerRadius: 20.0, isDark: self.theme.overallDarkAppearance, tintColor: GlassBackgroundView.TintColor(kind: .panel), isInteractive: true, transition: componentTransition)
        transition.updateFrame(node: self.sendButton, frame: sendFrame)
        self.sendIconNode.frame = CGRect(origin: CGPoint(), size: sendFrame.size)

        return fieldHeight
    }
}
