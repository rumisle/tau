import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import GlassBackgroundComponent
import UniformTypeIdentifiers
import ComponentFlow
import AnimatedTextComponent
import ChatTitleActivityNode
import ContextUI
import TelegramPresentationData

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
    /// In a preview, a tap opens the chat.
    var previewTapped: (() -> Void)?

    /// As Telegram's chat: the navigation controller starts the push once the first screen of messages is laid out, so
    /// nothing is laid out or pops in during the animation. A short timeout keeps a slow server from holding it.
    private let readyPromise = Promise<Bool>()
    override var ready: Promise<Bool> {
        return self.readyPromise
    }

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
        self.titleView.tapped = { [weak self] in
            self?.openTitleMenu()
        }
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
            self.titleView.update(selectedCount: ids.count)
            return
        }
        guard let dialog = self.context.store.dialog(self.conversationId) else {
            return
        }
        let model = self.context.store.agent(self.conversationId).modelId ?? dialog.model
        self.titleView.update(title: dialog.title, subtitle: busy ? "working" : "\(dialog.projectName) · \(model)", isActive: busy)
    }

    override func loadDisplayNode() {
        self.displayNode = ChatControllerNode(theme: self.theme, isPreview: self.isPreview)
        let node = self.controllerNode
        node.initialScrollState = self.context.store.scrollState(self.conversationId)
        node.contentReady = { [weak self] in
            self?.readyPromise.set(.single(true))
        }
        Queue.mainQueue().after(0.35) { [weak self] in
            self?.readyPromise.set(.single(true))
        }
        // The position also survives the app being suspended and killed with the chat open.
        NotificationCenter.default.addObserver(self, selector: #selector(self.saveScrollState), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
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
        node.openContextMenu = { [weak self] message, itemNode, gesture in
            self?.openContextMenu(message: message, itemNode: itemNode, gesture: gesture)
        }
        node.openTool = { [weak self] message in
            guard let self else {
                return
            }
            if let child = message.tool?.childConversationId {
                // A subagent's own conversation, live, as any chat.
                (self.navigationController as? NavigationController)?.pushViewController(ChatController(context: self.context, conversationId: child))
            } else {
                self.controllerNode.toggleExpanded(message.id)
            }
        }
        node.presentInGlobalOverlay = { [weak self] controller, arguments in
            self?.presentInGlobalOverlay(controller, with: arguments)
        }
        node.openImage = { [weak self] attachmentId in
            self?.openImage(attachmentId: attachmentId)
        }
        node.loadOlder = { [weak self] in
            guard let self else {
                return
            }
            self.context.store.loadOlder(self.conversationId)
        }
        node.inputPanelNode.attachPressed = { [weak self] in
            self?.openAttachments()
        }
        node.inputPanelNode.micPressed = { [weak self] in
            self?.controllerNode.showToast("Voice input is coming soon")
        }
        node.inputPanelNode.stopPressed = { [weak self] in
            guard let self else {
                return
            }
            self.context.store.abort(self.conversationId)
        }
        node.inputPanelNode.cancelEditing = { [weak self] in
            self?.endEditing(clearText: true)
        }

        if self.isPreview {
            node.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.previewTapGesture)))
        }

        self.stateDisposable.set((self.context.store.conversationSignal(self.conversationId) |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            self.lastState = state
            self.controllerNode.update(state: state)
            if self.isOnScreen && UIApplication.shared.applicationState == .active {
                self.context.store.markSeen(self.conversationId)
            }
            self.controllerNode.inputPanelNode.isBusy = state.busy
            self.updateTitle(busy: state.busy)
        }))
        self.displayNodeDidLoad()
    }

    private let hiddenMediaDisposable = MetaDisposable()

    /// Telegram's media viewer over the chat, paging through the conversation's photos, from the tapped one.
    private func openImage(attachmentId: Int) {
        let entries = self.controllerNode.imageEntries()
        guard let index = entries.firstIndex(where: { $0.attachmentId == attachmentId }) else {
            return
        }
        self.view.endEditing(true)
        let gallery = ImageGalleryController(context: self.context, entries: entries, centralIndex: index, baseNavigationController: self.navigationController as? NavigationController)
        self.hiddenMediaDisposable.set((gallery.hiddenMedia |> deliverOnMainQueue).start(next: { [weak self] entry in
            self?.controllerNode.setHiddenAttachment(entry?.attachmentId)
        }))
        let arguments = ImageGalleryControllerPresentationArguments(transitionArguments: { [weak self] entry in
            guard let self, let node = self.controllerNode.imageNode(attachmentId: entry.attachmentId) else {
                return nil
            }
            return ImageGalleryTransitionArguments(transitionNode: (node, node.bounds, { [weak node] in
                return (node?.view.snapshotContentTree(unhide: true), nil)
            }), addToTransitionSurface: { [weak self] view in
                self?.controllerNode.view.addSubview(view)
            })
        })
        self.present(gallery, in: .window(.root), with: arguments, blockInteraction: true)
    }

    @objc private func previewTapGesture() {
        self.previewTapped?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Only once the chat is gone: a swipe back can still be cancelled.
        if !self.isPreview && self.navigationController == nil {
            self.context.store.discardIfDraft(self.conversationId)
        }
    }

    @objc private func applicationDidBecomeActive() {
        if self.isOnScreen {
            self.context.store.markSeen(self.conversationId)
        }
    }

    /// On screen and not a preview: what arrives is read, as Telegram reads the messages a chat shows.
    private var isOnScreen = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !self.isPreview {
            self.isOnScreen = true
            self.context.store.markSeen(self.conversationId)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.isOnScreen = false
        self.saveScrollState()
    }

    @objc private func saveScrollState() {
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
            // The conversation continues from a fork before the edited message; show the fork in this chat's place.
            // The keyboard goes down first, while this chat is still on screen to take the layout change.
            self.controllerNode.inputPanelNode.deactivateInput()
            self.context.store.edit(messageId: messageId, text: text, in: self.conversationId, completion: { [weak self] newId in
                guard let self, newId != self.conversationId, let navigationController = self.navigationController as? NavigationController else {
                    return
                }
                Queue.mainQueue().after(0.3) {
                    navigationController.replaceTopController(ChatController(context: self.context, conversationId: newId), animated: false)
                }
            })
            self.endEditing(clearText: false)
        } else {
            self.context.store.send(text, attachments: attachments, to: self.conversationId)
        }
        self.controllerNode.wallpaperNode.animateEvent()
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
        case .share:
            self.share(text: message.text)
        }
    }

    private func share(text: String) {
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        self.view.window?.rootViewController?.present(activity, animated: true)
    }

    // MARK: - Title menu

    /// A tap on the title: the conversation's settings in Telegram's context menu, as Telegram's title opens a peer's
    /// actions. Model and thinking level open as nested lists.
    private func openTitleMenu() {
        guard !self.isPreview, self.controllerNode.selectedIds == nil else {
            return
        }
        self.controllerNode.inputPanelNode.deactivateInput()
        let store = self.context.store
        let id = self.conversationId
        let agent = store.agent(id)
        let thinking = agent.thinkingLevel ?? "off"
        let icon: (String) -> (PresentationTheme) -> UIImage? = { name in
            return { theme in generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor) }
        }
        let checkIcon: (Bool) -> (PresentationTheme) -> UIImage? = { checked in
            return { theme in checked ? generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor) : nil }
        }

        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: "Model", textLayout: .secondLineWithValue(agent.modelId ?? "default"), icon: icon("Chat/Context Menu/Settings"), action: { [weak self] _, f in
            f(.default)
            guard let self else {
                return
            }
            let current = agent.provider.flatMap { provider in agent.modelId.map { "\(provider)/\($0)" } }
            let picker = ModelPickerController(context: self.context, title: "Model", current: current, select: { [weak self] model in
                store.configure(id, model: model, thinkingLevel: nil)
                self?.controllerNode.showToast("Model: \(model.name)")
            })
            (self.navigationController as? NavigationController)?.pushViewController(picker)
        })))
        items.append(.action(ContextMenuActionItem(text: "Thinking", textLayout: .secondLineWithValue(thinking.capitalized), icon: icon("Chat/Context Menu/Timer"), action: { controller, _ in
            var levelItems: [ContextMenuItem] = [.action(ContextMenuActionItem(text: self.theme.presentationStrings.Common_Back, icon: icon("Chat/Context Menu/Back"), iconPosition: .left, action: { controller, _ in
                controller?.popItems()
            })), .separator]
            for level in ["off", "low", "medium", "high"] {
                levelItems.append(.action(ContextMenuActionItem(text: level.capitalized, icon: checkIcon(level == thinking), action: { [weak self] _, f in
                    f(.default)
                    store.configure(id, model: nil, thinkingLevel: level)
                    self?.controllerNode.showToast("Thinking: \(level.capitalized)")
                })))
            }
            controller?.pushItems(items: .single(ContextController.Items(content: .list(levelItems))))
        })))
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: "Compact Context", icon: icon("Chat/Context Menu/Clear"), action: { [weak self] _, f in
            f(.default)
            store.compact(id)
            self?.controllerNode.showToast("Compacting context")
        })))
        items.append(.action(ContextMenuActionItem(text: "New Context", textLayout: .secondLineWithValue("The model forgets this chat"), icon: icon("Chat/Context Menu/Reload"), action: { [weak self] _, f in
            f(.default)
            store.resetContext(id)
            self?.controllerNode.showToast("New context")
        })))

        let source = ChatTitleContextReferenceSource(view: self.titleView, contentArea: self.controllerNode.view.convert(self.controllerNode.frameForVisibleArea(), to: nil))
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .reference(source), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.presentInGlobalOverlay(controller)
    }

    // MARK: - Context menu

    /// Telegram's message context menu (ContextControllerImpl, copied): the message lifts out of the list onto a
    /// blurred background with the actions beside it, as in ChatControllerImpl's openMessageContextMenu.
    private func openContextMenu(message: ChatMessage, itemNode: ChatMessageItemNode, gesture: ContextGesture?) {
        guard !self.isPreview, self.controllerNode.selectedIds == nil else {
            gesture?.cancel()
            return
        }
        self.controllerNode.inputPanelNode.deactivateInput()
        let strings = self.theme.presentationStrings
        var items: [ContextMenuItem] = []
        if !message.text.isEmpty {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuCopy, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                f(.default)
                self?.perform(.copy, on: message)
            })))
        }
        if message.role == .user {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_MessageDialogEdit, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                f(.default)
                self?.perform(.edit, on: message)
            })))
        }
        if !message.text.isEmpty {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuShare, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Share"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                f(.default)
                self?.perform(.share, on: message)
            })))
        }
        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuSelect, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Select"), color: theme.actionSheet.primaryTextColor)
        }, action: { [weak self] _, f in
            // As Telegram's beginMessageSelection: rows move to their selection layout first, then the menu puts the
            // message back into its new place with the same transition.
            guard let self else {
                f(.default)
                return
            }
            let transition: ContainedViewLayoutTransition = .animated(duration: 0.4, curve: .spring)
            self.controllerNode.setSelection([message.id], transition: transition)
            f(.custom(transition))
        })))

        let source = ChatMessageContextExtractedContentSource(chatNode: self.controllerNode, messageId: message.id)
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .extracted(source), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: gesture)
        self.presentInGlobalOverlay(controller)
    }

    // MARK: - Selection mode

    /// Telegram's selection navigation: Cancel takes the back button's place, and the title becomes the count.
    private func selectionChanged(_ ids: Set<Int>?) {
        if ids != nil {
            if self.navigationItem.leftBarButtonItem == nil {
                let cancel = UIBarButtonItem(title: self.theme.presentationStrings.Common_Cancel, style: .plain, target: self, action: #selector(self.endSelection))
                cancel.accessibilityLabel = self.theme.presentationStrings.Common_Cancel
                self.navigationItem.setLeftBarButton(cancel, animated: true)
            }
        } else {
            self.navigationItem.setLeftBarButton(nil, animated: true)
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
        case .share:
            let text = selected.map(\.text).joined(separator: "\n\n")
            self.controllerNode.setSelection(nil)
            self.share(text: text)
        default:
            break
        }
    }

    // MARK: - Attachments

    /// Telegram's attachment menu (TelegramAttachmentMenu.swift); files and the full camera use the system pickers.
    private func openAttachments() {
        self.controllerNode.inputPanelNode.deactivateInput()
        let caption = self.controllerNode.inputPanelNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let menu = makeTelegramAttachmentMenu(context: self.context.telegram, presentationData: self.theme.presentationData, completion: { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case let .photos(images, pickedCaption):
                guard !images.isEmpty else {
                    return
                }
                let attachments = images.map { MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .image($0)) }
                let text = pickedCaption.isEmpty ? caption : pickedCaption
                if !text.isEmpty {
                    self.controllerNode.inputPanelNode.setText("")
                }
                self.send(text: text, attachments: attachments)
            case .files:
                let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                documentPicker.delegate = self
                self.view.window?.rootViewController?.present(documentPicker, animated: true)
            case .camera:
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    self.controllerNode.showToast("No camera on this device")
                    return
                }
                let camera = UIImagePickerController()
                camera.sourceType = .camera
                camera.delegate = self
                self.view.window?.rootViewController?.present(camera, animated: true)
            }
        })
        self.present(menu, in: .window(.root))
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

