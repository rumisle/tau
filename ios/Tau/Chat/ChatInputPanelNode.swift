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
/// morphs them. At the field's end:
///
/// - the microphone, where Telegram keeps the sticker button (an accessory button: 32 pt, 4 pt from the end). Tapped,
///   it listens until tapped again; held, while the finger is down. While it listens it is a disc in the accent color
///   with Telegram's recording blob around it, in its own place: nothing else moves.
/// - the action button after it, Telegram's `sendActionButtons`: a 40 by 34 pt capsule in a 46 by 40 pt box. Send once
///   there is text, Stop while the agent works on an empty field. It comes in with Telegram's scale, fade and blur
///   (`updateActionButtons`), and the microphone moves aside for it as Telegram's accessory buttons do.
///
/// Editing a message, or messages queued for the agent, add Telegram's accessory panel at the top of the field
/// (InputAccessoryPanelView).
final class ChatInputPanelNode: ASDisplayNode, UITextViewDelegate {
    private var theme: TauTheme
    private let glassContainer: GlassBackgroundContainerView
    private let attachBackgroundView: GlassBackgroundView
    private let attachIconView: UIImageView
    private let fieldBackgroundView: GlassBackgroundView
    private let textView: UITextView
    /// Its quotes (docs/quotes.md).
    private let quotes: InputQuotes
    private let placeholderLabel: UILabel
    private let accessoryView: InputAccessoryPanelView
    private let micButton = UIView()
    private let micIconView = UIImageView()

    /// The microphone while it listens, over its place but outside the field's glass, so the blob is not clipped: the
    /// accent disc, the microphone on it, and Telegram's recording blob (AudioBlob's VoiceBlobView, as
    /// ChatTextInputMediaRecordingButton sets it up) behind, moving with the level.
    private let listenView = UIView()
    private let listenDiscView = UIImageView()
    private let listenIconView = UIImageView()
    private var blobView: VoiceBlobView?

    /// The field's action button, over the field's end.
    private let actionView = UIView()
    private let actionFillView = UIImageView()
    private let sendIconView = UIImageView()
    private let stopIconView = UIImageView()

