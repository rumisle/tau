import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import GlassBackgroundComponent
import UniformTypeIdentifiers

final class ChatController: ViewController, UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let context: AppContext
    private let conversationId: Int
    private let isPreview: Bool
    private var theme: TauTheme
    private let stateDisposable = MetaDisposable()
    private var themeDisposable: Disposable?
    private let titleView: ChatTitleView
    private var editingMessageId: Int?
    private var lastState: ConversationState?

    private var controllerNode: ChatControllerNode {
        return self.displayNode as! ChatControllerNode
    }

    init(context: AppContext, conversationId: Int, isPreview: Bool = false) {
        self.context = context
        self.conversationId = conversationId
        self.isPreview = isPreview
        self.theme = context.theme
        self.titleView = ChatTitleView(theme: context.theme)

        // Telegram's chat screen uses the glass navigation bar.
        super.init(navigationBarPresentationData: isPreview ? nil : context.theme.navigationBarPresentationData())

        self.navigationItem.titleView = self.titleView
        self.updateTitle(busy: false)
        self.statusBar.statusBarStyle = self.theme.statusBarStyleValue
        self.themeDisposable = (context.themeContext.theme |> deliverOnMainQueue).start(next: { [weak self] theme in
            self?.updateTheme(theme)
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.stateDisposable.dispose()
        self.themeDisposable?.dispose()
    }

    private func updateTheme(_ theme: TauTheme) {
        guard theme !== self.theme else {
            return
        }
        self.theme = theme
        self.statusBar.statusBarStyle = theme.statusBarStyleValue
        self.navigationBar?.updatePresentationData(theme.navigationBarPresentationData(), transition: .immediate)
        self.titleView.updateTheme(theme)
        if self.isNodeLoaded {
            self.controllerNode.updateTheme(theme)
        }
    }

    private func updateTitle(busy: Bool) {
        if let ids = self.isNodeLoaded ? self.controllerNode.selectedIds : nil {
            self.titleView.update(title: ids.count == 1 ? "1 Selected" : "\(ids.count) Selected", subtitle: nil)
            return
        }
        guard let dialog = self.context.store.dialog(self.conversationId) else {
            return
        }
        self.titleView.update(title: dialog.title, subtitle: busy ? "working…" : "\(dialog.projectName) · \(dialog.model)", isActive: busy)
    }

    override func loadDisplayNode() {
        self.displayNode = ChatControllerNode(theme: self.theme, isPreview: self.isPreview)
        let node = self.controllerNode
        node.initialScrollState = self.context.store.scrollState(self.conversationId)
        node.sendMessage = { [weak self] text in
            self?.send(text: text, attachments: [])
        }
        node.messageAction = { [weak self] message, action in
            self?.perform(action, on: message)
        }
        node.selectionAction = { [weak self] action in
            self?.performOnSelection(action)
        }
        node.selectionChanged = { [weak self] ids in
            self?.selectionChanged(ids)
        }
        node.inputPanelNode.attachPressed = { [weak self] in
            self?.openAttachments()
        }
        node.inputPanelNode.micPressed = { [weak self] in
            self?.controllerNode.showToast("Voice input is coming soon")
        }
        node.inputPanelNode.cancelEditing = { [weak self] in
            self?.endEditing(clearText: true)
        }

        self.stateDisposable.set((self.context.store.conversationSignal(self.conversationId) |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            self.lastState = state
            self.controllerNode.update(state: state)
            self.updateTitle(busy: state.busy)
        }))
        self.displayNodeDidLoad()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !self.isPreview && self.isNodeLoaded {
            self.context.store.setScrollState(self.controllerNode.currentScrollState(), for: self.conversationId)
        }
    }

    func activateInput() {
        self.controllerNode.inputPanelNode.activateInput()
    }

    func setDraft(_ text: String) {
        self.controllerNode.inputPanelNode.setText(text)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let navigationHeight = self.isPreview ? 0.0 : self.navigationLayout(layout: layout).navigationFrame.maxY
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: transition)
    }

    // MARK: - Sending and editing

    private func send(text: String, attachments: [MessageAttachment]) {
        if let messageId = self.editingMessageId {
            self.context.store.edit(messageId: messageId, text: text, in: self.conversationId)
            self.endEditing(clearText: false)
        } else {
            self.context.store.send(text, attachments: attachments, to: self.conversationId)
        }
    }

    private func endEditing(clearText: Bool) {
        self.editingMessageId = nil
        self.controllerNode.inputPanelNode.setEditing(nil)
        if clearText {
            self.controllerNode.inputPanelNode.setText("")
        }
    }

    private func perform(_ action: ChatMessageAction, on message: ChatMessage) {
        switch action {
        case .copy:
            UIPasteboard.general.string = message.text
            self.controllerNode.showToast("Copied")
        case .edit:
            self.editingMessageId = message.id
            self.controllerNode.inputPanelNode.setEditing(message.text)
            self.controllerNode.inputPanelNode.setText(message.text)
            self.controllerNode.inputPanelNode.activateInput()
        case .select:
            self.controllerNode.inputPanelNode.deactivateInput()
            self.controllerNode.setSelection([message.id])
        case .delete:
            self.context.store.deleteMessages([message.id], in: self.conversationId)
        }
    }

    // MARK: - Selection mode

    private func selectionChanged(_ ids: Set<Int>?) {
        if ids != nil {
            self.navigationItem.setRightBarButton(UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(self.endSelection)), animated: true)
        } else {
            self.navigationItem.setRightBarButton(nil, animated: true)
        }
        self.updateTitle(busy: self.lastState?.busy ?? false)
    }

    @objc private func endSelection() {
        self.controllerNode.setSelection(nil)
    }

    private func performOnSelection(_ action: ChatMessageAction) {
        guard let ids = self.controllerNode.selectedIds, !ids.isEmpty, let messages = self.lastState?.messages else {
            return
        }
        let selected = messages.filter { ids.contains($0.id) }
        switch action {
        case .copy:
            UIPasteboard.general.string = selected.map(\.text).joined(separator: "\n\n")
            self.controllerNode.setSelection(nil)
            self.controllerNode.showToast(selected.count == 1 ? "Copied" : "Copied \(selected.count) messages")
        case .delete:
            self.controllerNode.setSelection(nil)
            self.context.store.deleteMessages(ids, in: self.conversationId)
        default:
            break
        }
    }

    // MARK: - Attachments

    private func openAttachments() {
        self.controllerNode.inputPanelNode.deactivateInput()
        let picker = AttachmentPickerController(theme: self.theme, completion: { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case let .images(images):
                guard !images.isEmpty else {
                    return
                }
                let attachments = images.map { MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .image($0)) }
                let caption = self.controllerNode.inputPanelNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.controllerNode.inputPanelNode.setText("")
                self.send(text: caption, attachments: attachments)
            case .file:
                let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                documentPicker.delegate = self
                self.present(documentPicker, animated: true)
            case .camera:
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    self.controllerNode.showToast("No camera on this device")
                    return
                }
                let camera = UIImagePickerController()
                camera.sourceType = .camera
                camera.delegate = self
                self.present(camera, animated: true)
            }
        })
        self.present(picker, in: .window(.root))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let attachments = urls.map { url -> MessageAttachment in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            return MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .file(name: url.lastPathComponent, size: size))
        }
        self.send(text: "", attachments: attachments)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage {
            self.send(text: "", attachments: [MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .image(image))])
        }
    }
}

