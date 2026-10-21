import UIKit
import AsyncDisplayKit
import Display
import UndoUI
import ChatListTitleView
import SwiftSignalKit
import MergeLists
import ComponentFlow
import ComponentDisplayAdapters
import EdgeEffect
import ActivityIndicator
import ContextUI
import TelegramPresentationData

private struct ChatListEntry: Comparable, Identifiable {
    let content: ChatListItemContent
    /// Position in the list; the store sorts by last activity.
    let index: Int

    var stableId: Int {
        switch self.content {
        case let .dialog(dialog):
            return dialog.id
        case .archive:
            return Int.min
        }
    }

    static func < (lhs: ChatListEntry, rhs: ChatListEntry) -> Bool {
        return lhs.index < rhs.index
    }

    static func == (lhs: ChatListEntry, rhs: ChatListEntry) -> Bool {
        return lhs.content == rhs.content && lhs.index == rhs.index
    }
}

/// Which chats a list shows: Telegram's root list, with Archived Chats on top, or the archive folder itself.
enum ChatListMode {
    case main
    case archive
}

final class ChatListController: ViewController {
    private let context: AppContext
    private let mode: ChatListMode
    private var theme: TauTheme
    private let dialogsDisposable = MetaDisposable()
    private var statusDisposable: Disposable?
    private let titleView: ChatListTitleView
    private var themeDisposable: Disposable?

    private var controllerNode: ChatListControllerNode {
        return self.displayNode as! ChatListControllerNode
    }

    init(context: AppContext, mode: ChatListMode = .main) {
        self.context = context
        self.mode = mode
        self.theme = context.theme
        self.titleView = ChatListTitleView(context: context.telegram, theme: context.theme.presentationTheme, strings: context.theme.presentationStrings, animationCache: context.telegram.animationCache, animationRenderer: context.telegram.animationRenderer)
        // iOS 26 Telegram: glass buttons and a blurred edge instead of a bar.
        super.init(navigationBarPresentationData: context.theme.navigationBarPresentationData())
        let title = mode == .archive ? context.theme.presentationStrings.ChatList_ArchivedChatsTitle : "Chats"
        // The title view draws the title, as in Telegram's chat list; the navigation bar would draw `title` under it.
        self.navigationItem.titleView = self.titleView
        // Telegram's ChatListTitleView: the title says, with its spinner, when the list may be stale.
        let strings = context.theme.presentationStrings
        // As Telegram's ChatListController: leaving online shows after 0.3 s, so a short blip does not flash the title.
        let previous = Atomic<ConnectionStatus?>(value: nil)
        let status = context.store.connectionStatus |> mapToSignal { value -> Signal<ConnectionStatus, NoError> in
            if let last = previous.swap(value), last == .online, value != .online {
                return .single(value) |> delay(0.3, queue: .mainQueue())
            }
            return .single(value)
        }
        self.statusDisposable = (status |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let self else {
                return
            }
            let text: String
            switch status {
            case .online:
                text = title
            case .waitingForNetwork:
                text = strings.State_WaitingForNetwork
            case .connecting:
                text = strings.State_Connecting
            case .updating:
                text = strings.State_Updating
            }
            self.titleView.setTitle(NetworkStatusTitle(text: text, activity: status != .online, hasProxy: false, connectsViaProxy: false, isPasscodeSet: false, isManuallyLocked: false, peerStatus: nil), animated: true)
            self.requestLayout(transition: .animated(duration: 0.45, curve: .spring))
        })
        if mode == .main {
            // The compose button in the bar's glass; a long press lists recent projects.
            let composeNode = ComposeButtonNode()
            composeNode.longPressed = { [weak self, weak composeNode] in
                guard let self, let composeNode else {
                    return
                }
                self.openComposeMenu(sourceView: composeNode.view)
            }
            composeNode.tapped = { [weak self] in
                self?.compose()
            }
            self.composeNode = composeNode
            composeNode.update(color: context.theme.navigationBar.primaryTextColor)
            let item = UIBarButtonItem(customDisplayNode: composeNode)!
            item.target = self
            item.action = #selector(self.composePressed)
            self.navigationItem.rightBarButtonItem = item
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
        self.dialogsDisposable.dispose()
        self.themeDisposable?.dispose()
        self.statusDisposable?.dispose()
    }

