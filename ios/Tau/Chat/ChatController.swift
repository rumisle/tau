import UIKit
import AsyncDisplayKit
import Display
import UndoUI
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
    /// A draft moved to another server becomes that server's draft, in this same screen.
    private(set) var conversationId: Int
    private let isPreview: Bool
    private var theme: TauTheme
    private let stateDisposable = MetaDisposable()
    private let eventsDisposable = MetaDisposable()
    private var themeDisposable: Disposable?
    private var settingsDisposable: Disposable?
    private let titleView: ChatTitleView
    private var editingMessageId: Int?
    /// The entry of the message being edited, which the draft keeps across launches.
    private var editingEntryId: Int?
    /// While editing, the message that was being written, which comes back when the edit ends (Telegram's
    /// composeInputState beside editMessage).
    private var composeText = ""
    /// An edit the saved draft had, applied once its message is in the transcript.
    private var pendingEditDraft: InputDraft?
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

    /// A message found by search, opened at with its words marked.
    private let focus: ChatFocus?

    init(context: AppContext, conversationId: Int, isPreview: Bool = false, focus: ChatFocus? = nil) {
        self.focus = focus
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
        if !isPreview {
            self.subscribeConnection()
        }
        self.settingsDisposable = (context.themeContext.settingsSignal |> deliverOnMainQueue).start(next: { [weak self] settings in
            self?.controllerNode.wrapCode = settings.wrapCode
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.chatSearchDisposable.dispose()
        self.titleTimer?.invalidate()
        self.stateDisposable.dispose()
        self.eventsDisposable.dispose()
        self.connectionDisposable?.dispose()
        self.themeDisposable?.dispose()
        self.settingsDisposable?.dispose()
    }

    private var seenCompactionFailure: Int??
    private var titleTimer: SwiftSignalKit.Timer?

    /// When the compaction now running began, as the transcript's pill says.
    private var compactingSince: Date? {
        for message in (self.lastState?.messages ?? []).reversed() {
            if case let .compacting(since) = message.service {
                return since
            }
        }
        return nil
    }

    /// The title's time ticks while the agent works or a compaction runs.
    private func updateTitleTimer() {
        let ticking = (self.lastState?.busy == true && self.lastState?.runStartedAt != nil) || self.compactingSince != nil
        if ticking, self.titleTimer == nil {
            let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
                guard let self else {
                    return
                }
                self.updateTitle(busy: self.lastState?.busy ?? false)
            }, queue: Queue.mainQueue())
            self.titleTimer = timer
            timer.start()
        } else if !ticking, let timer = self.titleTimer {
            self.titleTimer = nil
            timer.invalidate()
        }
    }

    private func subscribeConnection() {
        let store = self.context.store
        self.connectionDisposable?.dispose()
        self.connectionDisposable = ((store.server(of: self.conversationId)?.connectionStatus ?? store.connectionStatus) |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let self else {
                return
            }
            self.connectionStatus = status
            self.updateTitle(busy: self.lastState?.busy ?? false)
        })
    }

    private func subscribeConversation() {
        self.stateDisposable.set((self.context.store.conversationSignal(self.conversationId) |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            self.lastState = state
            self.controllerNode.update(state: state)
            if let pending = self.pendingEditDraft, let message = state.messages.first(where: { $0.entryId != nil && $0.entryId == pending.editEntryId }) {
                self.pendingEditDraft = nil
                self.beginEditing(message, text: pending.editText ?? message.text, focus: false)
            }
            if self.isOnScreen && UIApplication.shared.applicationState == .active {
                self.context.store.markSeen(self.conversationId)
            }
            self.controllerNode.inputPanelNode.isBusy = state.busy
            self.updateTitle(busy: state.busy)
            self.updateTitleTimer()
            // A compaction that failed says so once, as a toast; one from before this chat opened stays quiet.
            let failure = state.compactionFailure?.taskId
            if self.seenCompactionFailure == nil {
                self.seenCompactionFailure = .some(failure)
            } else if let failure, self.seenCompactionFailure != .some(failure) {
                self.seenCompactionFailure = .some(failure)
                self.presentToast(.info(title: nil, text: "The context could not be compacted: \(state.compactionFailure?.error ?? "")", timeout: nil, customUndoText: nil))
            }
        }))
        if !self.isPreview {
            self.eventsDisposable.set((self.context.store.chatEvents(self.conversationId) |> deliverOnMainQueue).start(next: { [weak self] event in
                guard let self else {
                    return
                }
                switch event {
                case let .restoreInput(text):
                    self.controllerNode.inputPanelNode.appendText(text)
                case let .notice(text):
                    self.presentToast(.info(title: nil, text: text, timeout: nil, customUndoText: nil))
                }
            }))
        }
    }

    /// The draft is another one now (another server's): the same screen follows it, with what was written.
    private func retarget(to id: Int) {
        let old = self.conversationId
        guard id != old else {
            return
        }
        self.conversationId = id
        self.context.store.setInputDraft(nil, for: old)
        self.context.store.discardIfDraft(old)
        self.subscribeConnection()
        self.subscribeConversation()
        self.saveInputDraft()
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
        // As Telegram's ChatTitleComponent: the connection's state takes the subtitle's place until it is back.
        let strings = self.theme.presentationStrings
        let status: ChatTitleView.Status
        switch self.connectionStatus {
        case .waitingForNetwork:
            status = .network(strings.ChatState_WaitingForNetwork)
        case .connecting:
            status = .network(strings.ChatState_Connecting)
        case .updating:
            status = .network(strings.ChatState_Updating)
        case .online:
            if busy {
                // How long this run has worked, as it goes.
                let elapsed = self.lastState?.runStartedAt.map { Date().timeIntervalSince($0) } ?? 0.0
                status = .working(elapsed >= 1.0 ? "working · \(formatElapsed(elapsed))" : "working")
            } else if let since = self.compactingSince {
                let elapsed = Date().timeIntervalSince(since)
                status = .working(elapsed >= 1.0 ? "compacting · \(formatElapsed(elapsed))" : "compacting")
            } else if let activity = dialog.subagentActivity {
                // Its background subagents, as Telegram's title says who is typing.
                status = .working(activity)
            } else {
                status = .info("\(dialog.projectLabel) · \(model)")
            }
        }
        self.titleView.update(title: dialog.title, status: status)
        self.updateNewChatCard(dialog: dialog)
    }

    /// A chat not created yet shows where it will run and with what, each a tap from changing.
    private func updateNewChatCard(dialog: DialogModel) {
        guard dialog.id < 0, !self.isPreview else {
            self.controllerNode.newChatCard = nil
            return
        }
        let store = self.context.store
        let agent = store.agent(self.conversationId)
        let location = ProjectLocation(slot: dialog.serverSlot, path: dialog.cwd)
        let modelName = agent.provider.flatMap { provider in agent.modelId.flatMap { store.server(of: self.conversationId)?.cachedModel(provider: provider, id: $0)?.name } } ?? agent.modelId ?? dialog.model
        self.controllerNode.newChatCard = NewChatCardNode.Content(
            project: store.projectTitle(location),
            projectDetail: store.describe(location),
            model: modelName,
            modelDetail: "Thinking: \(thinkingTitle(agent.thinkingLevel ?? "off"))"
        )
    }

    private func chooseProject() {
        guard let dialog = self.context.store.dialog(self.conversationId) else {
            return
        }
        let current = ProjectLocation(slot: dialog.serverSlot, path: dialog.cwd)
        let picker = ProjectPickerController(context: self.context, current: current, choose: { [weak self] location in
            guard let self else {
                return
            }
            self.saveInputDraft()
            let newId = self.context.store.relocateDraft(self.conversationId, to: location)
            if newId != self.conversationId {
                self.retarget(to: newId)
            } else {
                self.updateTitle(busy: false)
            }
        })
        (self.navigationController as? NavigationController)?.pushViewController(picker)
    }

    private func openModelPicker() {
        let store = self.context.store
        let id = self.conversationId
        let agent = store.agent(id)
        let current = agent.provider.flatMap { provider in agent.modelId.map { "\(provider)/\($0)" } }
        guard let server = store.server(of: id) else {
            return
        }
        let picker = ModelPickerController(context: self.context, server: server, title: "Model", current: current, select: { [weak self] model in
            store.configure(id, model: model, thinkingLevel: nil)
            self?.presentToast(.succeed(text: "Model changed to **\(model.name)**", timeout: nil, customUndoText: nil))
        })
        (self.navigationController as? NavigationController)?.pushViewController(picker)
    }

    private var connectionStatus: ConnectionStatus = .online
    private var connectionDisposable: Disposable?

    override func loadDisplayNode() {
        self.displayNode = ChatControllerNode(theme: self.theme, isPreview: self.isPreview)
        let node = self.controllerNode
        node.initialScrollState = self.context.store.scrollState(self.conversationId)
        if let focus = self.focus {
            node.focus = focus
            node.searchHighlight = (entryIds: [focus.entryId], terms: focus.terms)
            node.requestHistory = { [weak self] entryId in
                guard let self else {
                    return
                }
                self.context.store.loadHistory(self.conversationId, through: entryId)
            }
        }
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
        node.newChatProjectTapped = { [weak self] in
            self?.chooseProject()
        }
        node.newChatModelTapped = { [weak self] in
            self?.openModelPicker()
        }
        node.presentToast = { [weak self] content in
            self?.presentToast(content)
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
            if case .failed = message.service {
                self.retryAfterError(message)
            } else if let child = message.tool?.childConversationId {
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
        node.inputPanelNode.micPressed = {
            // Dictation starts; a real engine will ask for the microphone here.
        }
        node.inputPanelNode.stopPressed = { [weak self] in
            guard let self else {
                return
            }
            self.context.store.stop(self.conversationId)
        }
        node.inputPanelNode.sendLongPressed = { [weak self] view in
            self?.openSendMenu(sourceView: view)
        }
        node.inputPanelNode.queueTapped = { [weak self] view in
            self?.openQueueMenu(sourceView: view)
        }
        node.inputPanelNode.queueClosed = { [weak self] queued in
            guard let self else {
                return
            }
            self.context.store.withdraw(queued, in: self.conversationId, restore: false)
        }
        node.inputPanelNode.cancelEditing = { [weak self] in
            self?.endEditing(clearText: true)
        }
        if !self.isPreview {
            // What was written and not sent, as it was left, even across a crash.
            if let draft = self.context.store.inputDraft(self.conversationId) {
                node.inputPanelNode.setText(draft.text)
                if draft.editEntryId != nil {
                    self.pendingEditDraft = draft
                }
            }
            node.inputPanelNode.textChanged = { [weak self] _ in
                self?.saveInputDraft()
            }
        }

        if self.isPreview {
            node.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.previewTapGesture)))
        }

        self.subscribeConversation()
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
            LiveActivityController.shared.seen((self.context.store as? MultiStore)?.realId(self.conversationId) ?? self.conversationId)
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

    private(set) var validLayout: ContainerViewLayout?

    /// The chat grows out of its preview into the navigation stack, as Telegram's ChatControllerImpl
    /// animateFromPreviewing does: pushed without animation, then its view goes from the preview's frame and size to
    /// its own, the history scaled so its lines keep their breaks, the input panel rising from below.
    func animateFromPreview(frame initialFrame: CGRect, transition: ContainedViewLayoutTransition = .animated(duration: 0.4, curve: .spring)) {
        guard let navigationController = self.navigationController as? NavigationController, let updatedLayout = self.validLayout, transition.isAnimated else {
            return
        }
        let initialLayout = ContainerViewLayout(size: initialFrame.size, metrics: updatedLayout.metrics, deviceMetrics: updatedLayout.deviceMetrics, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), additionalInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
        let initialView = self.view.superview
        let startFrame = navigationController.view.convert(initialFrame, from: nil)
        let updatedFrame = self.view.convert(self.view.bounds, to: navigationController.view)
        navigationController.view.addSubview(self.view)
        self.view.clipsToBounds = true
        self.view.frame = startFrame
        self.containerLayoutUpdated(initialLayout, transition: .immediate)
        self.containerLayoutUpdated(updatedLayout, transition: transition)
        let history = self.controllerNode.historyNode
        history.layer.animateScaleX(from: initialLayout.size.width / updatedLayout.size.width, to: 1.0, duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring)
        history.layer.animatePosition(from: CGPoint(x: (updatedLayout.size.width - initialLayout.size.width) / 2.0, y: 0.0), to: CGPoint(), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
        let panel = self.controllerNode.inputPanelNode
        panel.layer.animatePosition(from: CGPoint(x: 0.0, y: panel.frame.height + 40.0), to: CGPoint(), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
        self.view.layer.animate(from: 30.0 as NSNumber, to: updatedLayout.deviceMetrics.screenCornerRadius as NSNumber, keyPath: "cornerRadius", timingFunction: kCAMediaTimingFunctionSpring, duration: 0.4)
        transition.updateFrame(view: self.view, frame: updatedFrame, completion: { [weak self] _ in
            guard let self else {
                return
            }
            initialView?.addSubview(self.view)
            self.view.clipsToBounds = false
        })
        transition.updateCornerRadius(layer: self.view.layer, cornerRadius: 0.0)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout
        super.containerLayoutUpdated(layout, transition: transition)
        let navigationHeight = self.isPreview ? 0.0 : self.navigationLayout(layout: layout).navigationFrame.maxY
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: transition)
        // As Telegram's chat: overlays presented over it, toasts among them, keep clear of the input panel.
        var childrenLayout = layout
        childrenLayout.intrinsicInsets.bottom = max(layout.intrinsicInsets.bottom, self.controllerNode.inputPanelInset)
        self.presentationContext.containerLayoutUpdated(childrenLayout, transition: transition)
    }

    /// Telegram's toast at the bottom of the chat; a new one replaces the one showing, as in Telegram.
    private weak var currentToast: UndoOverlayController?

    func presentToast(_ content: UndoOverlayContent, action: @escaping (UndoOverlayAction) -> Bool = { _ in return false }) {
        let replacing = self.currentToast != nil
        self.currentToast?.dismiss()
        let controller = UndoOverlayController(presentationData: self.theme.presentationData, content: content, elevatedLayout: false, animateInAsReplacement: replacing, action: action)
        self.currentToast = controller
        self.present(controller, in: .current)
    }

    // MARK: - Sending and editing

    private func send(text: String, attachments: [MessageAttachment]) {
        if let messageId = self.editingMessageId {
            // The conversation continues from a fork before the edited message; show the fork in this chat's place.
            // The keyboard goes down first, while this chat is still on screen to take the layout change.
            self.controllerNode.inputPanelNode.deactivateInput()
            // Photos attached while editing join the message's own.
            let original = self.lastState?.messages.first(where: { $0.id == messageId })?.attachments ?? []
            self.context.store.edit(messageId: messageId, text: text, attachments: original + attachments, in: self.conversationId, completion: { [weak self] newId in
                guard let self, newId != self.conversationId, let navigationController = self.navigationController as? NavigationController else {
                    return
                }
                Queue.mainQueue().after(0.3) {
                    navigationController.replaceTopController(ChatController(context: self.context, conversationId: newId), animated: false)
                }
            })
            // After the panel has cleared its field for the sent text.
            Queue.mainQueue().async { [weak self] in
                self?.endEditing(clearText: false)
            }
        } else {
            self.context.store.send(text, attachments: attachments, to: self.conversationId)
        }
        self.controllerNode.wallpaperNode.animateEvent()
    }

    /// The field holds `text` for `message` and Telegram's "Edit Message" panel shows above it; what was being written
    /// waits until the edit ends.
    private func beginEditing(_ message: ChatMessage, text: String, focus: Bool) {
        if self.editingMessageId == nil {
            self.composeText = self.controllerNode.inputPanelNode.text
        }
        self.editingMessageId = message.id
        self.editingEntryId = message.entryId
        self.controllerNode.inputPanelNode.setEditing(message.text)
        self.controllerNode.inputPanelNode.setText(text)
        if focus {
            self.controllerNode.inputPanelNode.activateInput()
        }
    }

    /// Cancelled or sent: the message that was being written comes back to the field.
    private func endEditing(clearText: Bool) {
        self.editingMessageId = nil
        self.editingEntryId = nil
        self.controllerNode.inputPanelNode.setEditing(nil)
        let compose = self.composeText
        self.composeText = ""
        self.controllerNode.inputPanelNode.setText(compose)
        self.saveInputDraft()
    }

    private func saveInputDraft() {
        guard !self.isPreview else {
            return
        }
        var draft = InputDraft()
        if let entryId = self.editingEntryId {
            draft.text = self.composeText
            draft.editEntryId = entryId
            draft.editText = self.controllerNode.inputPanelNode.text
        } else {
            draft.text = self.controllerNode.inputPanelNode.text
            if let pending = self.pendingEditDraft {
                draft.editEntryId = pending.editEntryId
                draft.editText = pending.editText
            }
        }
        self.context.store.setInputDraft(draft, for: self.conversationId)
    }

    private func perform(_ action: ChatMessageAction, on message: ChatMessage) {
        switch action {
        case .copy:
            UIPasteboard.general.string = message.text
            self.presentToast(.copy(text: self.theme.presentationStrings.Conversation_TextCopied))
        case .edit:
            self.beginEditing(message, text: message.text, focus: true)
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

    // MARK: - Sending modes and the queue

    private func menuIcon(_ name: String) -> (PresentationTheme) -> UIImage? {
        return { theme in generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor) }
    }

    /// Telegram's stop glyph for menus: a rounded square in a circle, drawn as its 24 pt line icons are.
    private static func stopIcon(_ theme: PresentationTheme) -> UIImage? {
        return generateImage(CGSize(width: 24.0, height: 24.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setStrokeColor(theme.contextMenu.primaryColor.cgColor)
            context.setFillColor(theme.contextMenu.primaryColor.cgColor)
            context.setLineWidth(1.33)
            context.strokeEllipse(in: CGRect(x: 2.665, y: 2.665, width: 18.67, height: 18.67))
            context.addPath(UIBezierPath(roundedRect: CGRect(x: 8.5, y: 8.5, width: 7.0, height: 7.0), cornerRadius: 1.5).cgPath)
            context.fillPath()
        })
    }

    /// A long press on Send while the agent works, as Telegram's send button opens Schedule Message: send after the
    /// run instead of at its next step, or stop it and send now.
    private func openSendMenu(sourceView: UIView) {
        guard !self.isPreview, self.lastState?.busy == true, self.editingMessageId == nil else {
            return
        }
        let id = self.conversationId
        let store = self.context.store
        let take: () -> String? = { [weak self] in
            guard let self else {
                return nil
            }
            let text = self.controllerNode.inputPanelNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            self.controllerNode.inputPanelNode.setText("")
            return text
        }
        let items: [ContextMenuItem] = [
            .action(ContextMenuActionItem(text: "Send as Follow-up", icon: self.menuIcon("Chat/Input/Menu/ScheduleIcon"), action: { [weak self] _, f in
                f(.default)
                if let text = take() {
                    store.send(text, attachments: [], to: id, mode: .followUp)
                    self?.controllerNode.wallpaperNode.animateEvent()
                }
            })),
            .action(ContextMenuActionItem(text: "Stop and Send", icon: { theme in ChatController.stopIcon(theme) }, action: { [weak self] _, f in
                f(.default)
                if let text = take() {
                    store.stopAndSend(text, attachments: [], in: id)
                    self?.controllerNode.wallpaperNode.animateEvent()
                }
            }))
        ]
        let source = ChatViewContextReferenceSource(view: sourceView)
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .reference(source), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.presentInGlobalOverlay(controller)
    }

    /// A tap on the queue panel: what can be done with a queued message before the agent has it. Several queued
    /// messages are listed first, each opening its actions.
    private func openQueueMenu(sourceView: UIView) {
        guard !self.isPreview, let queue = self.lastState?.queued, !queue.isEmpty else {
            return
        }
        var items: [ContextMenuItem]
        if queue.count == 1 {
            items = self.queueActions(queue[0], back: false)
        } else {
            items = []
            for queued in queue {
                let title: String
                switch queued.mode {
                case .steer:
                    title = "Steer"
                case .followUp:
                    title = "Follow-up"
                case .newContext:
                    title = "New Context"
                }
                let text = queued.mode == .newContext ? "The model forgets this chat" : (queued.text.isEmpty ? "Photo" : queued.text.replacingOccurrences(of: "\n", with: " "))
                items.append(.action(ContextMenuActionItem(text: text, textLayout: .secondLineWithValue(title), icon: { _ in nil }, action: { [weak self] controller, _ in
                    guard let self else {
                        return
                    }
                    controller?.pushItems(items: .single(ContextController.Items(content: .list(self.queueActions(queued, back: true)))))
                })))
            }
        }
        let source = ChatViewContextReferenceSource(view: sourceView)
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .reference(source), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.presentInGlobalOverlay(controller)
    }

    private func queueActions(_ queued: QueuedMessage, back: Bool) -> [ContextMenuItem] {
        let id = self.conversationId
        let store = self.context.store
        var items: [ContextMenuItem] = []
        if back {
            items.append(.action(ContextMenuActionItem(text: self.theme.presentationStrings.Common_Back, icon: self.menuIcon("Chat/Context Menu/Back"), iconPosition: .left, action: { controller, _ in
                controller?.popItems()
            })))
            items.append(.separator)
        }
        if queued.mode != .newContext {
            // pi's dequeue: the message comes back to the field to change and send again.
            items.append(.action(ContextMenuActionItem(text: self.theme.presentationStrings.Conversation_MessageDialogEdit, icon: self.menuIcon("Chat/Context Menu/Edit"), action: { [weak self] _, f in
                f(.default)
                store.withdraw(queued, in: id, restore: true)
                self?.controllerNode.inputPanelNode.activateInput()
            })))
            let other: SendMode = queued.mode == .steer ? .followUp : .steer
            items.append(.action(ContextMenuActionItem(text: other == .followUp ? "Send as Follow-up" : "Send as Steer", icon: self.menuIcon(other == .followUp ? "Chat/Input/Menu/ScheduleIcon" : "Chat/Context Menu/Forward"), action: { _, f in
                f(.default)
                store.move(queued, in: id, to: other)
            })))
            items.append(.action(ContextMenuActionItem(text: "Send Now", textLayout: .secondLineWithValue("Stops the agent"), icon: self.menuIcon("Chat/Context Menu/Resend"), action: { _, f in
                f(.default)
                store.sendNow(queued, in: id)
            })))
            items.append(.separator)
        }
        items.append(.action(ContextMenuActionItem(text: self.theme.presentationStrings.Conversation_ContextMenuDelete, textColor: .destructive, icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
        }, action: { _, f in
            f(.default)
            store.withdraw(queued, in: id, restore: false)
        })))
        return items
    }

    // MARK: - Title menu

    /// A tap on the title: the conversation's settings in Telegram's context menu, as Telegram's title opens a peer's
    /// actions. Model and thinking level open as nested lists.
    /// Telegram's title alert; the toast after it undoes the rename.
    private func openRename() {
        let store = self.context.store
        let id = self.conversationId
        guard let previous = store.dialog(id)?.title else {
            return
        }
        let alert = renameChatController(context: self.context.telegram, presentationData: self.theme.presentationData, title: previous, apply: { [weak self] title in
            store.rename(id, title: title)
            self?.presentToast(.info(title: nil, text: "Chat renamed to **\(title)**", timeout: nil, customUndoText: self?.theme.presentationStrings.Undo_Undo), action: { action in
                if case .undo = action {
                    store.rename(id, title: previous)
                }
                return true
            })
        })
        self.present(alert, in: .window(.root))
    }

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
        if self.lastState?.messages.isEmpty == false {
            items.append(.action(ContextMenuActionItem(text: self.theme.presentationStrings.Common_Search, icon: icon("Chat/Context Menu/Search"), action: { [weak self] _, f in
                f(.default)
                self?.activateChatSearch()
            })))
        }
        items.append(.action(ContextMenuActionItem(text: "Rename", icon: icon("Chat/Context Menu/Edit"), action: { [weak self] _, f in
            f(.default)
            self?.openRename()
        })))
        items.append(.action(ContextMenuActionItem(text: "Model", textLayout: .secondLineWithValue(agent.modelId ?? "default"), icon: icon("Chat/Context Menu/Settings"), action: { [weak self] _, f in
            f(.default)
            self?.openModelPicker()
        })))
        // The levels this model has (pi-ai's getSupportedThinkingLevels); the server fits the rest.
        let levels = agent.provider.flatMap { provider in agent.modelId.flatMap { store.server(of: id)?.cachedModel(provider: provider, id: $0)?.thinkingLevels } } ?? ["off", "low", "medium", "high"]
        items.append(.action(ContextMenuActionItem(text: "Thinking", textLayout: .secondLineWithValue(thinkingTitle(thinking)), icon: icon("Chat/Context Menu/Timer"), action: { controller, _ in
            var levelItems: [ContextMenuItem] = [.action(ContextMenuActionItem(text: self.theme.presentationStrings.Common_Back, icon: icon("Chat/Context Menu/Back"), iconPosition: .left, action: { controller, _ in
                controller?.popItems()
            })), .separator]
            for level in levels {
                levelItems.append(.action(ContextMenuActionItem(text: thinkingTitle(level), icon: checkIcon(level == thinking), action: { [weak self] _, f in
                    f(.default)
                    store.configure(id, model: nil, thinkingLevel: level)
                    self?.presentToast(.succeed(text: level == "off" ? "Thinking turned off" : "Thinking set to **\(thinkingTitle(level))**", timeout: nil, customUndoText: nil))
                })))
            }
            controller?.pushItems(items: .single(ContextController.Items(content: .list(levelItems))))
        })))
        let subagents = store.subagents(of: id)
        if !subagents.isEmpty {
            let working = subagents.filter(\.busy).count
            let summary = NSMutableAttributedString(string: subagents.count == 1 ? "1 subagent" : "\(subagents.count) subagents")
            if working > 0 {
                summary.insert(NSAttributedString(string: " · "), at: 0)
                summary.insert(NSAttributedString(string: "\(working) working", attributes: [.foregroundColor: self.theme.presentationData.theme.list.itemAccentColor]), at: 0)
            }
            items.append(.action(ContextMenuActionItem(text: "Subagents", textLayout: .secondLineWithAttributedValue(summary), icon: icon("Chat/Context Menu/Bots"), action: { [weak self] controller, _ in
                guard let self else {
                    return
                }
                controller?.pushItems(items: self.subagentItems(icon: icon))
            })))
        }
        items.append(.separator)
        let accent = self.theme.presentationData.theme.list.itemAccentColor
        let openUsage: (ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void = { [weak self] controller, _ in
            guard let self else {
                return
            }
            controller?.pushItems(items: .single(ContextController.Items(content: .list(self.usageItems(icon: icon)))))
        }
        // Read again each second while shown, so "warm" goes when the cache expires.
        items.append(.custom(TickingContextItem({
            return ContextMenuActionItem(text: "Usage", textLayout: .secondLineWithAttributedValue(usageSummary(store.usage(id), accent: accent)), icon: icon("Chat/Context Menu/Info"), action: openUsage)
        }), false))
        // Arrows meeting in a box: the context pressed into a summary.
        if self.compactingSince != nil {
            // Its pill in the chat shows it working; the chat goes on meanwhile.
            items.append(.action(ContextMenuActionItem(text: "Compacting Context…", textColor: .disabled, icon: icon("Chat/Context Menu/CellMergeV"), action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)))
        } else {
            items.append(.action(ContextMenuActionItem(text: "Compact Context", icon: icon("Chat/Context Menu/CellMergeV"), action: { _, f in
                f(.default)
                store.compact(id)
            })))
        }

        let source = ChatTitleContextReferenceSource(view: self.titleView, contentArea: self.controllerNode.view.convert(self.controllerNode.frameForVisibleArea(), to: nil))
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .reference(source), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.presentInGlobalOverlay(controller)
    }

    /// The Subagents submenu: each with its avatar and how long it has worked, as it goes, in the accent color while it
    /// works (as Telegram's "typing"); the most recently active first. A tap opens its conversation. The task is its
    /// title there: in a menu row it would be cut to a few words.
    private func subagentItems(icon: @escaping (String) -> (PresentationTheme) -> UIImage?) -> Signal<ContextController.Items, NoError> {
        var items: [ContextMenuItem] = [.action(ContextMenuActionItem(text: self.theme.presentationStrings.Common_Back, icon: icon("Chat/Context Menu/Back"), iconPosition: .left, action: { controller, _ in
            controller?.popItems()
        })), .separator]
        let accent = self.theme.presentationData.theme.list.itemAccentColor
        let subagents = self.context.store.subagents(of: self.conversationId).sorted { a, b in
            if a.busy != b.busy {
                return a.busy
            }
            return (a.last?.date ?? .distantPast) > (b.last?.date ?? .distantPast)
        }
        for dialog in subagents {
            let name = dialog.title.components(separatedBy: ": ").first ?? dialog.title
            let avatar = Avatar.image(letters: Avatar.letters(name), colorIndex: dialog.id, diameter: 30.0)
            let child = dialog.id
            let action: (ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void = { [weak self] _, f in
                f(.default)
                guard let self else {
                    return
                }
                (self.navigationController as? NavigationController)?.pushViewController(ChatController(context: self.context, conversationId: child))
            }
            // Read again each second while shown: its state, and its call in this transcript, for the time.
            items.append(.custom(TickingContextItem({ [weak self] in
                let busy = self?.context.store.subagents(of: self?.conversationId ?? 0).first(where: { $0.id == child })?.busy ?? dialog.busy
                var call: SubagentCall?
                for message in self?.lastState?.messages ?? [] {
                    if let found = message.tool?.subagent, found.name == name, found.kind == .spawn || found.kind == .send {
                        call = found
                    }
                }
                let status: NSAttributedString
                if busy {
                    status = NSAttributedString(string: call?.startedAt.map { "working · \(formatElapsed(Date().timeIntervalSince($0)))" } ?? "working", attributes: [.foregroundColor: accent])
                } else if let duration = call?.duration {
                    status = NSAttributedString(string: "worked \(formatDuration(duration))")
                } else {
                    status = NSAttributedString(string: "idle")
                }
                return ContextMenuActionItem(text: name, textLayout: .secondLineWithAttributedValue(status), icon: { _ in nil }, iconSource: ContextMenuActionItemIconSource(size: CGSize(width: 30.0, height: 30.0), cornerRadius: 15.0, signal: .single(avatar)), iconPosition: .left, action: action)
            }), false))
        }
        return .single(ContextController.Items(content: .list(items)))
    }

    /// The usage submenu, in groups: how full the context is and what the chat cost; its prompt cache, live, and what
    /// keeping it warm cost and saved; the tokens; the models, when it used several.
    private func usageItems(icon: @escaping (String) -> (PresentationTheme) -> UIImage?) -> [ContextMenuItem] {
        let store = self.context.store
        let id = self.conversationId
        let usage = store.usage(id)
        let accent = self.theme.presentationData.theme.list.itemAccentColor
        var items: [ContextMenuItem] = [.action(ContextMenuActionItem(text: self.theme.presentationStrings.Common_Back, icon: icon("Chat/Context Menu/Back"), iconPosition: .left, action: { controller, _ in
            controller?.popItems()
        })), .separator]
        func row(_ title: String, _ value: String) {
            items.append(.action(ContextMenuActionItem(text: title, textLayout: .secondLineWithValue(value), icon: { _ in nil }, action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)))
        }
        row("Context", contextDescription(usage))
        row("Cost", formatCost(usage.cost))
        if let cache = usage.cache {
            items.append(.separator)
            items.append(.custom(TickingContextItem({
                let current = store.usage(id).cache ?? cache
                return ContextMenuActionItem(text: "Prompt Cache", textLayout: .secondLineWithAttributedValue(promptCacheStatus(current, accent: accent)), icon: { _ in nil }, action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)
            }), false))
            if cache.warms > 0 {
                var kept = "\(cache.warms)× · \(formatCost(cache.cost))"
                if cache.saved > 0.0 {
                    kept += " · saved \(formatCost(cache.saved))"
                }
                row("Kept Warm", kept)
            }
        }
        let total = usage.total
        items.append(.separator)
        row("Tokens", "\(formatTokens(total.input)) in · \(formatTokens(total.output)) out")
        row("Cached", "\(formatTokens(total.cacheRead)) read · \(formatTokens(total.cacheWrite)) written")
        if usage.models.count > 1 {
            items.append(.separator)
            for (model, value) in usage.models {
                row(model.split(separator: "/").last.map(String.init) ?? model, "\(formatCost(value.cost)) · \(formatTokens(value.input + value.output + value.cacheRead + value.cacheWrite)) tokens")
            }
        }
        return items
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
        if message.role == .user, let outgoingId = message.outgoingId, message.delivery != .delivered {
            // As Telegram's menu for a message that did not go: Resend and Delete; one on its way can be deleted.
            let store = self.context.store
            let id = self.conversationId
            if case let .failed(reason) = message.delivery {
                items.append(.action(ContextMenuActionItem(text: reason, textLayout: .multiline, textFont: .small, icon: { _ in nil }, action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)))
                items.append(.separator)
                items.append(.action(ContextMenuActionItem(text: strings.Conversation_MessageDialogRetry, icon: { theme in
                    generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Resend"), color: theme.actionSheet.primaryTextColor)
                }, action: { _, f in
                    f(.dismissWithoutContent)
                    store.resend(outgoingId, in: id)
                })))
            }
            if !message.text.isEmpty {
                items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuCopy, icon: { theme in
                    generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.actionSheet.primaryTextColor)
                }, action: { [weak self] _, f in
                    f(.default)
                    self?.perform(.copy, on: message)
                })))
            }
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuDelete, textColor: .destructive, icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.destructiveActionTextColor)
            }, action: { _, f in
                f(.dismissWithoutContent)
                if case .failed = message.delivery {
                    store.discard(outgoingId, in: id)
                } else {
                    store.withdraw(QueuedMessage(id: outgoingId, mode: .steer, text: message.text, imageCount: 0, isSending: true, outgoingId: outgoingId, submissionId: nil), in: id, restore: false)
                }
            })))
            let source = ChatMessageContextExtractedContentSource(chatNode: self.controllerNode, messageId: message.id)
            let controller = makeContextController(presentationData: self.theme.presentationData, source: .extracted(source), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: gesture)
            self.presentInGlobalOverlay(controller)
            return
        }
        if !message.text.isEmpty {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuCopy, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                f(.default)
                self?.perform(.copy, on: message)
            })))
        }
        if case .failed = message.service {
            items.append(.action(ContextMenuActionItem(text: "Retry", icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Reload"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                f(.default)
                self?.retryAfterError(message)
            })))
        }
        if case .compacted = message.service, let entryId = message.entryId {
            // As an edit of an earlier message: the conversation goes on in a copy, from before the summary, with
            // everything the model saw then.
            items.append(.action(ContextMenuActionItem(text: "Restore Full Context", textLayout: .secondLineWithValue("Continues in a copy"), icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Reload"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                f(.default)
                self?.restoreFullContext(before: entryId)
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
        if message.role != .service {
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
        }

        let source = ChatMessageContextExtractedContentSource(chatNode: self.controllerNode, messageId: message.id)
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .extracted(source), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: gesture)
        self.presentInGlobalOverlay(controller)
    }

    /// Retry after a model error: the message before it, sent again. It is what happens anyway: the server's own
    /// retries are over, and the model never read the failed answer.
    private func retryAfterError(_ error: ChatMessage) {
        let messages = self.lastState?.messages ?? []
        guard let index = messages.firstIndex(where: { $0.id == error.id }), let user = messages[..<index].last(where: { $0.role == .user }) else {
            return
        }
        self.context.store.send(user.text, attachments: user.attachments, to: self.conversationId)
    }

    // MARK: - Search in the chat

    private var searchNavigationNode: ChatSearchNavigationContentNode?
    private let chatSearchDisposable = MetaDisposable()
    private var chatSearchResult = ChatSearchResult(entryIds: [], terms: [])
    private var chatSearchIndex = 0

    /// Telegram's chat search: the field in place of the title, the results' count and arrows in place of the input
    /// panel, and the matched words marked in the messages, the newest result first.
    func activateChatSearch() {
        guard self.searchNavigationNode == nil else {
            return
        }
        let node = ChatSearchNavigationContentNode(theme: self.theme.presentationTheme, strings: self.theme.presentationStrings)
        node.textUpdated = { [weak self] query in
            self?.updateChatSearch(query)
        }
        node.dismiss = { [weak self] in
            self?.deactivateChatSearch()
        }
        self.searchNavigationNode = node
        self.controllerNode.inputPanelNode.deactivateInput()
        self.navigationBar?.setContentNode(node, animated: true)
        self.controllerNode.searchPanelState = (0, -1, false)
        self.controllerNode.searchStep = { [weak self] delta in
            self?.stepChatSearch(delta)
        }
        self.requestLayout(transition: .animated(duration: 0.4, curve: .spring))
        node.activate()
    }

    func deactivateChatSearch() {
        guard let node = self.searchNavigationNode else {
            return
        }
        node.deactivate()
        self.searchNavigationNode = nil
        self.chatSearchDisposable.set(nil)
        self.chatSearchResult = ChatSearchResult(entryIds: [], terms: [])
        self.navigationBar?.setContentNode(nil, animated: true)
        self.controllerNode.searchPanelState = nil
        self.controllerNode.searchHighlight = nil
        self.requestLayout(transition: .animated(duration: 0.4, curve: .spring))
    }

    private func updateChatSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            self.chatSearchDisposable.set(nil)
            self.chatSearchResult = ChatSearchResult(entryIds: [], terms: [])
            self.searchNavigationNode?.isSearching = false
            self.controllerNode.searchPanelState = (0, -1, false)
            self.controllerNode.searchHighlight = nil
            return
        }
        self.searchNavigationNode?.isSearching = true
        self.controllerNode.searchPanelState = (0, self.chatSearchResult.entryIds.count, true)
        let signal: Signal<ChatSearchResult, NoError> = (Signal<ChatSearchResult, NoError>.complete() |> delay(0.2, queue: Queue.mainQueue())) |> then(self.context.store.searchConversation(self.conversationId, query: query, typing: !text.hasSuffix(" ")))
        self.chatSearchDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else {
                return
            }
            self.searchNavigationNode?.isSearching = false
            self.chatSearchResult = result
            self.chatSearchIndex = 0
            self.controllerNode.searchHighlight = (entryIds: Set(result.entryIds), terms: result.terms)
            self.controllerNode.searchPanelState = (0, result.entryIds.count, false)
            self.showChatSearchResult()
        }))
    }

    /// Up is older, Down newer.
    private func stepChatSearch(_ delta: Int) {
        let index = self.chatSearchIndex + delta
        guard index >= 0, index < self.chatSearchResult.entryIds.count else {
            return
        }
        self.chatSearchIndex = index
        self.controllerNode.searchPanelState = (index, self.chatSearchResult.entryIds.count, false)
        self.showChatSearchResult()
    }

    private func showChatSearchResult() {
        guard self.chatSearchIndex < self.chatSearchResult.entryIds.count else {
            return
        }
        let entryId = self.chatSearchResult.entryIds[self.chatSearchIndex]
        if !self.controllerNode.scroll(toEntry: entryId, kind: .assistant, animated: true) {
            // Further back than loaded: the history loads until it is there.
            self.controllerNode.focus = ChatFocus(entryId: entryId, terms: self.chatSearchResult.terms)
            self.context.store.loadHistory(self.conversationId, through: entryId)
        }
    }

    /// Restore Full Context: a copy of this chat from before a compaction, opened over it; it exists once something
    /// is sent in it.
    private func restoreFullContext(before entryId: Int) {
        guard let forkId = self.context.store.forkBefore(entryId: entryId, in: self.conversationId), let navigationController = self.navigationController as? NavigationController else {
            return
        }
        let chat = ChatController(context: self.context, conversationId: forkId)
        navigationController.pushViewController(chat)
        Queue.mainQueue().after(0.5) {
            chat.presentToast(.info(title: nil, text: "A copy from before the summary, with the full context", timeout: nil, customUndoText: nil))
        }
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
            self.presentToast(.copy(text: selected.count == 1 ? self.theme.presentationStrings.Conversation_TextCopied : "\(selected.count) messages copied to clipboard"))
        case .share:
            let text = selected.map(\.text).joined(separator: "\n\n")
            self.controllerNode.setSelection(nil)
            self.share(text: text)
        default:
            break
        }
    }

    // MARK: - Attachments

    /// Telegram's attachment menu (TelegramAttachmentMenu.swift); files and the full camera use the system pickers. What
    /// is written in the field, a new message or an edit, moves into the menu's caption, and goes with the photos; a menu
    /// closed without sending puts the caption back. The field is hidden while the menu is up: its glass send button,
    /// which no alpha fades, showed past the sheet's corner.
    private func openAttachments() {
        let inputPanel = self.controllerNode.inputPanelNode
        inputPanel.deactivateInput()
        let written = inputPanel.text
        var caption = written
        var sent = false
        let menu = makeTelegramAttachmentMenu(context: self.context.telegram, presentationData: self.theme.presentationData, initialCaption: written.trimmingCharacters(in: .whitespacesAndNewlines), captionChanged: { text in
            caption = text
        }, completion: { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case let .photos(images, pickedCaption):
                guard !images.isEmpty else {
                    return
                }
                sent = true
                let attachments = images.map { MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .image($0)) }
                let text = (pickedCaption.isEmpty ? caption : pickedCaption).trimmingCharacters(in: .whitespacesAndNewlines)
                if !written.isEmpty && self.editingMessageId == nil {
                    inputPanel.setText("")
                }
                self.send(text: text, attachments: attachments)
            case .files:
                let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                documentPicker.delegate = self
                self.view.window?.rootViewController?.present(documentPicker, animated: true)
            case .camera:
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    self.presentToast(.info(title: nil, text: "No camera on this device", timeout: nil, customUndoText: nil))
                    return
                }
                let camera = UIImagePickerController()
                camera.sourceType = .camera
                camera.delegate = self
                self.view.window?.rootViewController?.present(camera, animated: true)
            }
        })
        inputPanel.isHidden = true
        menu.willDismiss = { [weak inputPanel] in
            inputPanel?.isHidden = false
        }
        let dismissed = menu.didDismiss
        menu.didDismiss = { [weak inputPanel] in
            dismissed()
            inputPanel?.isHidden = false
            if !sent, caption.trimmingCharacters(in: .whitespacesAndNewlines) != written.trimmingCharacters(in: .whitespacesAndNewlines) {
                inputPanel?.setText(caption)
            }
        }
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
        /// "connecting...", in Telegram's input control color.
        case network(String)
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
        self.update(title: title, status: subtitle.map { isActive ? .working($0) : .info($0) })
    }

    func update(title: String, status: Status?) {
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
            case let .network(text):
                state = .info(NSAttributedString(string: text, font: Font.regular(12.0), textColor: self.theme.presentationTheme.chat.inputPanel.inputControlColor), .generic)
            case nil:
                state = .none
            }
            // Telegram's subtitle slides from one state to the next.
            let _ = self.activityNode.transitionToState(state, animation: animated ? .slide : .none)
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
            component: AnyComponent(AnimatedTextComponent(font: Font.semibold(16.0), color: self.theme.navigationBar.primaryTextColor, items: self.titleItems, noDelay: false, animateScale: true, animateSlide: true, blur: true)),
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