/// Two-line chat title in a glass capsule, as Telegram's ChatTitleView draws it in the glass navigation bar: the
/// conversation, then its project and model, or what the agent is doing.
final class ChatTitleView: UIView {
    private var theme: TauTheme
    private let backgroundView = GlassBackgroundView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var isActive = false

    init(theme: TauTheme) {
        self.theme = theme
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 240.0, height: 44.0))
        self.titleLabel.font = Font.semibold(16.0)
        self.titleLabel.textAlignment = .center
        self.subtitleLabel.font = Font.regular(12.0)
        self.subtitleLabel.textAlignment = .center
        self.addSubview(self.backgroundView)
        self.backgroundView.contentView.addSubview(self.titleLabel)
        self.backgroundView.contentView.addSubview(self.subtitleLabel)
        self.applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        self.applyColors()
        self.setNeedsLayout()
    }

    private func applyColors() {
        self.titleLabel.textColor = self.theme.navigationBar.primaryTextColor
        self.subtitleLabel.textColor = self.isActive ? self.theme.accentColor : self.theme.navigationBar.secondaryTextColor
    }

    func update(title: String, subtitle: String?, isActive: Bool = false) {
        self.titleLabel.text = title
        self.subtitleLabel.text = subtitle
        self.subtitleLabel.isHidden = subtitle == nil
        self.isActive = isActive
        self.applyColors()
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxTextWidth = max(40.0, self.bounds.width - 24.0)
        let titleSize = self.titleLabel.sizeThatFits(CGSize(width: maxTextWidth, height: 22.0))
        let subtitleSize = self.subtitleLabel.isHidden ? .zero : self.subtitleLabel.sizeThatFits(CGSize(width: maxTextWidth, height: 16.0))
        let textWidth = min(maxTextWidth, ceil(max(titleSize.width, subtitleSize.width)))

        // Telegram ChatTitleView: a 44 pt capsule, 12 pt wider than the text on each side.
        let backgroundSize = CGSize(width: textWidth + 24.0, height: 44.0)
        let backgroundFrame = CGRect(origin: CGPoint(x: floor((self.bounds.width - backgroundSize.width) / 2.0), y: floor((self.bounds.height - backgroundSize.height) / 2.0)), size: backgroundSize)
        self.backgroundView.frame = backgroundFrame
        self.backgroundView.update(size: backgroundSize, cornerRadius: backgroundSize.height / 2.0, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
        if self.subtitleLabel.isHidden {
            self.titleLabel.frame = CGRect(x: 12.0, y: 11.0, width: textWidth, height: 22.0)
        } else {
            self.titleLabel.frame = CGRect(x: 12.0, y: 4.0, width: textWidth, height: 21.0)
            self.subtitleLabel.frame = CGRect(x: 12.0, y: 24.0, width: textWidth, height: 15.0)
        }
    }
}
