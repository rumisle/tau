// tau shim for Telegram's AttachmentTextInputPanelNode module. Telegram's is its full chat input (formatting, emoji,
// mentions, send options); tau's is the caption field of the attachment menu in the same glass shapes: a growing text
// field with a placeholder and a send button, with the members AttachmentPanel lays out and animates.
import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatPresentationInterfaceState
import GlassBackgroundComponent
import AppBundle

public final class AttachmentTextInputPanelNode: ASDisplayNode, UITextViewDelegate {
    public var isAIEnabled: Bool = false
    public var interfaceInteraction: ChatPanelInterfaceInteraction?
    public var sendMessage: ((AttachmentTextInputPanelSendMode, ChatSendMessageActionSheetController.SendParameters?) -> Void)?
    public var invokeAICompose: (() -> Void)?
    public var focusUpdated: ((Bool) -> Void)?
    public var updateHeight: ((Bool) -> Void)?
    /// The caption as typed; tau's addition, as the chat interaction that carried it is not here.
    public var textChanged: ((NSAttributedString) -> Void)?

    public var inputPanelBottomSpacing: CGFloat
    /// In Telegram, the height of an emoji or media input shown in place of the keyboard; tau shows none.
    public let additionalInputHeight: CGFloat = 0.0
    public let opaqueActionButtons = ASDisplayNode()
    public let inputModeView = UIView()
    public let textPlaceholderNode = ImmediateTextNode()

    private var theme: PresentationTheme
    private let glassContainer = GlassBackgroundContainerView(spacing: 7.0)
    private let fieldBackground = GlassBackgroundView()
    private let sendBackground = GlassBackgroundView()
    private let sendIcon = UIImageView()
    private let textView = UITextView()
    private static let font = Font.regular(17.0)
    private static let insets = UIEdgeInsets(top: 10.0, left: 16.0, bottom: 10.0, right: 16.0)

    public init(context: AccountContext, presentationInterfaceState: ChatPresentationInterfaceState, glass: Bool, isAttachment: Bool, isScheduledMessages: Bool, customEmojiAvailable: Bool, presentController: @escaping (ViewController) -> Void, presentInGlobalOverlay: @escaping (ViewController) -> Void, getNavigationController: @escaping () -> NavigationController?, inputPanelBottomSpacing: CGFloat?) {
        self.theme = presentationInterfaceState.theme
        self.inputPanelBottomSpacing = inputPanelBottomSpacing ?? 0.0
        super.init()
        self.textPlaceholderNode.attributedText = NSAttributedString(string: presentationInterfaceState.strings.MediaPicker_AddCaption, font: AttachmentTextInputPanelNode.font, textColor: self.theme.chat.inputPanel.inputPlaceholderColor)
        self.textPlaceholderNode.isUserInteractionEnabled = false
    }