    override func loadDisplayNode() {
        let store = self.context.store
        let interaction = ChatListInteraction(open: { [weak self] dialog in
            self?.open(conversationId: dialog.id)
        }, openArchive: { [weak self] in
            self?.openArchive()
        }, contextAction: { [weak self] dialog, sourceNode, gesture in
            self?.openContextMenu(dialog: dialog, sourceNode: sourceNode, gesture: gesture)
        }, toggleRead: { dialog in
            store.setUnread(dialog.id, !dialog.isUnread)
        }, setArchived: { dialog, archived in
            store.setArchived(dialog.id, archived)
        }, delete: { dialog in
            store.deleteConversation(dialog.id)
        })
        self.displayNode = ChatListControllerNode(context: self.context, theme: self.theme, mode: self.mode, interaction: interaction)
        self.dialogsDisposable.set((self.context.store.dialogsSignal() |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            self?.latestDialogs = dialogs
            self?.controllerNode.update(dialogs: dialogs)
        }))
        self.displayNodeDidLoad()
    }

    private func updateTheme(_ theme: TauTheme) {
        guard theme !== self.theme else {
            return
        }
        self.theme = theme
        self.composeNode?.update(color: theme.navigationBar.primaryTextColor)
        self.statusBar.statusBarStyle = theme.statusBarStyleValue
        self.navigationBar?.updatePresentationData(theme.navigationBarPresentationData(), transition: .immediate)
        self.titleView.theme = theme.presentationTheme
        if self.isNodeLoaded {
            self.controllerNode.updateTheme(theme)
        }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }

    @objc private func composePressed() {
        self.compose()
    }

    private var composeNode: ComposeButtonNode?
    /// The list as last shown, for where a new chat starts.
    private(set) var latestDialogs: [DialogModel] = []

    /// New Chat: straight into an empty chat in the most recent project; its card changes where and with what.
    func compose() {
        guard let location = self.context.store.defaultLocation(self.latestDialogs) else {
            return
        }
        self.startChat(at: location)
    }

    func startChat(at location: ProjectLocation) {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        let id = self.context.store.createConversation(server: location.slot, cwd: location.path)
        let chat = ChatController(context: self.context, conversationId: id)
        navigationController.pushViewController(chat)
        Queue.mainQueue().after(0.45) {
            chat.activateInput()
        }
    }

    /// A long press on compose: Telegram's context menu from the button, with the recent projects, then Choose Project.
    private func openComposeMenu(sourceView: UIView) {
        let store = self.context.store
        let theme = self.theme
        var items: [ContextMenuItem] = []
        for location in store.recentProjects(self.latestDialogs).prefix(5) {
            items.append(.action(ContextMenuActionItem(text: store.projectTitle(location), textLayout: .secondLineWithValue(store.describe(location)), icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Message"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                f(.default)
                self?.startChat(at: location)
            })))
        }
        if !items.isEmpty {
            items.append(.separator)
        }
        items.append(.action(ContextMenuActionItem(text: "Choose Project…", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Folder"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.default)
            guard let self else {
                return
            }
            let picker = ProjectPickerController(context: self.context, current: nil, choose: { [weak self] location in
                Queue.mainQueue().after(0.3) {
                    self?.startChat(at: location)
                }
            })
            (self.navigationController as? NavigationController)?.pushViewController(picker)
        })))
        let source = ComposeContextReferenceSource(view: sourceView)
        let controller = makeContextController(presentationData: theme.presentationData, source: .reference(source), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.presentInGlobalOverlay(controller)
    }

    func openArchive() {
        (self.navigationController as? NavigationController)?.pushViewController(ChatListController(context: self.context, mode: .archive))
    }

    func open(conversationId: Int) {
        let start = CACurrentMediaTime()
        let controller = ChatController(context: self.context, conversationId: conversationId)
        (self.navigationController as? NavigationController)?.pushViewController(controller)
        if ProcessInfo.processInfo.environment["TAU_TIMING"] != nil { print("TIMING push sync \((CACurrentMediaTime() - start) * 1000.0) ms") }
        if ProcessInfo.processInfo.environment["TAU_TIMING"] != nil {
            var frames: [Double] = []
            var last = CACurrentMediaTime()
            let link = SharedDisplayLinkDriver.shared.add { _ in
                let now = CACurrentMediaTime()
                frames.append((now - last) * 1000.0)
                last = now
            }
            Queue.mainQueue().after(0.8) {
                link.invalidate()
                print("TIMING frames \(frames.map { String(format: "%.0f", $0) }.joined(separator: " "))")
            }
        }
    }

    /// Telegram's chat list preview: the chat itself grows out of the row, with actions under it. Tapping the preview
    /// opens the chat, as ChatListControllerImpl's peerContextAction does.
    private weak var currentToast: UndoOverlayController?

    /// Telegram's toast over the list; a new one replaces the one showing.
    func presentToast(_ content: UndoOverlayContent, action: @escaping (UndoOverlayAction) -> Bool = { _ in return false }) {
        let replacing = self.currentToast != nil
        self.currentToast?.dismiss()
        let controller = UndoOverlayController(presentationData: self.theme.presentationData, content: content, elevatedLayout: true, animateInAsReplacement: replacing, action: action)
        self.currentToast = controller
        self.present(controller, in: .current)
    }

    private func openRename(_ dialog: DialogModel) {
        let store = self.context.store
        let previous = dialog.title
        let alert = renameChatController(context: self.context.telegram, presentationData: self.theme.presentationData, title: previous, apply: { [weak self] title in
            store.rename(dialog.id, title: title)
            self?.presentToast(.info(title: nil, text: "Chat renamed to **\(title)**", timeout: nil, customUndoText: self?.theme.presentationStrings.Undo_Undo), action: { action in
                if case .undo = action {
                    store.rename(dialog.id, title: previous)
                }
                return true
            })
        })
        self.present(alert, in: .window(.root))
    }

    private func openContextMenu(dialog: DialogModel, sourceNode: ContextControllerSourceNode, gesture: ContextGesture?) {
        let store = self.context.store
        let strings = self.theme.presentationStrings
        let chat = ChatController(context: self.context, conversationId: dialog.id, isPreview: true)
        var items: [ContextMenuItem] = []
        // ChatContextMenus.swift: Archive, then Mark as Read or Unread, as the chat's state calls for.
        if dialog.archived {
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_Context_Unarchive, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Unarchive"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                store.setArchived(dialog.id, false)
            })))
        } else {
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_Context_Archive, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Archive"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                store.setArchived(dialog.id, true)
            })))
        }
        if dialog.isUnread {
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_Context_MarkAsRead, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/MarkAsRead"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                store.setUnread(dialog.id, false)
            })))
        } else {
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_Context_MarkAsUnread, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/MarkAsUnread"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                store.setUnread(dialog.id, true)
            })))
        }
        items.append(.action(ContextMenuActionItem(text: "Rename", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.dismissWithoutContent)
            self?.openRename(dialog)
        })))
        items.append(.action(ContextMenuActionItem(text: "Duplicate", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.default)
            // The copy opens, as a new chat would.
            store.duplicateConversation(dialog.id, completion: { newId in
                self?.open(conversationId: newId)
            })
        })))
        items.append(.action(ContextMenuActionItem(text: strings.Common_Delete, textColor: .destructive, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
        }, action: { _, f in
            f(.default)
            store.deleteConversation(dialog.id)
        })))
        let navigationController = self.navigationController as? NavigationController
        let source = ChatListContextControllerContentSource(controller: chat, sourceNode: sourceNode, navigationController: navigationController)
        let contextController = makeContextController(presentationData: self.theme.presentationData, source: .controller(source), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
        chat.previewTapped = { [weak self, weak contextController, weak chat] in
            guard let self, let chat, let navigationController = self.navigationController as? NavigationController else {
                return
            }
            // Telegram zooms the preview into the chat rather than pushing it from the side.
            let frame = chat.view.convert(chat.view.bounds, to: nil)
            contextController?.dismiss(result: .dismissWithoutContent, completion: nil)
            let full = ChatController(context: self.context, conversationId: dialog.id)
            navigationController.pushViewController(full, animated: false)
            full.animateFromPreview(frame: frame)
        }
        self.presentInGlobalOverlay(contextController)
    }
}

