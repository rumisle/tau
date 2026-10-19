import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import ComponentDisplayAdapters
import GlassBackgroundComponent

/// The composer, laid out like Telegram's iOS 26 ChatTextInputPanelNode: an attachment button, a growing text field and
/// a send button, each a glass shape inside one GlassBackgroundContainerView, so iOS merges and morphs them as liquid
/// glass. The send button appears once there is text, and the field gives up its space to it.
final class ChatInputPanelNode: ASDisplayNode, UITextViewDelegate {
    private let theme: TauTheme
    private let glassContainer: GlassBackgroundContainerView
    private let attachBackgroundView: GlassBackgroundView
    private let attachIconView: UIImageView
    private let fieldBackgroundView: GlassBackgroundView
    private let textView: UITextView
    private let placeholderLabel: UILabel
    private let sendBackgroundView: GlassBackgroundView
    private let sendIconView: UIImageView

    var sendMessage: ((String) -> Void)?
    /// The text changed height, or the send button appeared; the owner lays out again with this transition.
    var requestLayout: ((ContainedViewLayoutTransition) -> Void)?

    private var currentTextHeight: CGFloat = 0.0
    private var displaysSend = false
    private var validWidth: CGFloat?

    // Telegram ChatTextInputPanelNode: 40 pt controls, 6 pt between glass shapes.
    private static let controlSize: CGFloat = 40.0
    private static let spacing: CGFloat = 6.0
    private static let fieldMaxLines: CGFloat = 6.0
    private static let font = Font.regular(17.0)
    private static let textInsets = UIEdgeInsets(top: 10.0, left: 16.0, bottom: 10.0, right: 16.0)

