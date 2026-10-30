import UIKit
import AsyncDisplayKit
import Display
import UndoUI
import SwiftSignalKit
import GlassBackgroundComponent
import UniformTypeIdentifiers
import ComponentFlow
import AnimatedTextComponent
import ContextUI
import TelegramPresentationData
import SafariServices
import MoreButtonNode

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
    /// The tool card whose Show All was tapped last, and when: that tap also selects the card's row.
    private var toolTextOpened: (id: Int, at: Double)?
    /// New Chat and ⋯, on the bar's right; none in a preview.
    private var headerButtons: ChatHeaderButtonsNode?
    private var modelsDisposable: Disposable?
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
        if !isPreview {
            let buttons = ChatHeaderButtonsNode(theme: context.theme)
            buttons.composeNode.tapped = { [weak self] in
                self?.startNewChat(server: nil)
            }
            // Held: where to start one, when there is a choice (ChatListController.openComposeMenu).
            if context.store.servers.count > 1 {
                buttons.composeNode.contextAction = { [weak self, weak buttons] gesture in
                    guard let self, let buttons else {
                        return
                    }
                    self.openComposeMenu(sourceView: buttons.composeNode.referenceNode.view, gesture: gesture)
                }
            }
            buttons.moreNode.action = { [weak self] node, gesture in
                self?.openChatMenu(sourceView: node.view, gesture: gesture)
            }
            self.headerButtons = buttons
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(customDisplayNode: buttons)
            // The menu names the model; its name comes with the server's model list.
            self.modelsDisposable = context.store.server(of: conversationId)?.models().start(next: { [weak self] _ in
                guard let self else {
                    return
                }
                self.updateTitle(busy: self.lastState?.busy ?? false)
            })
        }
        self.updateTitle(busy: false)
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
        self.modelsDisposable?.dispose()
        self.settingsDisposable?.dispose()
    }

    private var seenCompactionFailure: Int??
    private var titleTimer: SwiftSignalKit.Timer?

    /// When the compaction now running began, as the transcript's pill says.
    private var compactingSince: Date? {
        for message in (self.lastState?.messages ?? []).reversed() {
            // Not one made and waiting for a run's step: the run is what holds the user up then.
            if case let .compacting(since, waiting) = message.service, !waiting {
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
        self.headerButtons?.update(theme: theme)
        if self.isNodeLoaded {
            self.controllerNode.updateTheme(theme)
        }
    }

    /// For checking the title's pill: `-titleStatus "compacting:750"` shows that status, working that many seconds.
    private static let forcedTitleStatus: ChatTitleView.Status? = UserDefaults.standard.string(forKey: "titleStatus").map { value in
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        return .working(parts[0], elapsed: parts.count > 1 ? Double(parts[1]) : nil)
    }

    private func updateTitle(busy: Bool) {
        if let ids = self.isNodeLoaded ? self.controllerNode.selectedIds : nil {
            self.titleView.update(selectedCount: ids.count)
            return
        }
        guard let dialog = self.context.store.dialog(self.conversationId) else {
            return
        }
        // As Telegram's ChatTitleComponent: the connection's state until it is back, then what the agent does.
        let strings = self.theme.presentationStrings
        let status: ChatTitleView.Status?
        switch self.connectionStatus {
        case .waitingForNetwork:
            status = .network(strings.ChatState_WaitingForNetwork)
        case .connecting, .refused:
            status = .network(strings.ChatState_Connecting)
        case .updating:
            status = .network(strings.ChatState_Updating)
        case .online:
            // What holds the user up: the agent's work (a compaction in the background meanwhile has its card in the
            // chat), unless the run waits for a compaction; a compaction when the agent is idle.
            if busy, self.lastState?.compactionBlocksRun == true, let since = self.compactingSince {
                status = .working("compacting", elapsed: Date().timeIntervalSince(since))
            } else if busy {
                // How long this run has worked, as it goes.
                let elapsed = self.lastState?.runStartedAt.map { Date().timeIntervalSince($0) } ?? 0.0
                status = .working("working", elapsed: elapsed)
            } else if let since = self.compactingSince {
                let elapsed = Date().timeIntervalSince(since)
                status = .working("compacting", elapsed: elapsed)
            } else if let activity = dialog.subagentActivity {
                // Its background subagents, as Telegram's title says who is typing.
                status = .working(activity, elapsed: nil)
            } else {
                status = nil
            }
        }
        self.titleView.update(status: ChatController.forcedTitleStatus ?? status)
        self.updateNewChatCard(dialog: dialog)
        // Who the field writes to, and while the agent works, that Send steers it.
        let name = self.modelName()
        // A message sent during a compaction is answered at once, on the whole context: a steer only while a run goes.
        let verb = busy ? "Steer" : "Message"
        if self.isNodeLoaded {
            self.controllerNode.inputPanelNode.placeholder = name.isEmpty ? verb : "\(verb) \(name)"
        }
    }

    /// A chat not created yet shows which server it will be on (with several) and its model, each a tap from changing.
    private func updateNewChatCard(dialog: DialogModel) {
        guard dialog.id < 0, !self.isPreview else {
            self.controllerNode.newChatCard = nil
            return
        }
        let store = self.context.store
        let agent = store.agent(self.conversationId)
        let server = store.servers.count > 1 ? store.server(dialog.serverSlot) : nil
        self.controllerNode.newChatCard = NewChatCardNode.Content(
            server: server.map { ($0.name, URL(string: $0.address)?.host ?? $0.address) },
            model: self.modelName(),
            modelDetail: "Thinking: \(thinkingTitle(agent.thinkingLevel ?? "off"))"
        )
    }

    /// The chat's model by name ("Claude Opus 5.5"), from the server's list once it has come; its ID until then.
    private func modelName() -> String {
        let store = self.context.store
        let agent = store.agent(self.conversationId)
        let info = agent.provider.flatMap { provider in agent.modelId.flatMap { store.server(of: self.conversationId)?.cachedModel(provider: provider, id: $0) } }
        return info.map { modelDisplayName($0.name) } ?? agent.modelId ?? store.dialog(self.conversationId)?.model ?? ""
    }

    /// The new chat's server row: the servers to move it to, before its first message.
    private func chooseServer(sourceView: UIView) {
        let store = self.context.store
        let current = store.dialog(self.conversationId)?.serverSlot
        var items: [ContextMenuItem] = []
        for server in store.servers {
            let checked = server.slot == current
            items.append(.action(ContextMenuActionItem(text: server.name, icon: { theme in
                return checked ? generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor) : nil
            }, action: { [weak self] _, f in
                f(.default)
                guard let self else {
                    return
                }
                self.saveInputDraft()
                let newId = store.relocateDraft(self.conversationId, toServer: server.slot)
                if newId != self.conversationId {
                    self.retarget(to: newId)
                }
            })))
        }
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .reference(ViewContextReferenceSource(view: sourceView)), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.presentInGlobalOverlay(controller)
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
        // The position also survives the app being suspended and killed with the chat open.
        NotificationCenter.default.addObserver(self, selector: #selector(self.saveScrollState), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        node.sendMessage = { [weak self] text in
            self?.send(text: text, attachments: [])
        }
        node.newChatServerTapped = { [weak self] view in
            self?.chooseServer(sourceView: view)
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
            if case let .failed(_, _, retry) = message.service {
                if retry {
                    self.retryAfterError(message)
                }
            } else if let child = message.tool?.childConversationId {
                // A subagent's own conversation, live, as any chat.
                (self.navigationController as? NavigationController)?.pushViewController(ChatController(context: self.context, conversationId: child))
            } else {
                // After the tap's own handlers: one on Show All opens the viewer, and leaves the card as it is.
                DispatchQueue.main.async {
                    if let shown = self.toolTextOpened, shown.id == message.id, CACurrentMediaTime() - shown.at < 0.5 {
                        return
                    }
                    self.controllerNode.toggleExpanded(message.id)
                }
            }
        }
        node.setToolTextHandler { [weak self] message in
            guard let self else {
                return
            }
            self.toolTextOpened = (message.id, CACurrentMediaTime())
            (self.navigationController as? NavigationController)?.pushViewController(ToolTextController(context: self.context, message: message))
        }
        node.setHistoryLinkHandler { [weak self] message, link in
            guard let self else {
                return
            }
            // The tap is the link's, not the card's: it stays as it is.
            self.toolTextOpened = (message.id, CACurrentMediaTime())
            self.openLink(link)
        }
        node.presentInGlobalOverlay = { [weak self] controller, arguments in
            self?.presentInGlobalOverlay(controller, with: arguments)
        }
        node.openImage = { [weak self] attachmentId in
            self?.openImage(attachmentId: attachmentId)
        }
        node.linkReferences = LinkReferenceResolver(store: self.context.store)
        node.linkReferencesUpdated = { [weak self] in
            guard let self else {
                return
            }
            self.updateLinkPreview(self.controllerNode.inputPanelNode.text)
        }
        node.setLinkHandlers(open: { [weak self] url in
            self?.openLink(url)
        }, menu: { [weak self] url, messageId, recognizer in
            self?.openLinkMenu(url, messageId: messageId, recognizer: recognizer)
        })
        let store = self.context.store
        let conversationId = self.conversationId
        node.setFileHandlers(status: { file in
            return store.fileStatus(file, in: conversationId)
        }, open: { [weak self] file, status in
            self?.openFile(file, status: status)
        })
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
            // Dictation starts: the engine asks for the microphone itself (Chat/AquaDictation.swift).
        }
        node.inputPanelNode.dictationFailed = { [weak self] message in
            self?.presentToast(.info(title: nil, text: message, timeout: nil, customUndoText: nil))
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
            node.inputPanelNode.textChanged = { [weak self] text in
                self?.saveInputDraft()
                self?.updateLinkPreview(text)
            }
            node.inputPanelNode.linkPreviewClosed = { [weak self] preview in
                self?.closedLinkPreviews.insert(preview.url)
                self?.controllerNode.inputPanelNode.setLinkPreview(nil)
            }
        }

        if self.isPreview {
            node.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.previewTapGesture)))
        }

        self.subscribeConversation()
        self.displayNodeDidLoad()
        self.updateTitle(busy: self.lastState?.busy ?? false)
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
                // Just above the transcript, as Telegram's chat adds it: under the input panel and the bar, which the
                // photo goes behind on its way back as the message itself does.
                guard let self else {
                    return
                }
                let history = self.controllerNode.historyNode.view
                history.superview?.insertSubview(view, aboveSubview: history)
            })
        })
        self.present(gallery, in: .window(.root), with: arguments, blockInteraction: true)
    }

    /// Links whose preview was closed, while the chat is open.
    private var closedLinkPreviews = Set<String>()

    /// The field's first tau link, previewed above it as Telegram previews a link.
    private func updateLinkPreview(_ text: String) {
        guard let resolver = self.controllerNode.linkReferences else {
            return
        }
        let preview = LinkReferenceResolver.links(in: text).first { !self.closedLinkPreviews.contains($0) }.flatMap { resolver.reference($0) }
        self.controllerNode.inputPanelNode.setLinkPreview(preview)
    }

    /// A link in the chat: the web in Safari's view over the app, as Telegram's in-app browser opens it; mail and the
    /// rest in their own apps.
    func openLink(_ string: String) {
        guard let url = URL(string: string) else {
            return
        }
        switch url.scheme?.lowercased() {
        case "tau":
            // tau's own (TauLink): the app routes it, as one from outside.
            self.view.endEditing(true)
            UIApplication.shared.open(url)
        case "http", "https":
            self.view.endEditing(true)
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = self.theme.accentColor
            self.view.window?.rootViewController?.present(safari, animated: true)
        default:
            UIApplication.shared.open(url)
        }
    }

    /// A long press on a link: Telegram's link menu (ChatControllerOpenLinkContextMenu), the message lifted with it.
    private func openLinkMenu(_ string: String, messageId: Int, recognizer: TapLongTapOrDoubleTapGestureRecognizer) {
        guard !self.isPreview, let url = URL(string: string) else {
            return
        }
        self.controllerNode.inputPanelNode.deactivateInput()
        let strings = self.theme.presentationStrings
        let icon: (String) -> (PresentationTheme) -> UIImage? = { name in
            return { theme in generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor) }
        }
        let isMail = url.scheme?.lowercased() == "mailto"
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        // What it reads as: an address without its mailto:.
        let shown = isMail ? String(string.dropFirst("mailto:".count)) : string
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: strings.Conversation_LinkDialogOpen, icon: icon(isWeb ? "Chat/Context Menu/Browser" : "Chat/Context Menu/Globe"), action: { [weak self] _, f in
            f(.default)
            self?.openLink(string)
        })))
        if isWeb {
            items.append(.action(ContextMenuActionItem(text: strings.Chat_ContextMenu_OpenInBrowser, icon: icon("Chat/Context Menu/Globe"), action: { _, f in
                f(.default)
                UIApplication.shared.open(url)
            })))
        }
        items.append(.action(ContextMenuActionItem(text: isMail ? strings.Conversation_ContextMenuCopyEmail : strings.Conversation_ContextMenuCopyLink, icon: icon("Chat/Context Menu/Copy"), action: { [weak self] _, f in
            f(.default)
            guard let self else {
                return
            }
            UIPasteboard.general.string = shown
            self.controllerNode.presentToast?(isMail ? .copy(text: strings.Conversation_EmailCopied) : .linkCopied(title: nil, text: strings.Conversation_LinkCopied))
        })))
        if isWeb {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_AddToReadingList, icon: icon("Chat/Context Menu/ReadingList"), action: { _, f in
                f(.default)
                try? SSReadingList.default()?.addItem(with: url, title: nil, previewText: nil)
            })))
        }
        let source = ChatMessageContextExtractedContentSource(chatNode: self.controllerNode, messageId: messageId)
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .extracted(source), items: .single(ContextController.Items(content: .list(items))), recognizer: recognizer, gesture: nil)
        self.presentInGlobalOverlay(controller)
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

    /// For UI tests: `-attachFile <path> [-attachCaption <text>]` sends that file from the first chat opened, as the
    /// document picker gives one (docs/files.md).
    private static var attachedTestFile = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !self.isPreview, !ChatController.attachedTestFile, let path = UserDefaults.standard.string(forKey: "attachFile") {
            ChatController.attachedTestFile = true
            let attachment = MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .file(FileAttachment(local: URL(fileURLWithPath: path))))
            self.send(text: UserDefaults.standard.string(forKey: "attachCaption") ?? "", attachments: [attachment])
        }
        if !self.isPreview {
            self.isOnScreen = true
            self.context.store.markSeen(self.conversationId)
            let id = (self.context.store as? MultiStore)?.realId(self.conversationId) ?? self.conversationId
            LiveActivityController.shared.seen(id)
            // Its notifications have been read now, as Telegram clears a chat's on opening it.
            if id >= 0, let serverId = (self.context.store as? MultiStore)?.server(of: id)?.serverInfo?.serverId {
                PushRegistration.shared.clearDelivered(serverId: serverId, localId: MultiStore.split(id).local)
            }
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
            // Quotes as Markdown's, as elsewhere they would be (docs/quotes.md).
            UIPasteboard.general.string = TauQuote.markdown(message.text)
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

    /// New Chat from the bar, on `server` or this chat's: a fresh chat over this one, so Back comes back to it. Over a
    /// new chat nothing was sent to yet, which leaves no chat behind, it takes that one's place instead.
    private func startNewChat(server: Int?) {
        guard let navigationController = self.navigationController as? NavigationController, let dialog = self.context.store.dialog(self.conversationId) else {
            return
        }
        self.controllerNode.inputPanelNode.deactivateInput()
        let id = self.context.store.createConversation(server: server ?? dialog.serverSlot)
        let chat = ChatController(context: self.context, conversationId: id)
        let isUnsent = self.conversationId < 0 && self.lastState?.messages.isEmpty != false
        if isUnsent {
            navigationController.replaceTopController(chat, animated: true)
        } else {
            navigationController.pushViewController(chat)
        }
        Queue.mainQueue().after(0.45) {
            chat.activateInput()
        }
    }

    /// New Chat held: the servers, the one last used first, as the chat list's compose menu.
    private func openComposeMenu(sourceView: UIView, gesture: ContextGesture) {
        let store = self.context.store
        var items: [ContextMenuItem] = []
        for server in store.recentServers() {
            items.append(.action(ContextMenuActionItem(text: server.name, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Message"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                f(.default)
                self?.startNewChat(server: server.slot)
            })))
        }
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .reference(ViewContextReferenceSource(view: sourceView)), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
        self.presentInGlobalOverlay(controller)
    }

    /// The bar's ⋯: the chat's title in full, then what can be done with it and how it runs.
    private func openChatMenu(sourceView: UIView, gesture: ContextGesture?) {
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
        // For a second line of its own colors (`.secondLineWithAttributedValue`), Telegram centers only an icon given as a
        // source on both lines (ContextControllerActionsStackNode); a plain one sits on the first, out of line with the
        // other rows.
        let presentationTheme = self.theme.presentationTheme
        let centeredIcon: (String) -> ContextMenuActionItemIconSource? = { name in
            return icon(name)(presentationTheme).map { ContextMenuActionItemIconSource(size: $0.size, contentMode: .center, signal: .single($0)) }
        }
        let checkIcon: (Bool) -> (PresentationTheme) -> UIImage? = { checked in
            return { theme in checked ? generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor) : nil }
        }

        var items: [ContextMenuItem] = []
        if let dialog = store.dialog(id) {
            // Small, as Telegram's information rows, with the server's name when there are several. A tap copies the
            // chat's link (docs/links.md), to send on or to paste into another chat.
            let layout: ContextMenuActionItemTextLayout = dialog.serverName.map { .secondLineWithValue($0) } ?? .multiline
            let link = TauLink.chat(self.conversationId, store: store)
            items.append(.action(ContextMenuActionItem(text: dialog.title, textLayout: layout, textFont: .small, icon: { _ in nil }, action: link.map { link in { [weak self] _, f in
                f(.default)
                UIPasteboard.general.string = link.absoluteString
                self?.presentToast(.linkCopied(title: nil, text: self?.theme.presentationStrings.Conversation_LinkCopied ?? ""))
            } })))
            items.append(.separator)
        }
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
        let modelName = self.modelName()
        items.append(.action(ContextMenuActionItem(text: "Model", textLayout: .secondLineWithValue(modelName), icon: icon("Chat/Context Menu/Settings"), action: { [weak self] _, f in
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
                summary.insert(NSAttributedString(string: ", "), at: 0)
                summary.insert(NSAttributedString(string: "\(working) working", attributes: [.foregroundColor: self.theme.presentationData.theme.list.itemAccentColor]), at: 0)
            }
            items.append(.action(ContextMenuActionItem(text: "Subagents", textLayout: .secondLineWithAttributedValue(summary), icon: { _ in nil }, iconSource: centeredIcon("Chat/Context Menu/Bots"), action: { [weak self] controller, _ in
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
        let usageIconSource = centeredIcon("Chat/Context Menu/Info")
        items.append(.custom(TickingContextItem({
            return ContextMenuActionItem(text: "Usage", textLayout: .secondLineWithAttributedValue(usageSummary(store.usage(id), accent: accent)), icon: { _ in nil }, iconSource: usageIconSource, action: openUsage)
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

        let source = ChatTitleContextReferenceSource(view: sourceView, contentArea: self.controllerNode.view.convert(self.controllerNode.frameForVisibleArea(), to: nil))
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
                    status = NSAttributedString(string: call?.startedAt.map { "working for \(formatElapsed(Date().timeIntervalSince($0)))" } ?? "working", attributes: [.foregroundColor: accent])
                } else if let duration = call?.duration {
                    status = NSAttributedString(string: "worked for \(formatDuration(duration))")
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
        if let cache = usage.cache, cache.expiresAt != nil || cache.warms > 0 {
            items.append(.separator)
            // Only while it is the cache of the chat's model: another model, or none declaring a lifetime, has nothing
            // to tell here.
            if let expiresAt = cache.expiresAt {
                items.append(.custom(TickingContextItem({
                    let current = store.usage(id).cache?.expiresAt ?? expiresAt
                    return ContextMenuActionItem(text: "Prompt Cache", textLayout: .secondLineWithAttributedValue(promptCacheStatus(expiresAt: current, accent: accent)), icon: { _ in nil }, action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)
                }), false))
            }
            if cache.warms > 0 {
                var kept = "\(cache.warms)×, \(formatCost(cache.cost))"
                if cache.saved > 0.0 {
                    kept += ", saved \(formatCost(cache.saved))"
                }
                row("Kept Warm", kept)
            }
        }
        let total = usage.total
        items.append(.separator)
        row("Tokens", "\(formatTokens(total.input)) in, \(formatTokens(total.output)) out")
        row("Cached", "\(formatTokens(total.cacheRead)) read, \(formatTokens(total.cacheWrite)) written")
        if usage.models.count > 1 {
            items.append(.separator)
            for (model, value) in usage.models {
                row(model.split(separator: "/").last.map(String.init) ?? model, "\(formatCost(value.cost)), \(formatTokens(value.input + value.output + value.cacheRead + value.cacheWrite)) tokens")
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
        // As a channel message's: its link (docs/links.md), to send on or to paste into another chat.
        if let entryId = message.entryId, let link = TauLink.chat(self.conversationId, entry: entryId, store: self.context.store) {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuCopyLink, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Link"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                f(.default)
                guard let self else {
                    return
                }
                UIPasteboard.general.string = link.absoluteString
                self.presentToast(.linkCopied(title: nil, text: strings.Conversation_LinkCopied))
            })))
        }
        if case .failed(_, _, true) = message.service {
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
            items.append(.action(ContextMenuActionItem(text: "Continue with Full Context", textLayout: .secondLineWithValue("In a new chat, from before the summary"), icon: { theme in
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

    /// Retry after a run that ended without an answer: the run continues where it stopped (durable's continue), on
    /// the context as it is, so the message is not sent again: it stays once in the chat and in the model's context.
    private func retryAfterError(_ error: ChatMessage) {
        guard case .failed(_, _, true) = error.service, !(self.lastState?.busy ?? false) else {
            return
        }
        self.context.store.continueRun(self.conversationId)
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
        // Once typing pauses, as the chat list's search: each key cancels the wait for the one before.
        let signal: Signal<ChatSearchResult, NoError> = (Signal<ChatSearchResult, NoError>.complete() |> delay(0.25, queue: Queue.mainQueue())) |> then(self.context.store.searchConversation(self.conversationId, query: query, typing: !text.hasSuffix(" ")))
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

    /// Continue with Full Context: a copy of this chat from before a compaction, opened over it; it exists once something
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
            UIPasteboard.general.string = selected.map { TauQuote.markdown($0.text) }.joined(separator: "\n\n")
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
            case let .mediaFiles(urls, pickedCaption):
                guard !urls.isEmpty else {
                    return
                }
                sent = true
                let attachments = urls.map { MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .file(FileAttachment(local: $0))) }
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
        // Copies (`asCopy`), which the outbox copies again before they go.
        let attachments = urls.map { url -> MessageAttachment in
            return MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .file(FileAttachment(local: url)))
        }
        self.send(text: "", attachments: attachments)
    }

    /// A file's row tapped, as Telegram's: fetch it, stop fetching it, or open it in Quick Look (DocumentPreviewController),
    /// where it shares, saves to Files or opens in another app.
    private func openFile(_ file: FileAttachment, status: FileTransferStatus) {
        switch status {
        case .remote:
            self.context.store.downloadFile(file, in: self.conversationId)
        case .downloading:
            self.context.store.cancelFileDownload(file, in: self.conversationId)
        case .uploading:
            break
        case let .local(url):
            self.controllerNode.inputPanelNode.deactivateInput()
            let preview = FilePreviewController(url: url)
            self.view.window?.rootViewController?.present(preview, animated: true)
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage {
            self.send(text: "", attachments: [MessageAttachment(id: self.context.store.mintAttachmentId(), kind: .image(image))])
        }
    }
}

/// The chat's status in a glass capsule where Telegram's ChatTitleView sits: "working for 11s" after Telegram's typing
/// dots, "connecting…", or "3 Selected" while selecting. With nothing to say it is not there: the chat's title, server and
/// model are in the menu of the bar's ⋯. Text is an AnimatedTextComponent, so a count changes in place, its digits
/// rolling, while the dots go on without a restart; the capsule springs to its new width.
/// A NavigationBarTitleView, so the bar gives it all the room between its buttons (the back button's side is narrower
/// than the buttons' on the right): the capsule stays centered on the bar while it fits beside the buttons, and moves
/// over where it does not.
final class ChatTitleView: UIView, NavigationBarTitleView {
    enum Status: Equatable {
        /// "working", "compacting", "reader working", and for how long it has been at it.
        case working(String, elapsed: TimeInterval?)
        /// "connecting…", in Telegram's input control color.
        case network(String)
    }

    private var theme: TauTheme
    private let backgroundView = GlassBackgroundView()
    private let title = ComponentView<Empty>()
    private let statusText = ComponentView<Empty>()
    private let dotsLayer = TypingDotsLayer()
    private var titleItems: [AnimatedTextComponent.Item] = []
    private var status: Status?
    private var hasLayout = false
    private var showsDots = false

    init(theme: TauTheme) {
        self.theme = theme
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 240.0, height: 44.0))
        self.dotsLayer.color = theme.accentColor
        self.addSubview(self.backgroundView)
        self.backgroundView.alpha = 0.0
        // Information, not a button: it takes no taps.
        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var requestUpdate: ((ContainedViewLayoutTransition) -> Void)?

    func animateLayoutTransition() {
    }

    func updateLayout(availableSize: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        return CGSize(width: availableSize.width, height: 44.0)
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        self.dotsLayer.color = theme.accentColor
        self.layoutContent(transition: .immediate)
    }

    func update(status: Status?) {
        self.update(titleItems: [], status: status, animated: true)
    }

    /// "N Selected", with N rolling as Telegram's counters do.
    func update(selectedCount: Int) {
        self.update(titleItems: [
            AnimatedTextComponent.Item(id: AnyHashable("count"), content: .number(selectedCount, minDigits: 1)),
            AnimatedTextComponent.Item(id: AnyHashable("label"), content: .text(" Selected")),
        ], status: nil, animated: true)
    }

    private func update(titleItems: [AnimatedTextComponent.Item], status: Status?, animated: Bool) {
        guard titleItems != self.titleItems || status != self.status || !self.hasLayout else {
            return
        }
        self.titleItems = titleItems
        self.status = status
        self.layoutContent(transition: animated && self.hasLayout ? .spring(duration: 0.4) : .immediate)
    }

    /// The status as AnimatedTextComponent's items: words, then each number of the time on its own, so only the
    /// digits that change roll. `label` in place of the status's own words, cut to fit; without the time if `timed` is
    /// false; `joiner` between the words and the time.
    private static func items(_ status: Status, label: String? = nil, timed: Bool = true, joiner: String = " for ") -> [AnimatedTextComponent.Item] {
        switch status {
        case let .network(text):
            return [AnimatedTextComponent.Item(id: AnyHashable("text"), content: .text(label ?? text))]
        case let .working(text, elapsed):
            var items = [AnimatedTextComponent.Item(id: AnyHashable("label"), content: .text(label ?? text))]
            guard timed, let elapsed, elapsed >= 1.0 else {
                return items
            }
            let seconds = Int(elapsed)
            items.append(AnimatedTextComponent.Item(id: AnyHashable("for"), content: .text(joiner)))
            func number(_ id: String, _ value: Int, digits: Int, unit: String) {
                items.append(AnimatedTextComponent.Item(id: AnyHashable(id), isUnbreakable: true, content: .number(value, minDigits: digits)))
                items.append(AnimatedTextComponent.Item(id: AnyHashable(id + "-unit"), content: .text(unit)))
            }
            // As formatElapsed: 11s, 2m 05s, 1h 03m.
            if seconds < 60 {
                number("s", seconds, digits: 1, unit: "s")
            } else if seconds < 3600 {
                number("m", seconds / 60, digits: 1, unit: "m ")
                number("s", seconds % 60, digits: 2, unit: "s")
            } else {
                number("h", seconds / 3600, digits: 1, unit: "h ")
                number("m", (seconds % 3600) / 60, digits: 2, unit: "m")
            }
            return items
        }
    }

    private static let statusFont = Font.with(size: 13.0, traits: .monospacedNumbers)
    /// The capsule's height, as the bar's buttons' glass, and its margins on either side of what it says.
    private static let capsuleHeight: CGFloat = 44.0
    private static let capsuleMargin: CGFloat = 16.0

    /// How wide the items set: every digit as wide as any (the font's are), so the width changes when the time gains a
    /// digit, not as the digits roll.
    private static func width(_ items: [AnimatedTextComponent.Item]) -> CGFloat {
        let text = items.map { item -> String in
            switch item.content {
            case let .text(text):
                return text
            case let .number(value, minDigits):
                return String(repeating: "0", count: max(minDigits, String(value).count))
            case .icon:
                return "  "
            }
        }.joined()
        return ceil((text as NSString).size(withAttributes: [.font: ChatTitleView.statusFont]).width)
    }

    /// The status's items as they fit in `width`: whole, then without its time, then its words cut with "…".
    private static func fitted(_ status: Status, width: CGFloat) -> (items: [AnimatedTextComponent.Item], width: CGFloat) {
        let whole = ChatTitleView.items(status)
        let wholeWidth = ChatTitleView.width(whole)
        if wholeWidth <= width {
            return (whole, wholeWidth)
        }
        // "compacting 12m 30s".
        let short = ChatTitleView.items(status, joiner: " ")
        let shortWidth = ChatTitleView.width(short)
        if short != whole, shortWidth <= width {
            return (short, shortWidth)
        }
        let untimed = ChatTitleView.items(status, timed: false)
        let untimedWidth = ChatTitleView.width(untimed)
        if untimedWidth <= width {
            return (untimed, untimedWidth)
        }
        let text: String
        switch status {
        case let .network(value), let .working(value, _):
            text = value
        }
        var count = text.count
        while count > 1 {
            count -= 1
            let cut = String(text.prefix(count)).trimmingCharacters(in: .whitespaces) + "…"
            let items = ChatTitleView.items(status, label: cut, timed: false)
            let cutWidth = ChatTitleView.width(items)
            if cutWidth <= width {
                return (items, cutWidth)
            }
        }
        let items = ChatTitleView.items(status, label: "…", timed: false)
        return (items, ChatTitleView.width(items))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layoutContent(transition: .immediate)
    }

    private func layoutContent(transition: ComponentTransition) {
        self.hasLayout = self.bounds.width > 0.0
        let maxTextWidth = max(40.0, self.bounds.width - 24.0)
        let hasTitle = !self.titleItems.isEmpty
        let status = hasTitle ? nil : self.status
        let titleSize = self.title.update(
            transition: transition,
            component: AnyComponent(AnimatedTextComponent(font: Font.semibold(16.0), color: self.theme.navigationBar.primaryTextColor, items: self.titleItems, noDelay: false, animateScale: true, animateSlide: true, blur: true)),
            environment: {},
            containerSize: CGSize(width: maxTextWidth, height: 22.0)
        )
        var statusColor = self.theme.accentColor
        var hasDots = false
        if case .network = status {
            // Telegram's color for it, lifted where the capsule's glass would swallow it (Readability).
            statusColor = Readability.readable(self.theme.presentationTheme.chat.inputPanel.inputControlColor, on: [self.theme.navigationBar.opaqueBackgroundColor], contrast: Readability.secondary)
        } else if status != nil {
            hasDots = true
        }
        let dotsWidth: CGFloat = hasDots ? 24.0 : 0.0
        // What it says fits in the capsule, and the capsule in the title's place.
        let margin = ChatTitleView.capsuleMargin
        let fit = status.map { ChatTitleView.fitted($0, width: max(20.0, self.bounds.width - margin * 2.0 - dotsWidth)) }
        let statusSize = self.statusText.update(
            transition: transition,
            component: AnyComponent(AnimatedTextComponent(font: ChatTitleView.statusFont, color: statusColor, items: fit?.items ?? [], noDelay: true, animateScale: false, animateSlide: true, blur: false)),
            environment: {},
            containerSize: CGSize(width: max(20.0, self.bounds.width - margin * 2.0 - dotsWidth), height: 18.0)
        )

        // "N Selected" in Telegram's 44 pt title capsule, 12 pt wider than the text on each side; a status in one as
        // tall as the bar's buttons, its margins even: the capsule is as wide as the status sets (by `fitted`, not as
        // the digits roll), with what it says centered in it.
        let backgroundSize: CGSize
        if hasTitle {
            backgroundSize = CGSize(width: min(maxTextWidth, ceil(titleSize.width)) + 24.0, height: 44.0)
        } else {
            backgroundSize = CGSize(width: min(self.bounds.width, dotsWidth + (fit?.width ?? 0.0) + margin * 2.0), height: ChatTitleView.capsuleHeight)
        }
        // Centered on the bar, unless that takes it past this view's room.
        let barCenter = self.superview.map { self.convert(CGPoint(x: $0.bounds.midX, y: 0.0), from: $0).x } ?? self.bounds.midX
        let originX = max(0.0, min(self.bounds.width - backgroundSize.width, floor(barCenter - backgroundSize.width / 2.0)))
        let backgroundFrame = CGRect(origin: CGPoint(x: originX, y: floor((self.bounds.height - backgroundSize.height) / 2.0)), size: backgroundSize)
        transition.setFrame(view: self.backgroundView, frame: backgroundFrame)
        self.backgroundView.update(size: backgroundSize, cornerRadius: backgroundSize.height / 2.0, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: transition)
        // It comes and goes as Telegram's glass does: a fade and a little scale.
        let shown = hasTitle || status != nil
        transition.setAlpha(view: self.backgroundView, alpha: shown ? 1.0 : 0.0)
        transition.setScale(view: self.backgroundView, scale: shown ? 1.0 : 0.8)

        let titleFrame = CGRect(origin: CGPoint(x: floor((backgroundSize.width - titleSize.width) / 2.0), y: floor((backgroundSize.height - titleSize.height) / 2.0)), size: titleSize)
        if let titleView = self.title.view {
            if titleView.superview == nil {
                self.backgroundView.contentView.addSubview(titleView)
                titleView.frame = titleFrame
            }
            transition.setFrame(view: titleView, frame: titleFrame)
            transition.setAlpha(view: titleView, alpha: hasTitle ? 1.0 : 0.0)
        }
        let contentWidth = dotsWidth + statusSize.width
        let statusOrigin = CGPoint(x: floor((backgroundSize.width - contentWidth) / 2.0), y: floor((backgroundSize.height - statusSize.height) / 2.0))
        let dotsFrame = CGRect(origin: CGPoint(x: statusOrigin.x, y: floor((backgroundSize.height - TypingDotsLayer.size.height) / 2.0)), size: TypingDotsLayer.size)
        // In the hierarchy only while there is a status: their animation keeps the screen refreshing, seen or not.
        self.showsDots = hasDots
        if hasDots && self.dotsLayer.superlayer == nil {
            self.backgroundView.contentView.layer.addSublayer(self.dotsLayer)
            self.dotsLayer.frame = dotsFrame
            self.dotsLayer.opacity = 0.0
        }
        transition.setFrame(layer: self.dotsLayer, frame: dotsFrame)
        transition.setAlpha(layer: self.dotsLayer, alpha: hasDots ? 1.0 : 0.0, completion: { [weak self] _ in
            guard let self, !self.showsDots else {
                return
            }
            self.dotsLayer.removeFromSuperlayer()
        })
        if let statusView = self.statusText.view {
            let statusFrame = CGRect(origin: CGPoint(x: statusOrigin.x + dotsWidth, y: statusOrigin.y), size: statusSize)
            if statusView.superview == nil {
                self.backgroundView.contentView.addSubview(statusView)
                statusView.frame = statusFrame
            }
            transition.setFrame(view: statusView, frame: statusFrame)
            transition.setAlpha(view: statusView, alpha: status != nil ? 1.0 : 0.0)
        }
    }
}

/// The bar's buttons on the right, in one glass capsule: New Chat, as the chat list's compose (Telegram's glyph; held,
/// where to start one), and Telegram's animated ⋯, the chat's menu (held, it follows the finger). Each is 50 pt wide,
/// wider than Telegram's 44, so that the two are apart.
final class ChatHeaderButtonsNode: ASDisplayNode {
    static let buttonWidth: CGFloat = 50.0

    let composeNode = BarActionButtonNode(image: composeIcon, width: ChatHeaderButtonsNode.buttonWidth, accessibilityLabel: "New Chat")
    let moreNode: MoreButtonNode

    init(theme: TauTheme) {
        self.moreNode = MoreButtonNode(theme: theme.presentationTheme, encircled: false, navigation: true)
        super.init()
        self.moreNode.accessibilityLabel = "More"
        self.addSubnode(self.composeNode)
        self.addSubnode(self.moreNode)
        self.update(theme: theme)
    }

    func update(theme: TauTheme) {
        self.composeNode.update(color: theme.navigationBar.primaryTextColor)
        self.moreNode.theme = theme.presentationTheme
        self.moreNode.updateColor(theme.navigationBar.primaryTextColor, transition: .immediate)
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: ChatHeaderButtonsNode.buttonWidth * 2.0, height: 44.0)
    }

    override func layout() {
        super.layout()
        let width = ChatHeaderButtonsNode.buttonWidth
        self.composeNode.frame = CGRect(x: 0.0, y: 0.0, width: width, height: 44.0)
        let moreSize = self.moreNode.measure(CGSize(width: width, height: 44.0))
        self.moreNode.frame = CGRect(origin: CGPoint(x: width + floor((width - moreSize.width) / 2.0), y: 0.0), size: CGSize(width: moreSize.width, height: 44.0))
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

/// A button of the bar as a context menu's anchor: the menu drops from it, as Telegram's peer menus do.
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

/// A model's name without the provider OpenRouter puts before it: "Anthropic: Claude Opus 5.5" is "Claude Opus 5.5".
func modelDisplayName(_ name: String) -> String {
    guard let range = name.range(of: ": ") else {
        return name
    }
    let rest = name[range.upperBound...]
    return rest.isEmpty ? name : String(rest)
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
    return "\(percent)%, \(formatTokens(tokens)) of \(formatTokens(window))"
}

/// The usage row's second line: how full the context is, the spend, and "warm" in the accent color while the prompt
/// cache lasts. The numbers behind them are a level down.
private func usageSummary(_ usage: ConversationUsage, accent: UIColor) -> NSAttributedString {
    let context = usage.contextPercent.map { "\($0)%" } ?? (usage.contextTokens == nil ? "Empty" : "\(formatTokens(usage.contextTokens ?? 0)) tokens")
    let summary = NSMutableAttributedString(string: "\(context), \(formatCost(usage.cost))")
    if usage.cache?.isWarm() == true {
        summary.append(NSAttributedString(string: ", "))
        summary.append(NSAttributedString(string: "warm", attributes: [.foregroundColor: accent]))
    }
    return summary
}

/// "warm, 4:12 left" in the accent color until it expires (refreshes counted in), "warm while working" while a run keeps
/// it, then how long ago it expired.
private func promptCacheStatus(expiresAt: Date, accent: UIColor, now: Date = Date()) -> NSAttributedString {
    if expiresAt == .distantFuture {
        return NSAttributedString(string: "warm while working", attributes: [.foregroundColor: accent])
    }
    let left = expiresAt.timeIntervalSince(now)
    if left > 0.0 {
        let seconds = Int(left.rounded(.up))
        return NSAttributedString(string: String(format: "warm, %d:%02d left", seconds / 60, seconds % 60), attributes: [.foregroundColor: accent])
    }
    let ago = -left
    if ago < 60.0 {
        return NSAttributedString(string: "expired just now")
    } else if ago < 3600.0 {
        return NSAttributedString(string: "expired \(Int(ago / 60.0)) min ago")
    } else if ago < 86400.0 {
        return NSAttributedString(string: "expired \(Int(ago / 3600.0)) h ago")
    }
    return NSAttributedString(string: "expired")
}