/// The chat title in a glass capsule, as Telegram's ChatTitleView draws it in the glass navigation bar. The title is
/// an AnimatedTextComponent (so "3 Selected" rolls its count), the subtitle a ChatTitleActivityNode (project and model,
/// or "working" with Telegram's typing dots), and the capsule springs to its new width when either changes.
final class ChatTitleView: UIView {
    enum Status: Equatable {
        case info(String)
        case working(String)
    }

    private var theme: TauTheme
    private let backgroundView = GlassBackgroundView()
    private let title = ComponentView<Empty>()
    private let activityNode = ChatTitleActivityNode()
    private var titleItems: [AnimatedTextComponent.Item] = []
    private var status: Status?
    private var hasLayout = false
    var tapped: (() -> Void)?

    init(theme: TauTheme) {
        self.theme = theme
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 240.0, height: 44.0))
        self.addSubview(self.backgroundView)
        self.activityNode.isUserInteractionEnabled = false
        self.backgroundView.contentView.addSubview(self.activityNode.view)
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapGesture() {
        self.tapped?()
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        let status = self.status
        self.status = nil
        self.update(titleItems: self.titleItems, status: status, animated: false)
    }

    func update(title: String, subtitle: String?, isActive: Bool = false) {
        let status: Status? = subtitle.map { isActive ? .working($0) : .info($0) }
        self.fullTitle = title
        self.update(titleItems: [AnimatedTextComponent.Item(id: AnyHashable("title"), content: .text(self.fitted(title)))], status: status, animated: true)
    }

    private var fullTitle: String?

    /// AnimatedTextComponent does not truncate; a long conversation title is cut to the capsule's width here.
    private func fitted(_ title: String) -> String {
        let maxWidth = max(40.0, self.bounds.width - 24.0)
        let font = Font.semibold(16.0)
        func width(_ text: String) -> CGFloat {
            return ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        if width(title) <= maxWidth {
            return title
        }
        var characters = Array(title)
        while !characters.isEmpty && width(String(characters) + "…") > maxWidth {
            characters.removeLast()
        }
        return String(characters).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "N Selected", with N rolling as Telegram's counters do.
    func update(selectedCount: Int) {
        self.fullTitle = nil
        self.update(titleItems: [
            AnimatedTextComponent.Item(id: AnyHashable("count"), content: .number(selectedCount, minDigits: 1)),
            AnimatedTextComponent.Item(id: AnyHashable("label"), content: .text(" Selected")),
        ], status: nil, animated: true)
    }

    private func update(titleItems: [AnimatedTextComponent.Item], status: Status?, animated: Bool) {
        let animated = animated && self.hasLayout
        self.titleItems = titleItems
        if self.status != status {
            self.status = status
            let state: ChatTitleActivityNodeState
            switch status {
            case let .info(text):
                state = .info(NSAttributedString(string: text, font: Font.regular(12.0), textColor: self.theme.navigationBar.secondaryTextColor), .generic)
            case let .working(text):
                state = .typingText(NSAttributedString(string: text, font: Font.regular(12.0), textColor: self.theme.accentColor), self.theme.accentColor)
            case nil:
                state = .none
            }
            let _ = self.activityNode.transitionToState(state, animation: animated ? .crossfade : .none)
        }
        self.layoutContent(transition: animated ? .spring(duration: 0.4) : .immediate)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let title = self.fullTitle, self.titleItems.count == 1 {
            self.titleItems = [AnimatedTextComponent.Item(id: AnyHashable("title"), content: .text(self.fitted(title)))]
        }
        self.layoutContent(transition: .immediate)
    }

    private func layoutContent(transition: ComponentTransition) {
        self.hasLayout = self.bounds.width > 0.0
        let maxTextWidth = max(40.0, self.bounds.width - 24.0)
        let titleSize = self.title.update(
            transition: transition,
            component: AnyComponent(AnimatedTextComponent(font: Font.semibold(16.0), color: self.theme.navigationBar.primaryTextColor, items: self.titleItems, noDelay: true)),
            environment: {},
            containerSize: CGSize(width: maxTextWidth, height: 22.0)
        )
        let hasStatus = self.status != nil
        let statusSize = hasStatus ? self.activityNode.updateLayout(CGSize(width: maxTextWidth, height: 16.0), alignment: .center) : CGSize()
        let textWidth = min(maxTextWidth, ceil(max(titleSize.width, statusSize.width)))

        // Telegram ChatTitleView: a 44 pt capsule, 12 pt wider than the text on each side.
        let backgroundSize = CGSize(width: textWidth + 24.0, height: 44.0)
        let backgroundFrame = CGRect(origin: CGPoint(x: floor((self.bounds.width - backgroundSize.width) / 2.0), y: floor((self.bounds.height - backgroundSize.height) / 2.0)), size: backgroundSize)
        transition.setFrame(view: self.backgroundView, frame: backgroundFrame)
        self.backgroundView.update(size: backgroundSize, cornerRadius: backgroundSize.height / 2.0, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: true, transition: transition)

        let titleFrame = CGRect(origin: CGPoint(x: floor((backgroundSize.width - titleSize.width) / 2.0), y: hasStatus ? 4.0 : floor((backgroundSize.height - titleSize.height) / 2.0)), size: titleSize)
        if let titleView = self.title.view {
            if titleView.superview == nil {
                self.backgroundView.contentView.addSubview(titleView)
                titleView.frame = titleFrame
            }
            transition.setFrame(view: titleView, frame: titleFrame)
        }
        // ChatTitleActivityNode centers its text on its own origin.
        let statusFrame = CGRect(origin: CGPoint(x: floor(backgroundSize.width / 2.0), y: 24.0), size: statusSize)
        transition.setFrame(view: self.activityNode.view, frame: statusFrame)
        transition.setAlpha(view: self.activityNode.view, alpha: hasStatus ? 1.0 : 0.0)
    }
}

/// Lifts a message's content node out of the list for the context menu and puts it back, as Telegram's
/// ChatMessageContextExtractedContentSource does.
private final class ChatMessageContextExtractedContentSource: ContextExtractedContentSource {
    let keepInPlace: Bool = false
    // As Telegram's: touches reach the lifted message, for text selection.
    let ignoreContentTouches: Bool = false
    let blurBackground: Bool = true

    private weak var chatNode: ChatControllerNode?
    private let messageId: Int

    var shouldBeDismissed: Signal<Bool, NoError> {
        return .single(false)
    }

    init(chatNode: ChatControllerNode, messageId: Int) {
        self.chatNode = chatNode
        self.messageId = messageId
    }

    func takeView() -> ContextControllerTakeViewInfo? {
        guard let chatNode = self.chatNode, let itemNode = chatNode.itemNode(messageId: self.messageId) else {
            return nil
        }
        return ContextControllerTakeViewInfo(containingItem: .node(itemNode.contextSourceNode), contentAreaInScreenSpace: chatNode.view.convert(chatNode.frameForVisibleArea(), to: nil))
    }

    func putBack() -> ContextControllerPutBackViewInfo? {
        guard let chatNode = self.chatNode else {
            return nil
        }
        return ContextControllerPutBackViewInfo(contentAreaInScreenSpace: chatNode.view.convert(chatNode.frameForVisibleArea(), to: nil))
    }
}

/// The title capsule as a context menu's anchor: the menu drops from it, as Telegram's peer menus do.
private final class ChatTitleContextReferenceSource: ContextReferenceContentSource {
    let keepInPlace: Bool = false
    private weak var view: UIView?
    private let contentArea: CGRect

    init(view: UIView, contentArea: CGRect) {
        self.view = view
        self.contentArea = contentArea
    }

    var shouldBeDismissed: Signal<Bool, NoError> {
        return .single(false)
    }

    var forceDisplayBelowKeyboard: Bool {
        return false
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        guard let view = self.view else {
            return nil
        }
        return ContextControllerReferenceViewInfo(referenceView: view, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}