/// A view in the input panel as a context menu's anchor: the send button, the queue panel. The menu stays above the
/// keyboard, as Telegram's send menu does.
private final class ChatViewContextReferenceSource: ContextReferenceContentSource {
    let keepInPlace: Bool = false
    private weak var view: UIView?

    init(view: UIView) {
        self.view = view
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

/// Tokens as pi's footer counts them: 950, 41.2k, 1.3M.
func formatTokens(_ count: Int) -> String {
    if count < 1_000 {
        return "\(count)"
    } else if count < 10_000 {
        return String(format: "%.1fk", Double(count) / 1_000.0).replacingOccurrences(of: ".0k", with: "k")
    } else if count < 1_000_000 {
        return "\(Int((Double(count) / 1_000.0).rounded()))k"
    } else {
        return String(format: "%.1fM", Double(count) / 1_000_000.0).replacingOccurrences(of: ".0M", with: "M")
    }
}

func formatCost(_ cost: Double) -> String {
    if cost == 0.0 {
        return "$0"
    } else if cost < 0.01 {
        return String(format: "$%.4f", cost)
    } else {
        return String(format: "$%.2f", cost)
    }
}

/// "21% · 41k of 200k", or what is known of it.
private func contextDescription(_ usage: ConversationUsage) -> String {
    guard let tokens = usage.contextTokens else {
        return "Empty"
    }
    guard let window = usage.contextWindow, let percent = usage.contextPercent else {
        return "\(formatTokens(tokens)) tokens"
    }
    return "\(percent)% · \(formatTokens(tokens)) of \(formatTokens(window))"
}

/// The usage row's second line: how full the context is, the spend, and "warm" in the accent color while the prompt
/// cache lasts. The numbers behind them are a level down.
private func usageSummary(_ usage: ConversationUsage, accent: UIColor) -> NSAttributedString {
    let context = usage.contextPercent.map { "\($0)%" } ?? (usage.contextTokens == nil ? "Empty" : "\(formatTokens(usage.contextTokens ?? 0)) tokens")
    let summary = NSMutableAttributedString(string: "\(context) · \(formatCost(usage.cost))")
    if usage.cache?.isWarm() == true {
        summary.append(NSAttributedString(string: " · "))
        summary.append(NSAttributedString(string: "warm", attributes: [.foregroundColor: accent]))
    }
    return summary
}

/// "Warm · 4:12 left" in the accent color while it lasts, then how long ago it expired.
private func promptCacheStatus(_ cache: PromptCache, accent: UIColor, now: Date = Date()) -> NSAttributedString {
    let left = cache.expiresAt.timeIntervalSince(now)
    if left > 0.0 {
        let seconds = Int(left.rounded(.up))
        return NSAttributedString(string: String(format: "Warm · %d:%02d left", seconds / 60, seconds % 60), attributes: [.foregroundColor: accent])
    }
    let ago = -left
    if ago < 60.0 {
        return NSAttributedString(string: "Expired just now")
    } else if ago < 3600.0 {
        return NSAttributedString(string: "Expired \(Int(ago / 60.0)) min ago")
    } else if ago < 86400.0 {
        return NSAttributedString(string: "Expired \(Int(ago / 3600.0)) h ago")
    }
    return NSAttributedString(string: "Expired")
}