final class ChatListControllerNode: ASDisplayNode {
    private let context: AppContext
    private var theme: TauTheme
    private let mode: ChatListMode
    private let interaction: ChatListInteraction
    private let listNode: ListViewImpl
    private let bottomEdgeEffectView = EdgeEffectView()

    private var entries: [ChatListEntry] = []
    private var pendingDialogs: [DialogModel]?
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?

    init(context: AppContext, theme: TauTheme, mode: ChatListMode, interaction: ChatListInteraction) {
        self.context = context
        self.theme = theme
        self.mode = mode
        self.interaction = interaction
        self.listNode = ListViewImpl()
        super.init()
        self.backgroundColor = theme.chatList.backgroundColor
        self.addSubnode(self.listNode)
        interaction.revealedOptionsChanged = { [weak self] id in
            self?.listNode.forEachItemNode { node in
                (node as? ChatListItemNode)?.closeRevealOptions(except: id)
            }
        }
    }

    override func didLoad() {
        super.didLoad()
        self.bottomEdgeEffectView.isUserInteractionEnabled = false
        self.view.addSubview(self.bottomEdgeEffectView)
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        self.backgroundColor = theme.chatList.backgroundColor
        self.reloadAllItems()
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .immediate)
        }
    }

    private func makeItem(_ entry: ChatListEntry) -> ListViewItem {
        return ChatListItem(theme: self.theme, content: entry.content, interaction: self.interaction)
    }

    private func reloadAllItems() {
        let updates = self.entries.enumerated().map { ListViewUpdateItem(index: $0.offset, previousIndex: $0.offset, item: self.makeItem($0.element), directionHint: nil) }
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: updates, options: [.Synchronous], updateOpaqueState: nil)
    }

    func update(dialogs: [DialogModel]) {
        guard self.validLayout != nil else {
            self.pendingDialogs = dialogs
            return
        }
        var contents: [ChatListItemContent] = []
        switch self.mode {
        case .main:
            let archived = dialogs.filter { $0.archived }
            if !archived.isEmpty {
                contents.append(.archive(ArchiveSummary(titles: archived.map { $0.title }, date: archived.compactMap { $0.last?.date }.max(), unreadCount: archived.reduce(0) { $0 + ($1.isUnread ? 1 : 0) })))
            }
            contents += dialogs.filter { !$0.archived }.map { .dialog($0) }
        case .archive:
            contents = dialogs.filter { $0.archived }.map { .dialog($0) }
        }
        let entries = contents.enumerated().map { ChatListEntry(content: $0.element, index: $0.offset) }
        let isInitial = self.entries.isEmpty
        let previous = self.entries
        self.entries = entries
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: previous, rightList: entries)
        self.listNode.transaction(
            deleteIndices: deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) },
            insertIndicesAndItems: indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: self.makeItem($0.1), directionHint: nil) },
            updateIndicesAndItems: updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: self.makeItem($0.1), directionHint: nil) },
            options: isInitial ? [.Synchronous, .LowLatency] : [.AnimateInsertion],
            updateOpaqueState: nil
        )
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let isFirstLayout = self.validLayout == nil
        self.validLayout = (layout, navigationHeight)
        let bottomInset = layout.intrinsicInsets.bottom

        // Rows scroll under the tab bar; a fade keeps it legible, as in Telegram's ChatListContainerItemNode.
        let edgeEffectHeight = bottomInset + 8.0
        let edgeEffectFrame = CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - edgeEffectHeight), size: CGSize(width: layout.size.width, height: edgeEffectHeight))
        transition.updateFrame(view: self.bottomEdgeEffectView, frame: edgeEffectFrame)
        self.bottomEdgeEffectView.update(content: self.theme.chatList.backgroundColor, alpha: 0.6, rect: edgeEffectFrame, edge: .bottom, edgeSize: min(edgeEffectFrame.height, 40.0), transition: ComponentTransition(transition))

        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        let insets = UIEdgeInsets(top: navigationHeight, left: layout.safeInsets.left, bottom: bottomInset, right: layout.safeInsets.right)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)

        if isFirstLayout, let dialogs = self.pendingDialogs {
            self.pendingDialogs = nil
            self.update(dialogs: dialogs)
        }
    }
}

