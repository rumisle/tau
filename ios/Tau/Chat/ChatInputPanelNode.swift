import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AppBundle
import ComponentFlow
import ComponentDisplayAdapters
import GlassBackgroundComponent
import AudioBlob

/// The composer, laid out like Telegram's iOS 26 ChatTextInputPanelNode with the text in it: an attachment button
/// (Telegram's paperclip) and the growing text field, as glass in one GlassBackgroundContainerView so iOS merges and
/// morphs them. The field has the microphone at its end, where Telegram keeps the sticker button, always in its place;
/// and after it, the field's action button, as Telegram's `sendActionButtons`: Send once there is text, Stop while the
/// agent works on an empty field, and while dictating, the listening button. The button comes in with Telegram's scale,
/// fade and blur (`updateActionButtons`), and the microphone moves aside for it as Telegram's accessory buttons do.
/// Editing a message, or messages queued for the agent, add Telegram's accessory panel at the top of the field
/// (InputAccessoryPanelView).
final class ChatInputPanelNode: ASDisplayNode, UITextViewDelegate {
    private var theme: TauTheme
    private let glassContainer: GlassBackgroundContainerView
    private let attachBackgroundView: GlassBackgroundView
    private let attachIconView: UIImageView
    private let fieldBackgroundView: GlassBackgroundView
    private let textView: UITextView
    private let placeholderLabel: UILabel
    private let accessoryView: InputAccessoryPanelView
    /// Dictation, at the field's end: tapped, it listens until tapped again (on the listening button); held, while the
    /// finger is down, as Telegram's hold-to-record.
    private let micButton = UIView()
    private let micIconView = UIImageView()

    /// The field's action button, over the field's end: outside the field's glass, so the listening blob is not clipped.
    private let actionView = UIView()
    private let actionFillView = UIImageView()
    private let sendIconView = UIImageView()
    private let stopIconView = UIImageView()
    private let listenIconView = UIImageView()
    /// Telegram's recording blob (AudioBlob's VoiceBlobView, as ChatTextInputMediaRecordingButton sets it up), behind
    /// the listening button's disc, moving with the microphone's level.
    private var blobView: VoiceBlobView?

    private var dictationEngine: DictationEngine?
    private let dictationDisposable = MetaDisposable()
    /// Where the words being heard are in the text, replaced as they change.
    private var dictationRange: NSRange?
    /// The space put before a stretch, kept as its words change.
    private var dictationLead = ""
    private(set) var isDictating = false
    /// Asked to stop: the microphone is off and the last words are on their way.
    private var isFinishingDictation = false

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
    /// Dictation could not listen: what to tell the user.
    var dictationFailed: ((String) -> Void)?

    /// The agent is working: the empty field's action is Stop.
    var isBusy: Bool = false {
        didSet {
            if self.isBusy != oldValue {
                self.requestLayout?(.animated(duration: 0.4, curve: .spring))
            }
        }
    }
    var cancelEditing: (() -> Void)?
    /// After every change to the text, typed or set.
    var textChanged: ((String) -> Void)?
    /// The text changed height, the action button changed, or editing began; the owner lays out again.
    var requestLayout: ((ContainedViewLayoutTransition) -> Void)?

    private var currentTextHeight: CGFloat = 0.0
    private enum Action {
        case send
        case stop
        case listening
    }
    private var action: Action?
    /// The first layout puts the button in place without animating it in.
    private var hasLaidOut = false
    private var validWidth: CGFloat?
    private(set) var editingText: String?
    private(set) var queue: [QueuedMessage] = []

    /// The accessory panel shows the message being edited, else the first queued one.
    private var showsAccessory: Bool {
        return self.editingText != nil || !self.queue.isEmpty
    }