    override public func didLoad() {
        super.didLoad()
        self.view.addSubview(self.glassContainer)
        self.glassContainer.isHidden = self.alpha < 0.01
        self.glassContainer.contentView.addSubview(self.fieldBackground)
        self.fieldBackground.contentView.addSubview(self.textView)
        self.fieldBackground.contentView.addSubview(self.textPlaceholderNode.view)
        self.glassContainer.contentView.addSubview(self.opaqueActionButtons.view)
        self.opaqueActionButtons.view.addSubview(self.sendBackground)
        self.sendBackground.contentView.addSubview(self.sendIcon)
        self.sendIcon.contentMode = .center
        self.sendBackground.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.sendTapped)))
        self.sendBackground.isAccessibilityElement = true
        self.sendBackground.accessibilityLabel = "Send"
        self.sendBackground.accessibilityIdentifier = "attachment-send"
        self.sendBackground.accessibilityTraits = .button

        self.textView.backgroundColor = .clear
        self.textView.font = AttachmentTextInputPanelNode.font
        self.textView.textContainerInset = AttachmentTextInputPanelNode.insets
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.isScrollEnabled = false
        self.textView.delegate = self
        self.applyTheme()
    }

    private func applyTheme() {
        let input = self.theme.chat.inputPanel
        self.textView.textColor = input.inputTextColor
        self.textView.tintColor = self.theme.list.itemAccentColor
        self.textView.keyboardAppearance = self.theme.overallDarkAppearance ? .dark : .default
        self.sendIcon.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/SendIcon"), color: input.actionControlForegroundColor)
    }

    public func updateInputTextState(_ state: ChatTextInputState, animated: Bool) {
        if !(self.textView.attributedText ?? NSAttributedString()).string.elementsEqual(state.inputText.string) {
            self.textView.text = state.inputText.string
            self.textPlaceholderNode.isHidden = !state.inputText.string.isEmpty
        }
    }

    public func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, keyboardHeight: CGFloat, additionalSideInsets: UIEdgeInsets, textFieldMaxHeight: CGFloat, availableHeight: CGFloat, isSecondary: Bool, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState, metrics: LayoutMetrics, isMediaInputExpanded: Bool) -> CGFloat {
        if interfaceState.theme !== self.theme {
            self.theme = interfaceState.theme
            if self.isNodeLoaded {
                self.applyTheme()
            }
        }
        let controlSize: CGFloat = 40.0
        let spacing: CGFloat = 6.0
        // Telegram's panel keeps 8 pt from the screen edges itself when the attachment panel gives it none (focused).
        let leftInset = max(leftInset, 8.0)
        let rightInset = max(rightInset, 8.0)
        let insets = AttachmentTextInputPanelNode.insets
        let fieldWidth = width - leftInset - rightInset - controlSize - spacing
        let textWidth = fieldWidth - insets.left - insets.right
        let text = self.textView.text.isEmpty ? " " : self.textView.text!
        let maxTextHeight = min(textFieldMaxHeight, ceil(AttachmentTextInputPanelNode.font.lineHeight * 5.0))
        let textHeight = min(maxTextHeight, ceil((text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: AttachmentTextInputPanelNode.font], context: nil).height))
        self.textView.isScrollEnabled = textHeight >= maxTextHeight
        let fieldHeight = max(controlSize, textHeight + insets.top + insets.bottom)

        let isDark = self.theme.overallDarkAppearance
        let componentTransition = ComponentTransition(transition)
        let panelSize = CGSize(width: width, height: fieldHeight)
        componentTransition.setFrame(view: self.glassContainer, frame: CGRect(origin: CGPoint(), size: panelSize))
        self.glassContainer.update(size: panelSize, isDark: isDark, transition: componentTransition)

        let fieldFrame = CGRect(x: leftInset, y: 0.0, width: fieldWidth, height: fieldHeight)
        componentTransition.setFrame(view: self.fieldBackground, frame: fieldFrame)
        self.fieldBackground.update(size: fieldFrame.size, cornerRadius: controlSize / 2.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: componentTransition)
        componentTransition.setFrame(view: self.textView, frame: CGRect(origin: CGPoint(), size: fieldFrame.size))
        let placeholderSize = self.textPlaceholderNode.updateLayout(CGSize(width: textWidth, height: 30.0))
        self.textPlaceholderNode.frame = CGRect(origin: CGPoint(x: insets.left, y: insets.top), size: placeholderSize)

        let sendFrame = CGRect(x: width - rightInset - controlSize, y: fieldHeight - controlSize, width: controlSize, height: controlSize)
        transition.updateFrame(node: self.opaqueActionButtons, frame: sendFrame)
        self.sendBackground.frame = CGRect(origin: CGPoint(), size: sendFrame.size)
        self.sendBackground.update(size: sendFrame.size, cornerRadius: controlSize / 2.0, isDark: isDark, tintColor: .init(kind: .custom(style: .default, color: self.theme.chat.inputPanel.actionControlFillColor)), isInteractive: true, transition: componentTransition)
        self.sendIcon.frame = CGRect(origin: CGPoint(), size: sendFrame.size)

        return fieldHeight + self.inputPanelBottomSpacing
    }

    public func animateIn(transition: ContainedViewLayoutTransition) {
    }

    /// AttachmentPanel hides the panel by its alpha, which glass ignores: its send button showed past the sheet's corner
    /// while nothing was selected. Hidden with it, then.
    override public var alpha: CGFloat {
        get {
            return super.alpha
        }
        set {
            super.alpha = newValue
            if self.isNodeLoaded {
                self.glassContainer.isHidden = newValue < 0.01
            }
        }
    }

    public var isFocused: Bool {
        return self.textView.isFirstResponder
    }

    public func ensureUnfocused() {
        self.textView.resignFirstResponder()
    }

    @objc private func sendTapped() {
        self.textView.resignFirstResponder()
        self.sendMessage?(.generic, nil)
    }

    public func textViewDidChange(_ textView: UITextView) {
        self.textPlaceholderNode.isHidden = !textView.text.isEmpty
        self.textChanged?(NSAttributedString(string: textView.text ?? ""))
        self.updateHeight?(false)
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        self.focusUpdated?(true)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        self.focusUpdated?(false)
    }
}