/// As ChatListController.swift's ContextControllerContentSourceImpl: a live controller as the context menu's content,
/// growing from the row it was opened on.
private final class ChatListContextControllerContentSource: ContextControllerContentSource {
    let controller: ViewController
    weak var sourceNode: ASDisplayNode?
    let navigationController: NavigationController?
    let passthroughTouches: Bool = true

    init(controller: ViewController, sourceNode: ASDisplayNode?, navigationController: NavigationController?) {
        self.controller = controller
        self.sourceNode = sourceNode
        self.navigationController = navigationController
    }

    func transitionInfo() -> ContextControllerTakeControllerInfo? {
        let sourceNode = self.sourceNode
        return ContextControllerTakeControllerInfo(contentAreaInScreenSpace: CGRect(origin: CGPoint(), size: CGSize(width: 10.0, height: 10.0)), sourceNode: { [weak sourceNode] in
            if let sourceNode {
                return (sourceNode.view, sourceNode.bounds)
            }
            return nil
        })
    }

    func animatedIn() {
    }
}

/// The compose glyph inside the navigation bar's glass button, which also takes a long press.
final class ComposeButtonNode: ASDisplayNode {
    private let iconNode = ASImageNode()
    var longPressed: (() -> Void)?
    var tapped: (() -> Void)?