    // Telegram ChatTextInputPanelNode: 40 pt controls, 6 pt between glass shapes; the send button is a 34 pt disc in
    // a 40 pt box at the field's end (ChatTextInputActionButtonsNode insets it 3 pt).
    private static let controlSize: CGFloat = 40.0
    private static let spacing: CGFloat = 6.0
    private static let actionDiameter: CGFloat = 34.0
    /// The microphone's width in the field, as Telegram's accessory buttons.
    private static let micWidth: CGFloat = 34.0
    private static let fieldMaxLines: CGFloat = 6.0
    private static let font = Font.regular(17.0)
    private static let textInsets = UIEdgeInsets(top: 10.0, left: 16.0, bottom: 10.0, right: 4.0)
    /// ChatInputMessageAccessoryPanel's height.
    private static let accessoryHeight: CGFloat = 52.0
    /// The blob's box around the 34 pt button: its smallest blob, the button's own disc, is about half of it.
    private static let blobSize: CGFloat = 68.0

    init(theme: TauTheme) {
        self.theme = theme
        self.glassContainer = GlassBackgroundContainerView(spacing: 7.0)
        self.attachBackgroundView = GlassBackgroundView()
        self.fieldBackgroundView = GlassBackgroundView()
        self.attachIconView = UIImageView()
        self.attachIconView.contentMode = .center
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

    deinit {
        self.dictationDisposable.dispose()
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

        self.micIconView.contentMode = .center
        self.micIconView.isUserInteractionEnabled = false
        self.micButton.addSubview(self.micIconView)
        self.micButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.micTapped)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(self.micHeld(_:)))
        hold.minimumPressDuration = 0.25
        self.micButton.addGestureRecognizer(hold)
        self.fieldBackgroundView.contentView.addSubview(self.micButton)