    private var dictationEngine: DictationEngine?
    private let dictationDisposable = MetaDisposable()
    /// Where the words being heard are in the text, replaced as they change, and what was put there last.
    private var dictationRange: NSRange?
    private var dictationInserted = ""
    /// The space put before a stretch, kept as its words change.
    private var dictationLead = ""
    /// Listening: the microphone is on.
    private(set) var isDictating = false
    /// Stopped, with the last words still on their way: they replace what was heard if it is still as it was.
    private var isAwaitingFinal = false

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
    }
    private var action: Action?
    /// The first layout puts everything in place without animating it in.
    private var hasLaidOut = false
    private var validWidth: CGFloat?
    private(set) var editingText: String?
    private(set) var queue: [QueuedMessage] = []

    /// A tau link written in the field, as Telegram previews a link in its accessory panel (docs/links.md).
    private(set) var linkPreview: LinkReference?
    /// Its ✕: the panel goes for that link.
    var linkPreviewClosed: ((LinkReference) -> Void)?

    /// The accessory panel shows the message being edited, else the first queued one, else a link's preview.
    private var showsAccessory: Bool {
        return self.editingText != nil || !self.queue.isEmpty || self.linkPreview != nil
    }

    // Telegram ChatTextInputPanelNode: 40 pt controls, 6 pt between glass shapes.
    private static let controlSize: CGFloat = 40.0
    private static let spacing: CGFloat = 6.0
    /// ChatTextInputActionButtonsNode: a box 46 pt wide (40 + 3 * 2), the capsule inset 3 pt in it.
    private static let actionBoxWidth: CGFloat = 46.0
    private static let actionInset: CGFloat = 3.0
    /// Telegram's accessory buttons: 32 pt wide, the last 4 pt from the field's end.
    private static let micWidth: CGFloat = 32.0
    private static let accessoryInset: CGFloat = 4.0
    private static let listenDiameter: CGFloat = 32.0
    /// The blob's box: its smallest blob is about half of it, the size of the disc.
    private static let blobSize: CGFloat = 64.0
    private static let fieldMaxLines: CGFloat = 6.0
    /// The text's font, at the theme's text size (Telegram's input field follows `chatFontSize`).
    private var font: UIFont {
        return Font.regular(self.theme.fontSize)
    }
    private static let textInsets = UIEdgeInsets(top: 10.0, left: 16.0, bottom: 10.0, right: 4.0)
    /// ChatInputMessageAccessoryPanel's height.
    private static let accessoryHeight: CGFloat = 52.0

    init(theme: TauTheme) {
        self.theme = theme
        self.glassContainer = GlassBackgroundContainerView(spacing: 7.0)
        self.attachBackgroundView = GlassBackgroundView()
        self.fieldBackgroundView = GlassBackgroundView()
        self.attachIconView = UIImageView()
        self.attachIconView.contentMode = .center
        self.accessoryView = InputAccessoryPanelView()

        // TextKit 1, as Telegram's field: its quotes are drawn from the layout manager's lines.
        self.textView = UITextView(usingTextLayoutManager: false)
        self.textView.backgroundColor = .clear
        self.textView.font = Font.regular(theme.fontSize)
        self.textView.textContainerInset = ChatInputPanelNode.textInsets
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.isScrollEnabled = false
        self.textView.scrollsToTop = false

        self.quotes = InputQuotes(textView: self.textView, font: Font.regular(theme.fontSize), textColor: theme.chat.inputTextColor, accentColor: theme.accentColor)
        self.placeholderLabel = UILabel()
        self.placeholderLabel.font = Font.regular(theme.fontSize)
        self.placeholderLabel.text = "Message"
        self.placeholderLabel.lineBreakMode = .byTruncatingTail

        super.init()
    }

    deinit {
        self.dictationDisposable.dispose()
        if let observer = self.settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Settings > Dictation changed: the microphone shows only while a provider is on.
    private var settingsObserver: NSObjectProtocol?
    private var showsMic = DictationSettings.isEnabled

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

        for view in [self.actionFillView, self.sendIconView, self.stopIconView] {
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

        for view in [self.listenDiscView, self.listenIconView] {
            view.contentMode = .center
            view.isUserInteractionEnabled = false
            self.listenView.addSubview(view)
        }
        self.listenView.alpha = 0.0
        self.listenView.isUserInteractionEnabled = false
        self.listenView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.micTapped)))
        let listenHold = UILongPressGestureRecognizer(target: self, action: #selector(self.micHeld(_:)))
        listenHold.minimumPressDuration = 0.25
        self.listenView.addGestureRecognizer(listenHold)
        self.view.addSubview(self.listenView)

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
            } else if let preview = self.linkPreview {
                self.linkPreviewClosed?(preview)
            }
        }
        self.accessoryView.tapped = { [weak self] in
            guard let self, self.editingText == nil, !self.queue.isEmpty else {
                return
            }
            self.queueTapped?(self.accessoryView)
        }
        self.accessoryView.alpha = 0.0
        for (view, identifier, label) in [(self.attachBackgroundView, "attach", "Attach"), (self.micButton, "microphone", "Dictate"), (self.actionView, "send", "Send"), (self.listenView, "stopDictation", "Stop Dictation")] as [(UIView, String, String)] {
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = identifier
            view.accessibilityLabel = label
            view.accessibilityTraits = .button
        }
        self.listenView.accessibilityElementsHidden = true
        self.settingsObserver = NotificationCenter.default.addObserver(forName: DictationSettings.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else {
                return
            }
            let shows = DictationSettings.isEnabled
            // Another provider: the next dictation makes its engine.
            self.dictationEngine = nil
            if shows != self.showsMic {
                self.showsMic = shows
                if !shows {
                    self.cancelDictation()
                }
                self.requestLayout?(.immediate)
            }
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
        if self.textView.font?.pointSize != self.font.pointSize {
            self.textView.font = self.font
            self.placeholderLabel.font = self.font
            self.textView.typingAttributes[.font] = self.font
        }
        self.attachIconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/IconAttachment"), color: chat.panelControlColor)
        self.micIconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/IconMicrophone"), color: chat.panelControlColor)
        // ChatTextInputActionButtonsNode: a capsule whatever its frame, from a stretchable disc of its shorter side.
        let capsule = ChatInputPanelNode.controlSize - ChatInputPanelNode.actionInset * 2.0
        self.actionFillView.image = generateStretchableFilledCircleImage(diameter: capsule, color: chat.actionControlFillColor)
        self.actionFillView.contentMode = .scaleToFill
        self.sendIconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/SendIcon"), color: chat.actionControlForegroundColor)
        self.stopIconView.image = generateImage(CGSize(width: 12.0, height: 12.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(chat.actionControlForegroundColor.cgColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: 2.5).cgPath)
            context.fillPath()
        })
        self.listenDiscView.image = generateFilledCircleImage(diameter: ChatInputPanelNode.listenDiameter, color: chat.actionControlFillColor)
        // The microphone, smaller, on the disc.
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
        self.quotes.font = self.font
        self.quotes.textColor = chat.inputTextColor
        self.quotes.accentColor = self.theme.accentColor
        self.textView.typingAttributes = self.quotes.typingAttributes(at: self.textView.selectedRange.location)
        self.textView.keyboardAppearance = self.theme.overallDarkAppearance ? .dark : .default
        self.placeholderLabel.textColor = chat.inputPlaceholderColor
        self.updateAccessoryContent(animated: false)
    }

    /// The message the field's text makes: its quotes in their tags.
    var text: String {
        return InputQuotes.text(of: self.textView.textStorage)
    }

    func activateInput() {
        self.textView.becomeFirstResponder()
    }

    func deactivateInput() {
        self.textView.resignFirstResponder()
    }

    func setText(_ text: String) {
        self.cancelDictation()
        self.textView.attributedText = self.quotes.attributed(text)
        self.textView.typingAttributes = self.quotes.typingAttributes(at: self.textView.selectedRange.location)
        self.textViewDidChange(self.textView)
    }

    /// Quote on selected text (docs/quotes.md): it goes in where the cursor is, the keyboard up for the reply.
    func insertQuote(_ text: String) {
        self.cancelDictation()
        if !self.textView.isFirstResponder {
            self.textView.becomeFirstResponder()
        }
        self.quotes.insert(text)
        self.textViewDidChange(self.textView)
        self.textView.scrollRangeToVisible(self.textView.selectedRange)
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

    func setLinkPreview(_ preview: LinkReference?) {
        guard preview != self.linkPreview else {
            return
        }
        let hadAccessory = self.showsAccessory
        self.linkPreview = preview
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
        } else if let preview = self.linkPreview {
            self.accessoryView.update(content: InputAccessoryPanelView.Content(id: "link:" + preview.url, title: preview.title, text: preview.text, status: .none, count: 1), theme: theme, animated: animated)
        }
    }

    // MARK: - Buttons

    @objc private func actionTapped() {
        switch self.action {
        case .send:
            self.sendPressed()
        case .stop:
            self.stopPressed?()
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
        // The last words of a stretch stopped a moment ago are not waited for.
        self.dropDictation()
        guard let engine = self.dictationEngine ?? makeDictationEngine() else {
            return
        }
        self.dictationEngine = engine
        self.isDictating = true
        self.micPressed?()
        self.updateListening(animated: true)
        self.dictationDisposable.set((engine.start() |> deliverOnMainQueue).start(next: { [weak self] event in
            self?.apply(event)
        }, completed: { [weak self] in
            self?.dictationEnded()
        }))
    }

    /// Stops listening at once: the microphone is off and the button is the microphone again. The engine still sends
    /// the last words, which a second or so later replace what was heard, if it is still as it was.
    func stopDictation() {
        guard self.isDictating else {
            return
        }
        self.isDictating = false
        self.isAwaitingFinal = true
        self.dictationEngine?.stop()
        self.updateListening(animated: true)
    }

    /// Ends dictation now, keeping the text as it is: the field is being sent or replaced.
    private func cancelDictation() {
        let wasDictating = self.isDictating
        self.dropDictation()
        if wasDictating {
            self.updateListening(animated: true)
        }
    }

    private func dropDictation() {
        self.dictationDisposable.set(nil)
        self.isDictating = false
        self.isAwaitingFinal = false
        self.dictationRange = nil
    }

    private func dictationEnded() {
        let wasDictating = self.isDictating
        self.dropDictation()
        if wasDictating {
            self.updateListening(animated: true)
        }
    }

    /// The microphone, or in its place the disc and the blob.
    private func updateListening(animated: Bool) {
        let listening = self.isDictating
        if listening {
            if self.blobView == nil {
                // ChatTextInputMediaRecordingButton's blob.
                let blob = VoiceBlobView(frame: CGRect(origin: CGPoint(), size: CGSize(width: ChatInputPanelNode.blobSize, height: ChatInputPanelNode.blobSize)), maxLevel: 4.0, smallBlobRange: (0.45, 0.55), mediumBlobRange: (0.52, 0.87), bigBlobRange: (0.57, 1.0))
                blob.isUserInteractionEnabled = false
                blob.setColor(self.theme.chat.actionControlFillColor)
                self.listenView.insertSubview(blob, at: 0)
                self.blobView = blob
            }
            self.layoutListenContents()
            self.blobView?.startAnimating()
        } else {
            self.blobView?.updateLevel(0.0)
            self.blobView?.stopAnimating()
        }
        let transition: ContainedViewLayoutTransition = animated && self.hasLaidOut ? .animated(duration: 0.25, curve: .spring) : .immediate
        let fade: ContainedViewLayoutTransition = animated && self.hasLaidOut ? .animated(duration: 0.15, curve: .easeInOut) : .immediate
        fade.updateAlpha(layer: self.listenView.layer, alpha: listening ? 1.0 : 0.0)
        transition.updateTransformScale(layer: self.listenView.layer, scale: listening ? 1.0 : 0.5)
        fade.updateAlpha(layer: self.micIconView.layer, alpha: listening ? 0.0 : 1.0)
        transition.updateTransformScale(layer: self.micIconView.layer, scale: listening ? 0.5 : 1.0)
        self.listenView.isUserInteractionEnabled = listening
        self.listenView.accessibilityElementsHidden = !listening
        self.micButton.isUserInteractionEnabled = !listening && self.showsMic
        self.micButton.accessibilityElementsHidden = listening || !self.showsMic
    }

    private func layoutListenContents() {
        let box = ChatInputPanelNode.blobSize
        let center = CGPoint(x: box / 2.0, y: box / 2.0)
        let diameter = ChatInputPanelNode.listenDiameter
        self.listenDiscView.bounds = CGRect(origin: CGPoint(), size: CGSize(width: diameter, height: diameter))
        self.listenDiscView.center = center
        self.listenIconView.bounds = CGRect(origin: CGPoint(), size: CGSize(width: diameter, height: diameter))
        self.listenIconView.center = center
        if let blob = self.blobView {
            blob.bounds = CGRect(origin: CGPoint(), size: CGSize(width: box, height: box))
            blob.center = center
        }
    }

    private func apply(_ event: DictationEvent) {
        let text: String
        let isFinal: Bool
        switch event {
        case let .level(level):
            if self.isDictating {
                self.blobView?.updateLevel(CGFloat(level) * 4.0)
            }
            return
        case let .failed(message):
            self.dictationFailed?(message)
            return
        case let .partial(value):
            // After Stop only the final text counts.
            guard self.isDictating else {
                return
            }
            text = value
            isFinal = false
        case let .final(value):
            text = value
            isFinal = true
        }
        let storage = self.textView.textStorage
        let range: NSRange
        if let current = self.dictationRange {
            // The text heard so far must still be where it was, as it was: an edit meanwhile keeps the edit.
            guard current.upperBound <= storage.length, (storage.string as NSString).substring(with: current) == self.dictationInserted else {
                if !self.isDictating {
                    self.dropDictation()
                }
                self.dictationRange = nil
                return
            }
            range = current
        } else {
            guard self.isDictating || !isFinal || self.isAwaitingFinal else {
                return
            }
            // The first words of a stretch go where the cursor is, a space apart from what is before them.
            let cursor = self.textView.isFirstResponder ? self.textView.selectedRange.location : storage.length
            range = NSRange(location: min(cursor, storage.length), length: 0)
            let before = range.location > 0 ? (storage.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) : ""
            self.dictationLead = (before.isEmpty || before == " " || before == "\n") ? "" : " "
        }
        let value = text.isEmpty ? "" : self.dictationLead + text
        let attributes: [NSAttributedString.Key: Any] = [.font: self.font, .foregroundColor: self.theme.chat.inputTextColor]
        let selection = self.textView.selectedRange
        storage.replaceCharacters(in: range, with: NSAttributedString(string: value, attributes: attributes))
        let newRange = NSRange(location: range.location, length: (value as NSString).length)
        self.textView.typingAttributes = attributes
        if isFinal {
            self.dictationRange = nil
            self.dictationInserted = ""
            if !self.isDictating {
                self.isAwaitingFinal = false
            }
        } else {
            self.dictationRange = newRange
            self.dictationInserted = value
        }
        if self.textView.isFirstResponder {
            // The cursor follows the words while listening; after, it stays where the user put it.
            if self.isDictating || selection.location >= range.location {
                self.textView.selectedRange = NSRange(location: newRange.upperBound, length: 0)
            }
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
        self.textView.attributedText = NSAttributedString()
        self.textView.typingAttributes = self.quotes.baseAttributes
        self.textViewDidChange(self.textView)
    }

    /// What the empty field says: "Message Claude Opus 5.5", and "Steer Claude Opus 5.5" while the agent works.
    var placeholder: String = "Message" {
        didSet {
            if self.placeholder != oldValue {
                self.placeholderLabel.text = self.placeholder
            }
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // A backspace takes a quote whole from just after it.
        if let whole = self.quotes.deletion(for: range, replacement: text) {
            textView.textStorage.deleteCharacters(in: whole)
            textView.selectedRange = NSRange(location: whole.location, length: 0)
            self.textViewDidChange(textView)
            return false
        }
        return true
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView.markedTextRange == nil else {
            return
        }
        textView.typingAttributes = self.quotes.typingAttributes(at: textView.selectedRange.location)
    }

    func textViewDidChange(_ textView: UITextView) {
        // Not while a character is being composed (Chinese, Japanese): restyling would end it.
        if textView.markedTextRange == nil {
            InputQuotes.restyle(textView.textStorage)
        }
        self.quotes.updateDecorations()
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
        if !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .send
        }
        return self.isBusy ? .stop : nil
    }

    private func fieldWidth(_ width: CGFloat) -> CGFloat {
        return width - ChatInputPanelNode.controlSize - ChatInputPanelNode.spacing
    }

    /// Where the microphone's right edge is from the field's end: after the action button, or 4 pt from the end.
    private func micTrailing(action: Action?) -> CGFloat {
        return action == nil ? ChatInputPanelNode.accessoryInset : ChatInputPanelNode.actionBoxWidth
    }

    /// The field's end that the text keeps clear of: the microphone, when dictation is on, and the action button.
    private func fieldTrailing(action: Action?) -> CGFloat {
        return self.micTrailing(action: action) + (self.showsMic ? ChatInputPanelNode.micWidth : 12.0)
    }

    private func measureTextHeight(width: CGFloat) -> CGFloat {
        let insets = ChatInputPanelNode.textInsets
        let textWidth = self.fieldWidth(width) - insets.left - insets.right - self.fieldTrailing(action: self.currentAction())
        let maxHeight = ceil(self.font.lineHeight * ChatInputPanelNode.fieldMaxLines)
        // As the field lays it out, quotes' indents and spacing in; a last line that is empty counts.
        let text = NSMutableAttributedString(attributedString: self.textView.textStorage)
        if text.length == 0 || text.string.hasSuffix("\n") {
            text.append(NSAttributedString(string: " ", attributes: self.quotes.baseAttributes))
        }
        let bounds = text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
        return min(maxHeight, ceil(bounds.height))
    }

    /// The capsule and its icons in the action button's box.
    private func layoutActionContents() {
        let box = CGSize(width: ChatInputPanelNode.actionBoxWidth, height: ChatInputPanelNode.controlSize)
        let center = CGPoint(x: box.width / 2.0, y: box.height / 2.0)
        let fill = CGRect(origin: CGPoint(), size: box).insetBy(dx: ChatInputPanelNode.actionInset, dy: ChatInputPanelNode.actionInset)
        self.actionFillView.bounds = CGRect(origin: CGPoint(), size: fill.size)
        self.actionFillView.center = center
        for view in [self.sendIconView, self.stopIconView] {
            view.bounds = CGRect(origin: CGPoint(), size: box)
            view.center = center
        }
    }

    /// Lays the panel out in `width` and returns its height.
    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.validWidth = width
        let transition = self.hasLaidOut ? transition : .immediate
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
        self.textView.isScrollEnabled = textHeight >= ceil(self.font.lineHeight * ChatInputPanelNode.fieldMaxLines)

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
        self.quotes.updateDecorations()
        componentTransition.setFrame(view: self.placeholderLabel, frame: CGRect(origin: CGPoint(x: insets.left, y: accessoryHeight + insets.top), size: CGSize(width: fieldFrame.width - insets.left - self.fieldTrailing(action: action), height: ceil(self.font.lineHeight))))

        // The microphone at the field's end, moved aside by the action button as Telegram's accessory buttons are by
        // Send. By position and bounds: its icon may be scaled, and a frame set through a transform lands elsewhere.
        let micFrame = CGRect(x: fieldFrame.width - self.micTrailing(action: action) - ChatInputPanelNode.micWidth, y: fieldHeight - size, width: ChatInputPanelNode.micWidth, height: size)
        transition.updatePosition(layer: self.micButton.layer, position: micFrame.center)
        transition.updateBounds(layer: self.micButton.layer, bounds: CGRect(origin: CGPoint(), size: micFrame.size))
        // Dictation off: no microphone at all.
        self.micButton.isHidden = !self.showsMic
        self.micButton.isUserInteractionEnabled = self.showsMic && !self.isDictating
        self.micButton.accessibilityElementsHidden = !self.showsMic || self.isDictating
        self.micIconView.bounds = CGRect(origin: CGPoint(), size: micFrame.size)
        self.micIconView.center = CGPoint(x: micFrame.width / 2.0, y: micFrame.height / 2.0)

        // Listening, the disc stands where the microphone is, and moves with it.
        let listenCenter = CGPoint(x: fieldFrame.minX + micFrame.midX, y: fieldFrame.minY + micFrame.midY)
        transition.updatePosition(layer: self.listenView.layer, position: listenCenter)
        self.listenView.bounds = CGRect(origin: CGPoint(), size: CGSize(width: ChatInputPanelNode.blobSize, height: ChatInputPanelNode.blobSize))
        self.layoutListenContents()

        // The action button at the field's end. Hidden, it shrinks to the field's edge (Telegram's `sendActionsScale`
        // of 0.001, its frame moved right by about half its width).
        let boxWidth = ChatInputPanelNode.actionBoxWidth
        var actionFrame = CGRect(x: fieldFrame.maxX - boxWidth, y: controlsY, width: boxWidth, height: size)
        if action == nil {
            actionFrame.origin.x += (boxWidth - ChatInputPanelNode.actionInset * 2.0) * 0.5 - ChatInputPanelNode.actionInset
        }
        transition.updatePosition(layer: self.actionView.layer, position: actionFrame.center)
        self.actionView.bounds = CGRect(origin: CGPoint(), size: actionFrame.size)
        transition.updateTransformScale(layer: self.actionView.layer, scale: action == nil ? 0.001 : 1.0)
        self.layoutActionContents()
        self.updateActionButton(action: action, previous: previousAction, transition: transition)
        if !self.hasLaidOut {
            self.hasLaidOut = true
            self.updateListening(animated: false)
        }

        return panelSize.height
    }

    /// Telegram's `updateActionButtons`: the button fades and unblurs in, its send arrow coming from below-left, and
    /// blurs out; between Send and Stop, the icons trade places with a scale, as its stop and microphone icons do.
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
        let iconTransition: ContainedViewLayoutTransition = wasShown && animated ? .animated(duration: 0.3, curve: .spring) : .immediate
        for (kind, view) in [(Action.send, self.sendIconView), (Action.stop, self.stopIconView)] {
            let visible = kind == shown
            iconTransition.updateAlpha(layer: view.layer, alpha: visible ? 1.0 : 0.0)
            iconTransition.updateTransformScale(layer: view.layer, scale: visible ? 1.0 : 0.001)
        }
        self.actionView.isUserInteractionEnabled = action != nil
        self.actionView.accessibilityElementsHidden = action == nil
        switch action {
        case .send:
            self.actionView.accessibilityIdentifier = "send"
            self.actionView.accessibilityLabel = "Send"
        case .stop:
            self.actionView.accessibilityIdentifier = "stop"
            self.actionView.accessibilityLabel = "Stop"
        case .none:
            break
        }
    }
}