    init(theme: TauTheme) {
        self.theme = theme
        self.glassContainer = GlassBackgroundContainerView(spacing: 7.0)
        self.attachBackgroundView = GlassBackgroundView()
        self.fieldBackgroundView = GlassBackgroundView()
        self.sendBackgroundView = GlassBackgroundView()

        self.attachIconView = UIImageView(image: UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19.0, weight: .medium)))
        self.attachIconView.tintColor = theme.chat.inputPanelControlColor
        self.attachIconView.contentMode = .center

        self.sendIconView = UIImageView(image: UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .bold)))
        self.sendIconView.tintColor = theme.chat.actionControlForegroundColor
        self.sendIconView.contentMode = .center

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

        super.init()
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.glassContainer)
        let content = self.glassContainer.contentView
        content.addSubview(self.attachBackgroundView)
        self.attachBackgroundView.contentView.addSubview(self.attachIconView)
        content.addSubview(self.fieldBackgroundView)
        self.fieldBackgroundView.contentView.addSubview(self.placeholderLabel)
        self.fieldBackgroundView.contentView.addSubview(self.textView)
        content.addSubview(self.sendBackgroundView)
        self.sendBackgroundView.contentView.addSubview(self.sendIconView)

        self.textView.delegate = self
        self.sendBackgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.sendPressed)))
        self.sendBackgroundView.alpha = 0.0
    }

    var text: String {
        return self.textView.text ?? ""
    }

    func activateInput() {
        self.textView.becomeFirstResponder()
    }

    func setText(_ text: String) {
        self.textView.text = text
        self.textViewDidChange(self.textView)
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
        let displaysSend = !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let width = self.validWidth else {
            return
        }
        if displaysSend != self.displaysSend || self.measureTextHeight(width: width, displaysSend: displaysSend) != self.currentTextHeight {
            self.requestLayout?(.animated(duration: 0.4, curve: .spring))
        }
    }

    private func fieldWidth(_ width: CGFloat, displaysSend: Bool) -> CGFloat {
        let size = ChatInputPanelNode.controlSize
        let spacing = ChatInputPanelNode.spacing
        return width - size - spacing - (displaysSend ? size + spacing : 0.0)
    }

    private func measureTextHeight(width: CGFloat, displaysSend: Bool) -> CGFloat {
        let insets = ChatInputPanelNode.textInsets
        let textWidth = self.fieldWidth(width, displaysSend: displaysSend) - insets.left - insets.right
        let maxHeight = ceil(ChatInputPanelNode.font.lineHeight * ChatInputPanelNode.fieldMaxLines)
        let text = self.text.isEmpty ? " " : self.text
        let bounds = (text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: ChatInputPanelNode.font], context: nil)
        return min(maxHeight, ceil(bounds.height))
    }

    /// Lays the panel out in `width` and returns its height.
    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.validWidth = width
        let displaysSend = !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.displaysSend = displaysSend
        let size = ChatInputPanelNode.controlSize
        let spacing = ChatInputPanelNode.spacing
        let insets = ChatInputPanelNode.textInsets
        let isDark = self.theme.overallDarkAppearance

        let textHeight = self.measureTextHeight(width: width, displaysSend: displaysSend)
        self.currentTextHeight = textHeight
        let fieldHeight = max(size, textHeight + insets.top + insets.bottom)
        self.textView.isScrollEnabled = textHeight >= ceil(ChatInputPanelNode.font.lineHeight * ChatInputPanelNode.fieldMaxLines)

        let componentTransition = ComponentTransition(transition)
        let panelSize = CGSize(width: width, height: fieldHeight)
        componentTransition.setFrame(view: self.glassContainer, frame: CGRect(origin: CGPoint(), size: panelSize))
        self.glassContainer.update(size: panelSize, isDark: isDark, transition: componentTransition)

        // Controls stay on the last line as the field grows, as Telegram's do.
        let attachFrame = CGRect(origin: CGPoint(x: 0.0, y: fieldHeight - size), size: CGSize(width: size, height: size))
        componentTransition.setFrame(view: self.attachBackgroundView, frame: attachFrame)
        self.attachBackgroundView.update(size: attachFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: componentTransition)
        self.attachIconView.frame = CGRect(origin: CGPoint(), size: attachFrame.size)

        let fieldFrame = CGRect(origin: CGPoint(x: attachFrame.maxX + spacing, y: 0.0), size: CGSize(width: self.fieldWidth(width, displaysSend: displaysSend), height: fieldHeight))
        componentTransition.setFrame(view: self.fieldBackgroundView, frame: fieldFrame)
        self.fieldBackgroundView.update(size: fieldFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: componentTransition)
        componentTransition.setFrame(view: self.textView, frame: CGRect(origin: CGPoint(), size: fieldFrame.size))
        self.placeholderLabel.frame = CGRect(origin: CGPoint(x: insets.left, y: insets.top), size: CGSize(width: fieldFrame.width - insets.left - insets.right, height: ceil(ChatInputPanelNode.font.lineHeight)))

        // The send button grows out of the field's trailing end.
        let sendFrame = CGRect(origin: CGPoint(x: displaysSend ? width - size : fieldFrame.maxX - size, y: fieldHeight - size), size: CGSize(width: size, height: size))
        // Position and bounds, not frame: the view is also scaled.
        componentTransition.setPosition(view: self.sendBackgroundView, position: sendFrame.center)
        componentTransition.setBounds(view: self.sendBackgroundView, bounds: CGRect(origin: CGPoint(), size: sendFrame.size))
        self.sendBackgroundView.update(size: sendFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .custom(style: .default, color: self.theme.chat.actionControlFillColor)), isInteractive: true, transition: componentTransition)
        componentTransition.setAlpha(view: self.sendBackgroundView, alpha: displaysSend ? 1.0 : 0.0)
        componentTransition.setScale(view: self.sendBackgroundView, scale: displaysSend ? 1.0 : 0.6)
        self.sendIconView.frame = CGRect(origin: CGPoint(), size: sendFrame.size)

        return fieldHeight
    }
}