        for view in [self.actionFillView, self.sendIconView, self.stopIconView, self.listenIconView] {
            view.contentMode = .center
            view.isUserInteractionEnabled = false
            self.actionView.addSubview(view)
        }
        self.actionView.alpha = 0.0
        self.actionView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.actionTapped)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.actionLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        self.actionView.addGestureRecognizer(longPress)
        self.view.addSubview(self.actionView)

        self.textView.delegate = self
        self.attachBackgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.attachTapped)))
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
        self.accessoryView.alpha = 0.0
        for (view, identifier, label) in [(self.attachBackgroundView, "attach", "Attach"), (self.micButton, "microphone", "Dictate"), (self.actionView, "send", "Send")] as [(UIView, String, String)] {
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = identifier
            view.accessibilityLabel = label
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
        let diameter = ChatInputPanelNode.actionDiameter
        self.actionFillView.image = generateFilledCircleImage(diameter: diameter, color: chat.actionControlFillColor)
        self.sendIconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/SendIcon"), color: chat.actionControlForegroundColor)
        self.stopIconView.image = generateImage(CGSize(width: 12.0, height: 12.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(chat.actionControlForegroundColor.cgColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: 2.5).cgPath)
            context.fillPath()
        })
        // The microphone, smaller, on the disc: what listens.
        if let mic = UIImage(bundleImageName: "Chat/Input/Text/IconMicrophone") {
            let size = CGSize(width: floor(mic.size.width * 0.8), height: floor(mic.size.height * 0.8))
            self.listenIconView.image = generateImage(size, contextGenerator: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                if let cgImage = mic.cgImage {
                    context.clip(to: CGRect(origin: CGPoint(), size: size), mask: cgImage)
                    context.setFillColor(chat.actionControlForegroundColor.cgColor)
                    context.fill(CGRect(origin: CGPoint(), size: size))
                }
            })
        }
        self.blobView?.setColor(chat.actionControlFillColor)
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
        self.cancelDictation()
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

    // MARK: - Buttons

    @objc private func actionTapped() {
        switch self.action {
        case .send:
            self.sendPressed()
        case .stop:
            self.stopPressed?()
        case .listening:
            self.stopDictation()
        case .none:
            break
        }
    }

    @objc private func actionLongPress(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began, self.action == .send {
            self.sendLongPressed?(self.actionView)
        }
    }

    @objc private func attachTapped() {
        self.attachPressed?()
    }

    @objc private func micTapped() {
        if self.isDictating {
            self.stopDictation()
        } else {
            self.startDictation()
        }
    }

    @objc private func micHeld(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            if !self.isDictating {
                self.startDictation()
            }
        case .ended, .cancelled, .failed:
            self.stopDictation()
        default:
            break
        }
    }

    // MARK: - Dictation

    /// What is heard goes in at the cursor (at the end when the field is not being edited); the field keeps whatever
    /// else is in it.
    func startDictation() {
        guard !self.isDictating else {
            return
        }
        let engine = self.dictationEngine ?? makeDictationEngine()
        self.dictationEngine = engine
        self.isDictating = true
        self.isFinishingDictation = false
        self.dictationRange = nil
        self.micPressed?()
        self.updateBlob()
        self.dictationDisposable.set((engine.start() |> deliverOnMainQueue).start(next: { [weak self] event in
            self?.apply(event)
        }, completed: { [weak self] in
            self?.finishDictation()
        }))
        self.requestLayout?(.animated(duration: 0.4, curve: .spring))
    }

    /// Stops listening; the last words still come, then dictation ends.
    func stopDictation() {
        guard self.isDictating, !self.isFinishingDictation else {
            return
        }
        self.isFinishingDictation = true
        self.updateBlob()
        self.dictationEngine?.stop()
        self.requestLayout?(.animated(duration: 0.3, curve: .easeInOut))
    }

    /// Ends dictation now, keeping the text as it is: the field is being sent or replaced.
    private func cancelDictation() {
        guard self.isDictating else {
            return
        }
        self.dictationDisposable.set(nil)
        self.finishDictation()
    }

    private func finishDictation() {
        guard self.isDictating else {
            return
        }
        self.isDictating = false
        self.isFinishingDictation = false
        self.dictationDisposable.set(nil)
        self.dictationRange = nil
        self.updateBlob()
        self.requestLayout?(.animated(duration: 0.4, curve: .spring))
    }

    private func updateBlob() {
        let listening = self.isDictating && !self.isFinishingDictation
        if listening {
            let blob: VoiceBlobView
            if let current = self.blobView {
                blob = current
            } else {
                // ChatTextInputMediaRecordingButton's blob.
                blob = VoiceBlobView(frame: CGRect(origin: CGPoint(), size: CGSize(width: ChatInputPanelNode.blobSize, height: ChatInputPanelNode.blobSize)), maxLevel: 4.0, smallBlobRange: (0.45, 0.55), mediumBlobRange: (0.52, 0.87), bigBlobRange: (0.57, 1.0))
                blob.isUserInteractionEnabled = false
                blob.setColor(self.theme.chat.actionControlFillColor)
                self.actionView.insertSubview(blob, at: 0)
                self.blobView = blob
            }
            self.layoutActionContents()
            blob.startAnimating()
        } else {
            self.blobView?.updateLevel(0.0)
            self.blobView?.stopAnimating()
        }
    }

    private func apply(_ event: DictationEvent) {
        let text: String
        switch event {
        case let .level(level):
            self.blobView?.updateLevel(CGFloat(level) * 4.0)
            return
        case let .failed(message):
            self.dictationFailed?(message)
            return
        case let .partial(value):
            text = value
        case let .final(value):
            text = value
        }
        let isFinal: Bool
        if case .final = event {
            isFinal = true
        } else {
            isFinal = false
        }
        let storage = self.textView.textStorage
        // The first words of a stretch go where the cursor is, a space apart from what is before them.
        let range: NSRange
        if let current = self.dictationRange, current.upperBound <= storage.length {
            range = current
        } else {
            let cursor = self.textView.isFirstResponder ? self.textView.selectedRange.location : storage.length
            range = NSRange(location: min(cursor, storage.length), length: 0)
            let before = range.location > 0 ? (storage.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) : ""
            self.dictationLead = (before.isEmpty || before == " " || before == "\n") ? "" : " "
        }
        let value = text.isEmpty ? "" : self.dictationLead + text
        let attributes: [NSAttributedString.Key: Any] = [.font: ChatInputPanelNode.font, .foregroundColor: self.theme.chat.inputTextColor]
        storage.replaceCharacters(in: range, with: NSAttributedString(string: value, attributes: attributes))
        let newRange = NSRange(location: range.location, length: (value as NSString).length)
        self.textView.typingAttributes = attributes
        self.dictationRange = isFinal ? nil : newRange
        if self.textView.isFirstResponder {
            self.textView.selectedRange = NSRange(location: newRange.upperBound, length: 0)
        }
        self.textViewDidChange(self.textView)
    }

    private func sendPressed() {
        // While dictating, what has been heard is sent; the rest is not waited for.
        self.cancelDictation()
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
        guard let width = self.validWidth else {
            return
        }
        if self.currentAction() != self.action || self.measureTextHeight(width: width) != self.currentTextHeight {
            self.requestLayout?(.animated(duration: 0.4, curve: .spring))
        }
    }

    // MARK: - Layout

    private func currentAction() -> Action? {
        if self.isDictating {
            return .listening
        }
        if !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .send
        }
        return self.isBusy ? .stop : nil
    }

    private func fieldWidth(_ width: CGFloat) -> CGFloat {
        return width - ChatInputPanelNode.controlSize - ChatInputPanelNode.spacing
    }

    /// The field's end that the text keeps clear of: the microphone, and the action button when there is one.
    private func fieldTrailing(action: Action?) -> CGFloat {
        return ChatInputPanelNode.micWidth + (action == nil ? 6.0 : ChatInputPanelNode.controlSize)
    }

    private func measureTextHeight(width: CGFloat) -> CGFloat {
        let insets = ChatInputPanelNode.textInsets
        let textWidth = self.fieldWidth(width) - insets.left - insets.right - self.fieldTrailing(action: self.currentAction())
        let maxHeight = ceil(ChatInputPanelNode.font.lineHeight * ChatInputPanelNode.fieldMaxLines)
        let text = self.text.isEmpty ? " " : self.text
        let bounds = (text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: ChatInputPanelNode.font], context: nil)
        return min(maxHeight, ceil(bounds.height))
    }

    /// The disc, its icons and the blob, centered in the action button.
    private func layoutActionContents() {
        let size = ChatInputPanelNode.controlSize
        let center = CGPoint(x: size / 2.0, y: size / 2.0)
        let diameter = ChatInputPanelNode.actionDiameter
        self.actionFillView.bounds = CGRect(origin: CGPoint(), size: CGSize(width: diameter, height: diameter))
        self.actionFillView.center = center
        for view in [self.sendIconView, self.stopIconView, self.listenIconView] {
            view.bounds = CGRect(origin: CGPoint(), size: CGSize(width: size, height: size))
            view.center = center
        }
        if let blob = self.blobView {
            blob.bounds = CGRect(origin: CGPoint(), size: CGSize(width: ChatInputPanelNode.blobSize, height: ChatInputPanelNode.blobSize))
            blob.center = center
        }
    }

    /// Lays the panel out in `width` and returns its height.
    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.validWidth = width
        let action = self.currentAction()
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
        componentTransition.setFrame(view: self.textView, frame: CGRect(origin: CGPoint(x: 0.0, y: accessoryHeight), size: CGSize(width: fieldFrame.width - self.fieldTrailing(action: action), height: textAreaHeight)))
        componentTransition.setFrame(view: self.placeholderLabel, frame: CGRect(origin: CGPoint(x: insets.left, y: accessoryHeight + insets.top), size: CGSize(width: fieldFrame.width - insets.left - self.fieldTrailing(action: action), height: ceil(ChatInputPanelNode.font.lineHeight))))

        // The microphone at the field's end, moved aside by the action button as Telegram's accessory buttons are by
        // Send; while dictating the listening button stands for it.
        let micFrame = CGRect(x: fieldFrame.width - (action == nil ? 4.0 : size) - ChatInputPanelNode.micWidth, y: fieldHeight - size, width: ChatInputPanelNode.micWidth, height: size)
        componentTransition.setFrame(view: self.micButton, frame: micFrame)
        self.micIconView.frame = CGRect(origin: CGPoint(), size: micFrame.size)
        let showsMic = action != .listening
        componentTransition.setAlpha(view: self.micButton, alpha: showsMic ? 1.0 : 0.0)
        componentTransition.setScale(view: self.micButton, scale: showsMic ? 1.0 : 0.6)
        self.micButton.isUserInteractionEnabled = showsMic
        self.micButton.accessibilityElementsHidden = !showsMic

        // The action button at the field's end. Hidden, it shrinks to the field's edge (Telegram's `sendActionsScale`
        // of 0.001, its frame moved right by about half its width).
        var actionFrame = CGRect(x: fieldFrame.maxX - size, y: controlsY, width: size, height: size)
        if action == nil {
            actionFrame.origin.x += (size - 6.0) * 0.5 - 3.0
        }
        transition.updatePosition(layer: self.actionView.layer, position: actionFrame.center)
        self.actionView.bounds = CGRect(origin: CGPoint(), size: actionFrame.size)
        transition.updateTransformScale(layer: self.actionView.layer, scale: action == nil ? 0.001 : 1.0)
        self.layoutActionContents()
        self.updateActionButton(action: action, previous: previousAction, transition: self.hasLaidOut ? transition : .immediate)
        self.hasLaidOut = true

        return panelSize.height
    }

    /// Telegram's `updateActionButtons`: the button fades and unblurs in, its send arrow coming from below-left, and
    /// blurs out; between kinds, the icons trade places with a scale, as its stop and microphone icons do.
    private func updateActionButton(action: Action?, previous: Action?, transition: ContainedViewLayoutTransition) {
        let animated = transition.isAnimated
        let alphaTransition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.2, curve: .easeInOut) : .immediate
        let blurTransition: ComponentTransition = animated ? .easeInOut(duration: 0.18) : .immediate
        let wasShown = previous != nil
        if let action {
            if !wasShown {
                alphaTransition.updateAlpha(layer: self.actionView.layer, alpha: 1.0)
                blurTransition.setBlur(layer: self.actionView.layer, radius: 0.0)
                if action == .send {
                    transition.animatePositionAdditive(layer: self.sendIconView.layer, offset: CGPoint(x: -22.0, y: 18.0))
                }
            }
        } else if wasShown {
            alphaTransition.updateAlpha(layer: self.actionView.layer, alpha: 0.0)
            blurTransition.setBlur(layer: self.actionView.layer, radius: 4.0)
        }
        // Hidden, the button keeps showing what it last was, so it leaves as it was.
        let shown = action ?? previous
        let icons: [(Action, UIView)] = [(.send, self.sendIconView), (.stop, self.stopIconView), (.listening, self.listenIconView)]
        let iconTransition: ContainedViewLayoutTransition = wasShown && animated ? .animated(duration: 0.3, curve: .spring) : .immediate
        for (kind, view) in icons {
            let visible = kind == shown
            iconTransition.updateAlpha(layer: view.layer, alpha: visible ? (kind == .listening && self.isFinishingDictation ? 0.5 : 1.0) : 0.0)
            iconTransition.updateTransformScale(layer: view.layer, scale: visible ? 1.0 : 0.001)
        }
        // The blob moves around the disc, as around Telegram's recording button.
        self.blobView?.isHidden = shown != .listening
        self.actionView.isUserInteractionEnabled = action != nil && !(action == .listening && self.isFinishingDictation)
        self.actionView.accessibilityElementsHidden = action == nil
        switch action {
        case .send:
            self.actionView.accessibilityIdentifier = "send"
            self.actionView.accessibilityLabel = "Send"
        case .stop:
            self.actionView.accessibilityIdentifier = "stop"
            self.actionView.accessibilityLabel = "Stop"
        case .listening:
            self.actionView.accessibilityIdentifier = "stopDictation"
            self.actionView.accessibilityLabel = "Stop Dictation"
        case .none:
            break
        }
    }
}
