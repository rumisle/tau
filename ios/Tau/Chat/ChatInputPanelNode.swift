import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AppBundle
import ComponentFlow
import ComponentDisplayAdapters
import GlassBackgroundComponent

/// The composer, laid out like Telegram's iOS 26 ChatTextInputPanelNode: an attachment button (Telegram's paperclip),
/// a growing text field, and a microphone that turns into the send button once there is text. Every shape is glass inside
/// one GlassBackgroundContainerView, so iOS merges and morphs them. Editing a message, or messages queued for the agent,
/// add Telegram's accessory panel at the top of the field (InputAccessoryPanelView).
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
    private let accessoryView: InputAccessoryPanelView

    var sendMessage: ((String) -> Void)?
    /// A long press on Send, with the button to point a menu at.
    var sendLongPressed: ((UIView) -> Void)?
    /// The queue panel, tapped, with itself to point a menu at.
    var queueTapped: ((UIView) -> Void)?
    /// The queue panel's close button: withdraw the message it shows.
    var queueClosed: ((QueuedMessage) -> Void)?
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
    /// After every change to the text, typed or set.
    var textChanged: ((String) -> Void)?
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
    private(set) var queue: [QueuedMessage] = []

    /// The accessory panel shows the message being edited, else the first queued one.
    private var showsAccessory: Bool {
        return self.editingText != nil || !self.queue.isEmpty
    }

    // Telegram ChatTextInputPanelNode: 40 pt controls, 6 pt between glass shapes.
    private static let controlSize: CGFloat = 40.0
    private static let spacing: CGFloat = 6.0
    private static let fieldMaxLines: CGFloat = 6.0
    private static let font = Font.regular(17.0)
    private static let textInsets = UIEdgeInsets(top: 10.0, left: 16.0, bottom: 10.0, right: 16.0)
    /// ChatInputMessageAccessoryPanel's height.
    private static let accessoryHeight: CGFloat = 52.0

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
        self.accessoryView = InputAccessoryPanelView()

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
        content.addSubview(self.attachBackgroundView)
        self.attachBackgroundView.contentView.addSubview(self.attachIconView)
        content.addSubview(self.fieldBackgroundView)
        self.fieldBackgroundView.contentView.addSubview(self.placeholderLabel)
        self.fieldBackgroundView.contentView.addSubview(self.textView)
        // Inside the field's glass, above the text, where Telegram's iOS 26 input panel puts it.
        self.fieldBackgroundView.contentView.addSubview(self.accessoryView)
        self.fieldBackgroundView.contentView.clipsToBounds = true
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
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.sendLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        self.sendBackgroundView.addGestureRecognizer(longPress)
        self.accessoryView.close = { [weak self] in
            guard let self else {
                return
            }
            if self.editingText != nil {
                self.cancelEditing?()
            } else if let first = self.queue.first {
                self.queueClosed?(first)
            }
        }
        self.accessoryView.tapped = { [weak self] in
            guard let self, self.editingText == nil, !self.queue.isEmpty else {
                return
            }
            self.queueTapped?(self.accessoryView)
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
        self.updateAccessoryContent(animated: false)
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

    /// Show Telegram's "Edit Message" panel for `original`, or hide it with nil.
    func setEditing(_ original: String?) {
        self.editingText = original
        self.updateAccessoryContent(animated: true)
        self.requestLayout?(.animated(duration: 0.4, curve: .spring))
    }

    /// The messages waiting for the agent; the panel shows the first, which reaches it first.
    func setQueue(_ queue: [QueuedMessage]) {
        guard queue != self.queue else {
            return
        }
        let hadAccessory = self.showsAccessory
        self.queue = queue
        self.updateAccessoryContent(animated: true)
        if hadAccessory != self.showsAccessory {
            self.requestLayout?(.animated(duration: 0.4, curve: .spring))
        }
    }

    /// The accessory panel on screen, while it shows a queued message.
    func accessoryFrameInWindow() -> CGRect? {
        guard self.editingText == nil, !self.queue.isEmpty, self.isNodeLoaded else {
            return nil
        }
        return self.accessoryView.convert(self.accessoryView.bounds, to: nil)
    }

    /// A text to put back in the field: after what is there, a blank line between.
    func appendText(_ text: String) {
        let current = self.text
        self.setText(current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : current + "\n\n" + text)
    }

    private func updateAccessoryContent(animated: Bool) {
        let theme = self.theme.presentationTheme
        if let editing = self.editingText {
            self.accessoryView.update(content: InputAccessoryPanelView.Content(id: "edit", title: "Edit Message", text: editing, status: .none, count: 1), theme: theme, animated: animated)
        } else if let first = self.queue.first {
            let title: String
            var text = first.text
            if text.isEmpty {
                text = first.imageCount == 1 ? "Photo" : "\(first.imageCount) Photos"
            }
            switch first.mode {
            case .steer:
                title = "Steer"
            case .followUp:
                title = "Follow-up"
            case .newContext:
                title = "New Context"
                text = "The model forgets this chat"
            }
            let status: InputAccessoryPanelView.Status = first.mode == .newContext ? .none : (first.isSending ? .sending : .queued)
            self.accessoryView.update(content: InputAccessoryPanelView.Content(id: first.id, title: title, text: text, status: status, count: self.queue.count), theme: theme, animated: animated)
        }
    }

    @objc private func sendLongPress(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began, !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.sendLongPressed?(self.sendBackgroundView)
        }
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
        self.textChanged?(self.text)
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

        let accessoryHeight: CGFloat = self.showsAccessory ? ChatInputPanelNode.accessoryHeight : 0.0
        let textHeight = self.measureTextHeight(width: width)
        self.currentTextHeight = textHeight
        let textAreaHeight = max(size, textHeight + insets.top + insets.bottom)
        let fieldHeight = accessoryHeight + textAreaHeight
        self.textView.isScrollEnabled = textHeight >= ceil(ChatInputPanelNode.font.lineHeight * ChatInputPanelNode.fieldMaxLines)

        let panelSize = CGSize(width: width, height: fieldHeight)
        componentTransition.setFrame(view: self.glassContainer, frame: CGRect(origin: CGPoint(), size: panelSize))
        self.glassContainer.update(size: panelSize, isDark: isDark, transition: componentTransition)

        // The panel comes in from under the text as the field grows, as Telegram's does.
        let accessoryFrame = CGRect(x: 0.0, y: self.showsAccessory ? 0.0 : ChatInputPanelNode.accessoryHeight * 0.5, width: self.fieldWidth(width), height: ChatInputPanelNode.accessoryHeight)
        componentTransition.setFrame(view: self.accessoryView, frame: accessoryFrame)
        self.accessoryView.layout(size: accessoryFrame.size, transition: componentTransition)
        if self.showsAccessory {
            self.accessoryView.isHidden = false
        }
        componentTransition.setAlpha(view: self.accessoryView, alpha: self.showsAccessory ? 1.0 : 0.0, completion: { [weak self] _ in
            guard let self else {
                return
            }
            // Gone for accessibility too once faded out.
            self.accessoryView.isHidden = !self.showsAccessory
        })
        self.accessoryView.isUserInteractionEnabled = self.showsAccessory
        self.accessoryView.accessibilityElementsHidden = !self.showsAccessory

        // Controls stay on the last line as the field grows, as Telegram's do.
        let controlsY = fieldHeight - size
        let attachFrame = CGRect(origin: CGPoint(x: 0.0, y: controlsY), size: CGSize(width: size, height: size))
        componentTransition.setFrame(view: self.attachBackgroundView, frame: attachFrame)
        self.attachBackgroundView.update(size: attachFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: componentTransition)
        self.attachIconView.frame = CGRect(origin: CGPoint(), size: attachFrame.size)

        let fieldFrame = CGRect(origin: CGPoint(x: attachFrame.maxX + spacing, y: 0.0), size: CGSize(width: self.fieldWidth(width), height: fieldHeight))
        componentTransition.setFrame(view: self.fieldBackgroundView, frame: fieldFrame)
        self.fieldBackgroundView.update(size: fieldFrame.size, cornerRadius: size / 2.0, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: componentTransition)
        componentTransition.setFrame(view: self.textView, frame: CGRect(origin: CGPoint(x: 0.0, y: accessoryHeight), size: CGSize(width: fieldFrame.width, height: textAreaHeight)))
        componentTransition.setFrame(view: self.placeholderLabel, frame: CGRect(origin: CGPoint(x: insets.left, y: accessoryHeight + insets.top), size: CGSize(width: fieldFrame.width - insets.left - insets.right, height: ceil(ChatInputPanelNode.font.lineHeight))))

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