    override init() {
        super.init()
        self.iconNode.displaysAsynchronously = false
        self.addSubnode(self.iconNode)
    }

    override func didLoad() {
        super.didLoad()
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressGesture(_:)))
        recognizer.minimumPressDuration = 0.4
        self.view.addGestureRecognizer(recognizer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture))
        tap.require(toFail: recognizer)
        self.view.addGestureRecognizer(tap)
    }

    @objc private func tapGesture() {
        self.tapped?()
    }

    @objc private func longPressGesture(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            self.longPressed?()
        }
    }

    func update(color: UIColor) {
        // Telegram's own compose glyph, drawn to sit centered in the button.
        self.iconNode.image = generateTintedImage(image: UIImage(bundleImageName: "Chat List/ComposeIcon"), color: color)
        self.setNeedsLayout()
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 44.0, height: 44.0)
    }

    override func layout() {
        super.layout()
        if let image = self.iconNode.image {
            self.iconNode.frame = CGRect(origin: CGPoint(x: floor((self.bounds.width - image.size.width) / 2.0), y: floor((self.bounds.height - image.size.height) / 2.0)), size: image.size)
        }
    }
}

/// The compose button as a context menu's anchor.
private final class ComposeContextReferenceSource: ContextReferenceContentSource {
    private weak var view: UIView?

    init(view: UIView) {
        self.view = view
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        guard let view = self.view else {
            return nil
        }
        return ContextControllerReferenceViewInfo(referenceView: view, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}
