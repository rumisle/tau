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
import SearchBarNode
import SearchUI
import NavigationBarImpl
import LottieComponent

private struct ChatListEntry: Comparable, Identifiable {
    let content: ChatListItemContent
    /// Position in the list; the store sorts by last activity.
    let index: Int
    var isLastPinned = false

    var stableId: Int {
        switch self.content {
        case let .dialog(dialog):
            return dialog.id
        case .archive:
            return Int.min
        case let .message(dialog, _):
            return dialog.id
        }
    }

    static func < (lhs: ChatListEntry, rhs: ChatListEntry) -> Bool {
        return lhs.index < rhs.index
    }

    static func == (lhs: ChatListEntry, rhs: ChatListEntry) -> Bool {
        return lhs.content == rhs.content && lhs.index == rhs.index && lhs.isLastPinned == rhs.isLastPinned
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
    /// The folder tabs, while the user has folders (Telegram shows none until then).
    private var tabsNode: ChatListFolderTabsNode?
    private let foldersDisposable = MetaDisposable()
    private var folders: [ChatFolder] = []
    private var selectedFolder: ChatListFolderId = .all
    /// Telegram's Reorder Tabs: the tabs jiggle and drag, the list dims, Done keeps the order.
    private var isReorderingTabs = false

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
        if mode == .main {
            // Telegram's search field under the title, which scrolls away with the list.
            let searchContentNode = NavigationBarSearchContentNode(theme: context.theme.presentationTheme, placeholder: context.theme.presentationStrings.Common_Search, activate: { [weak self] in
                self?.activateSearch()
            })
            searchContentNode.placeholderNode.accessibilityIdentifier = "chatSearch"
            self.searchContentNode = searchContentNode
            self.navigationBar?.setContentNode(searchContentNode, animated: false)
        }
        self.themeDisposable = (context.themeContext.theme |> deliverOnMainQueue).start(next: { [weak self] theme in
            self?.updateTheme(theme)
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.dialogsDisposable.dispose()
        self.foldersDisposable.dispose()
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
        interaction.setPinned = { dialog, pinned in
            store.setPinned(dialog.id, pinned)
        }
        self.displayNode = ChatListControllerNode(context: self.context, theme: self.theme, mode: self.mode, interaction: interaction)
        self.controllerNode.listOffsetChanged = { [weak self] offset in
            self?.searchContentNode?.updateListVisibleContentOffset(offset)
        }
        self.controllerNode.listDidEndScrolling = { [weak self] list in
            if let self, let searchContentNode = self.searchContentNode {
                let _ = fixNavigationSearchableListNodeScrolling(list, searchNode: searchContentNode)
            }
        }
        self.dialogsDisposable.set((self.context.store.dialogsSignal() |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            guard let self else {
                return
            }
            self.latestDialogs = dialogs
            if self.mode == .main {
                ChatFolderStore.shared.seedIfNeeded(store: self.context.store, dialogs: dialogs)
            }
            self.controllerNode.update(dialogs: dialogs)
            self.updateTabs(transition: .immediate)
        }))
        self.controllerNode.selectedFolderChanged = { [weak self] id in
            guard let self else {
                return
            }
            self.selectedFolder = id
            self.updateTabs(transition: .spring(duration: 0.4))
        }
        self.controllerNode.switchFractionUpdated = { [weak self] fraction, isDragging, transition in
            self?.tabsNode?.updateSwitchFraction(fraction, isDragging: isDragging, transition: ComponentTransition(transition))
        }
        self.controllerNode.editFolder = { [weak self] id in
            self?.editFolder(id)
        }
        if self.mode == .main {
            self.foldersDisposable.set((ChatFolderStore.shared.signal |> deliverOnMainQueue).start(next: { [weak self] folders in
                self?.updateFolders(folders)
            }))
        }
        self.displayNodeDidLoad()
    }

    // MARK: - Folders

    private func updateFolders(_ folders: [ChatFolder]) {
        let hadTabs = !self.folders.isEmpty
        self.folders = folders
        self.controllerNode.update(folders: folders)
        guard let navigationBar = self.navigationBar as? NavigationBarImpl else {
            return
        }
        if folders.isEmpty {
            if self.tabsNode != nil {
                navigationBar.setSecondaryContentNode(nil, animated: hadTabs)
                self.tabsNode = nil
                self.requestLayout(transition: .animated(duration: 0.3, curve: .spring))
            }
            return
        }
        if self.tabsNode == nil {
            let tabsNode = ChatListFolderTabsNode(theme: self.theme)
            tabsNode.select = { [weak self] id in
                guard let self, !self.isReorderingTabs else {
                    return
                }
                self.controllerNode.select(id)
            }
            tabsNode.contextAction = { [weak self] id, view, gesture in
                self?.openTabMenu(id, sourceView: view, gesture: gesture)
            }
            tabsNode.delete = { [weak self] id in
                if case let .folder(value) = id {
                    self?.deleteFolder(value)
                }
            }
            self.tabsNode = tabsNode
            navigationBar.secondaryContentHeight = ChatListFolderTabsNode.height
            if self.displayNavigationBar {
                navigationBar.setSecondaryContentNode(tabsNode, animated: hadTabs || self.view.window != nil)
            }
            self.updateTabs(transition: .immediate)
            self.requestLayout(transition: self.view.window != nil ? .animated(duration: 0.3, curve: .spring) : .immediate)
        } else {
            self.updateTabs(transition: .spring(duration: 0.4))
        }
    }

    private func updateTabs(transition: ComponentTransition) {
        guard let tabsNode = self.tabsNode else {
            return
        }
        let visible = self.latestDialogs.filter { $0.parentConversationId == nil }
        var tabs = [ChatListFolderTab(id: .all, title: "All", unread: 0)]
        for folder in self.folders {
            tabs.append(ChatListFolderTab(id: .folder(folder.id), title: folder.title, unread: visible.filter { $0.isUnread && folder.contains($0) }.count))
        }
        tabsNode.update(theme: self.theme, tabs: tabs, selected: self.controllerNode.selectedId, isEditing: self.isReorderingTabs, transition: transition)
    }

    private func pushController(_ controller: ViewController) {
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }

    func editFolder(_ id: Int32) {
        guard let folder = ChatFolderStore.shared.folder(id) else {
            return
        }
        self.pushController(ChatFolderEditController(context: self.context, folder: folder))
    }

    /// A folder goes, with Undo, as Telegram's toast after a folder is deleted.
    private func deleteFolder(_ id: Int32) {
        let store = ChatFolderStore.shared
        guard let index = store.folders.firstIndex(where: { $0.id == id }) else {
            return
        }
        let folder = store.folders[index]
        store.remove(id)
        self.presentToast(.info(title: nil, text: "Folder **\(folder.title)** deleted", timeout: nil, customUndoText: self.theme.presentationStrings.Undo_Undo), action: { action in
            if case .undo = action {
                var folders = store.folders
                folders.insert(folder, at: min(index, folders.count))
                store.set(folders)
            }
            return true
        })
    }

    /// A tab's long press, as ChatListController.tabContextGesture: a folder's Edit Folder, Add Chats, Mark All as Read
    /// and Delete; All's Edit Folders; both Reorder Tabs.
    private func openTabMenu(_ id: ChatListFolderId, sourceView: ContextExtractedContentContainingView, gesture: ContextGesture?) {
        guard !self.isReorderingTabs else {
            gesture?.cancel()
            return
        }
        let strings = self.theme.presentationStrings
        var items: [ContextMenuItem] = []
        func icon(_ name: String, destructive: Bool = false) -> (PresentationTheme) -> UIImage? {
            return { theme in
                return generateTintedImage(image: UIImage(bundleImageName: name), color: destructive ? theme.contextMenu.destructiveColor : theme.contextMenu.primaryColor)
            }
        }
        switch id {
        case let .folder(value):
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_EditFolder, icon: icon("Chat/Context Menu/Edit"), action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    self?.editFolder(value)
                })
            })))
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_AddChatsToFolder, icon: icon("Chat/Context Menu/Add"), action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    guard let self, let folder = ChatFolderStore.shared.folder(value) else {
                        return
                    }
                    self.pushController(ChatFolderPickerController(context: self.context, folder: folder, mode: .include, apply: { folder in
                        ChatFolderStore.shared.update(folder)
                    }))
                })
            })))
            if let folder = ChatFolderStore.shared.folder(value) {
                let unread = self.latestDialogs.filter { $0.isUnread && folder.contains($0) }
                if !unread.isEmpty {
                    items.append(.action(ContextMenuActionItem(text: strings.ChatList_ReadAll, icon: icon("Chat/Context Menu/ReadAll"), action: { [weak self] _, f in
                        f(.default)
                        for dialog in unread {
                            self?.context.store.setUnread(dialog.id, false)
                        }
                    })))
                }
            }
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_RemoveFolder, textColor: .destructive, icon: icon("Chat/Context Menu/Delete", destructive: true), action: { [weak self] _, f in
                f(.default)
                self?.deleteFolder(value)
            })))
        case .all:
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_EditFolders, icon: icon("Chat/Context Menu/EditFolder"), action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    guard let self else {
                        return
                    }
                    self.pushController(ChatFoldersController(context: self.context))
                })
            })))
        }
        if self.folders.count > 1 {
            items.append(.separator)
            items.append(.action(ContextMenuActionItem(text: strings.ChatList_ReorderTabs, icon: icon("Chat/Context Menu/ReorderItems"), action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    self?.setReorderingTabs(true)
                })
            })))
        }
        let controller = makeContextController(presentationData: self.theme.presentationData, source: .reference(ChatListTabContextReferenceSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
        self.presentInGlobalOverlay(controller)
    }

    private var composeItem: UIBarButtonItem?

    /// Reorder Tabs on and off: Done in the compose button's place; the order the tabs were dragged into is kept.
    private func setReorderingTabs(_ value: Bool) {
        guard value != self.isReorderingTabs else {
            return
        }
        if !value, let ids = self.tabsNode?.reorderedIds {
            let byId = Dictionary(self.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = ids.compactMap { id -> ChatFolder? in
                if case let .folder(value) = id {
                    return byId[value]
                }
                return nil
            }
            let rest = self.folders.filter { folder in !ordered.contains(where: { $0.id == folder.id }) }
            ChatFolderStore.shared.set(ordered + rest)
        }
        self.isReorderingTabs = value
        if value {
            self.composeItem = self.navigationItem.rightBarButtonItem
            self.navigationItem.setRightBarButton(UIBarButtonItem(title: self.theme.presentationStrings.Common_Done, style: .done, target: self, action: #selector(self.reorderDonePressed)), animated: true)
        } else {
            self.navigationItem.setRightBarButton(self.composeItem, animated: true)
        }
        self.controllerNode.setDimmed(value, transition: .animated(duration: 0.2, curve: .easeInOut))
        self.updateTabs(transition: .spring(duration: 0.4))
    }

    @objc private func reorderDonePressed() {
        self.setReorderingTabs(false)
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
        // The search field collapses as the list scrolls, which changes the bar's height; the list's inset must not
        // follow it, or each scroll moves the inset, which moves the scroll, without end (cleanNavigationHeight adds
        // the collapsed part back, as Telegram's lists use it).
        let navigationFrame = self.navigationLayout(layout: layout).navigationFrame
        let navigationHeight = self.searchContentNode != nil ? self.cleanNavigationHeight : navigationFrame.maxY
        // The tabs at the bar's foot, under the search field.
        if let tabsNode = self.tabsNode, tabsNode.supernode != nil, let navigationBar = self.navigationBar {
            let height = ChatListFolderTabsNode.height
            transition.updateFrame(node: tabsNode, frame: CGRect(x: 0.0, y: navigationBar.frame.height - height, width: layout.size.width, height: height))
            tabsNode.updateLayout(width: layout.size.width, transition: ComponentTransition(transition))
        }
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: transition)
        self.controllerNode.updateSearchLayout(layout, navigationBarHeight: self.cleanNavigationHeight, transition: transition)
    }

    @objc private func composePressed() {
        self.compose()
    }

    private var composeNode: ComposeButtonNode?
    private var searchContentNode: NavigationBarSearchContentNode?

    /// Telegram's search: the bar slides away, the field takes the top, results cover the list.
    func activateSearch() {
        guard self.displayNavigationBar, let searchContentNode = self.searchContentNode else {
            return
        }
        if self.isReorderingTabs {
            self.setReorderingTabs(false)
        }
        // The folder tabs make way for the search, as Telegram's do; they come back with the list.
        if self.tabsNode != nil, let navigationBar = self.navigationBar as? NavigationBarImpl {
            navigationBar.setSecondaryContentNode(nil, animated: true)
        }
        self.controllerNode.activateSearch(placeholderNode: searchContentNode.placeholderNode, navigationBar: self.navigationBar, open: { [weak self] dialog, match in
            self?.openSearchResult(dialog, match: match)
        }, cancel: { [weak self] in
            self?.deactivateSearch()
        })
        let transition: ContainedViewLayoutTransition = .animated(duration: 0.4, curve: .spring)
        self.setDisplayNavigationBar(false, transition: transition)
        (self.parent as? RootTabController)?.updateIsTabBarHidden(true, transition: transition)
    }

    func deactivateSearch() {
        guard !self.displayNavigationBar, let searchContentNode = self.searchContentNode else {
            return
        }
        let transition: ContainedViewLayoutTransition = .animated(duration: 0.4, curve: .spring)
        if let tabsNode = self.tabsNode, let navigationBar = self.navigationBar as? NavigationBarImpl {
            navigationBar.setSecondaryContentNode(tabsNode, animated: true)
        }
        self.setDisplayNavigationBar(true, transition: transition)
        self.controllerNode.deactivateSearch(placeholderNode: searchContentNode.placeholderNode)
        (self.parent as? RootTabController)?.updateIsTabBarHidden(false, transition: transition)
    }

    /// A found message: its chat, scrolled to it, with the words marked.
    private func openSearchResult(_ dialog: DialogModel, match: SearchMatch?) {
        let focus = match.flatMap { match in match.entryId.map { ChatFocus(entryId: $0, terms: self.controllerNode.searchTerms) } }
        let controller = ChatController(context: self.context, conversationId: dialog.id, focus: focus)
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }
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
        // ChatContextMenus.swift: Pin or Unpin after the read state.
        items.append(.action(ContextMenuActionItem(text: dialog.pinned != nil ? strings.ChatList_Context_Unpin : strings.ChatList_Context_Pin, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: dialog.pinned != nil ? "Chat/Context Menu/Unpin" : "Chat/Context Menu/Pin"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            store.setPinned(dialog.id, dialog.pinned == nil)
        })))
        // ChatContextMenus.swift: Add to Folder, with the folders it is not in; in a folder, Remove from Folder.
        if self.mode == .main && !self.folders.isEmpty {
            if case let .folder(current) = self.controllerNode.selectedId, let folder = ChatFolderStore.shared.folder(current), folder.contains(dialog) {
                items.append(.action(ContextMenuActionItem(text: strings.ChatList_Context_RemoveFromFolder, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/RemoveFromFolder"), color: theme.contextMenu.primaryColor)
                }, action: { [weak self] _, f in
                    f(.default)
                    var updated = folder
                    updated.chats.removeAll { $0 == dialog.id }
                    if updated.contains(dialog) {
                        updated.excludedChats.append(dialog.id)
                    }
                    ChatFolderStore.shared.update(updated)
                    self?.presentToast(.info(title: nil, text: "Chat removed from **\(folder.title)**", timeout: nil, customUndoText: strings.Undo_Undo), action: { action in
                        if case .undo = action {
                            ChatFolderStore.shared.update(folder)
                        }
                        return true
                    })
                })))
            }
            let addable = self.folders.filter { !$0.contains(dialog) }
            if !addable.isEmpty {
                items.append(.action(ContextMenuActionItem(text: strings.ChatList_Context_AddToFolder, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/AddToFolder"), color: theme.contextMenu.primaryColor)
                }, action: { [weak self] c, _ in
                    var submenu: [ContextMenuItem] = [.action(ContextMenuActionItem(text: strings.Common_Back, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
                    }, iconPosition: .left, action: { c, _ in
                        c?.popItems()
                    })), .separator]
                    for folder in addable {
                        submenu.append(.action(ContextMenuActionItem(text: folder.title, icon: { _ in nil }, action: { [weak self] _, f in
                            f(.default)
                            var updated = folder
                            updated.excludedChats.removeAll { $0 == dialog.id }
                            if !updated.contains(dialog) {
                                updated.chats.append(dialog.id)
                            }
                            ChatFolderStore.shared.update(updated)
                            self?.presentToast(.info(title: nil, text: "Chat added to **\(folder.title)**", timeout: nil, customUndoText: strings.Undo_Undo), action: { action in
                                if case .undo = action {
                                    ChatFolderStore.shared.update(folder)
                                }
                                return true
                            })
                        })))
                    }
                    c?.pushItems(items: .single(ContextController.Items(content: .list(submenu))))
                })))
            }
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

/// One list of chats: All, the archive, or a folder's, as Telegram's ChatListContainerItemNode. Rows come and go with
/// the list's animations as the chats change.
final class ChatListPaneNode: ASDisplayNode {
    private let context: AppContext
    private var theme: TauTheme
    private let mode: ChatListMode
    let folderId: ChatListFolderId
    private(set) var folder: ChatFolder?
    private let interaction: ChatListInteraction
    let listNode = ListViewImpl()
    private var entries: [ChatListEntry] = []
    private var pendingDialogs: [DialogModel]?
    private var validLayout: (size: CGSize, insets: UIEdgeInsets)?
    private var emptyNode: ChatListFolderEmptyNode?
    /// A folder's Edit Folder, under its empty state.
    var editFolder: (() -> Void)?

    init(context: AppContext, theme: TauTheme, mode: ChatListMode, folderId: ChatListFolderId, folder: ChatFolder?, interaction: ChatListInteraction) {
        self.context = context
        self.theme = theme
        self.mode = mode
        self.folderId = folderId
        self.folder = folder
        self.interaction = interaction
        super.init()
        self.backgroundColor = theme.chatList.backgroundColor
        self.addSubnode(self.listNode)
    }

    func closeRevealOptions(except id: Int?) {
        self.listNode.forEachItemNode { node in
            (node as? ChatListItemNode)?.closeRevealOptions(except: id)
        }
    }

    private func makeItem(_ entry: ChatListEntry) -> ListViewItem {
        return ChatListItem(theme: self.theme, content: entry.content, interaction: self.interaction, isLastPinned: entry.isLastPinned)
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        self.backgroundColor = theme.chatList.backgroundColor
        let updates = self.entries.enumerated().map { ListViewUpdateItem(index: $0.offset, previousIndex: $0.offset, item: self.makeItem($0.element), directionHint: nil) }
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: updates, options: [.Synchronous], updateOpaqueState: nil)
        self.emptyNode?.updateTheme(theme)
    }

    func update(dialogs: [DialogModel], folder: ChatFolder?) {
        self.folder = folder
        guard self.validLayout != nil else {
            self.pendingDialogs = dialogs
            return
        }
        var contents: [ChatListItemContent] = []
        switch self.mode {
        case .main:
            if let folder {
                contents = ChatListControllerNode.pinnedFirst(dialogs.filter { folder.contains($0) }).map { .dialog($0) }
            } else {
                let archived = dialogs.filter { $0.archived }
                if !archived.isEmpty {
                    contents.append(.archive(ArchiveSummary(titles: archived.map { $0.title }, date: archived.compactMap { $0.last?.date }.max(), unreadCount: archived.reduce(0) { $0 + ($1.isUnread ? 1 : 0) })))
                }
                contents += ChatListControllerNode.pinnedFirst(dialogs.filter { !$0.archived }).map { .dialog($0) }
            }
        case .archive:
            contents = ChatListControllerNode.pinnedFirst(dialogs.filter { $0.archived }).map { .dialog($0) }
        }
        var entries = contents.enumerated().map { ChatListEntry(content: $0.element, index: $0.offset) }
        if let last = entries.lastIndex(where: { if case let .dialog(dialog) = $0.content { return dialog.pinned != nil } else { return false } }), last < entries.count - 1 {
            entries[last].isLastPinned = true
        }
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
        self.updateEmpty(isEmpty: entries.isEmpty && folder != nil)
    }

    /// Telegram's empty folder (ChatListEmptyNode, `.filter`): its animation, what it means, and Edit Folder.
    private func updateEmpty(isEmpty: Bool) {
        if isEmpty, self.emptyNode == nil {
            let node = ChatListFolderEmptyNode(theme: self.theme, action: { [weak self] in
                self?.editFolder?()
            })
            self.emptyNode = node
            self.addSubnode(node)
            if let (size, insets) = self.validLayout {
                node.update(size: size, insets: insets)
            }
            node.animateIn()
        } else if !isEmpty, let node = self.emptyNode {
            self.emptyNode = nil
            node.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak node] _ in
                node?.removeFromSupernode()
            })
        }
    }

    func updateLayout(size: CGSize, insets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        // A drag lays the panes out every frame, moving them, not resizing them: nothing for the list to do.
        if let (currentSize, currentInsets) = self.validLayout, currentSize == size, currentInsets == insets {
            return
        }
        let isFirstLayout = self.validLayout == nil
        self.validLayout = (size, insets)
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: size, insets: insets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)
        if let emptyNode = self.emptyNode {
            transition.updateFrame(node: emptyNode, frame: CGRect(origin: CGPoint(), size: size))
            emptyNode.update(size: size, insets: insets)
        }
        if isFirstLayout, let dialogs = self.pendingDialogs {
            self.pendingDialogs = nil
            self.update(dialogs: dialogs, folder: self.folder)
        }
    }
}

/// The chat list's body, as Telegram's ChatListContainerNode: a list for the selected folder and, while one is dragged
/// toward them, its neighbors, side by side; a horizontal drag moves between folders, the tabs following it.
final class ChatListControllerNode: ASDisplayNode, ASGestureRecognizerDelegate {
    private let context: AppContext
    private var theme: TauTheme
    private let mode: ChatListMode
    private let interaction: ChatListInteraction
    private let bottomEdgeEffectView = EdgeEffectView()

    private var pendingDialogs: [DialogModel]?
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?

    /// The tabs, All first, and their folders.
    private(set) var folderIds: [ChatListFolderId] = [.all]
    private var folders: [Int32: ChatFolder] = [:]
    private(set) var selectedId: ChatListFolderId = .all
    private var panes: [ChatListFolderId: ChatListPaneNode] = [:]
    private var transitionFraction: CGFloat = 0.0
    private var transitionFractionOffset: CGFloat = 0.0
    private var disablePaneOperations = false
    private var panRecognizer: InteractiveTransitionGestureRecognizer?

    /// The selected folder changed, or the drag toward another moved: for the tabs.
    var switchFractionUpdated: ((CGFloat, Bool, ContainedViewLayoutTransition) -> Void)?
    var selectedFolderChanged: ((ChatListFolderId) -> Void)?
    var editFolder: ((Int32) -> Void)?

    var currentPane: ChatListPaneNode? {
        return self.panes[self.selectedId]
    }

    init(context: AppContext, theme: TauTheme, mode: ChatListMode, interaction: ChatListInteraction) {
        self.context = context
        self.theme = theme
        self.mode = mode
        self.interaction = interaction
        super.init()
        self.backgroundColor = theme.chatList.backgroundColor
        self.addPane(.all)
        interaction.revealedOptionsChanged = { [weak self] id in
            for pane in self?.panes.values ?? [:].values {
                pane.closeRevealOptions(except: id)
            }
        }
    }

    @discardableResult
    private func addPane(_ id: ChatListFolderId) -> ChatListPaneNode {
        if let pane = self.panes[id] {
            return pane
        }
        var folder: ChatFolder?
        if case let .folder(value) = id {
            folder = self.folders[value]
        }
        let pane = ChatListPaneNode(context: self.context, theme: self.theme, mode: self.mode, folderId: id, folder: folder, interaction: self.interaction)
        pane.editFolder = { [weak self] in
            if case let .folder(value) = id {
                self?.editFolder?(value)
            }
        }
        // Only the selected list moves the search field.
        pane.listNode.visibleContentOffsetChanged = { [weak self, weak pane] offset, _ in
            guard let self, let pane, pane.folderId == self.selectedId else {
                return
            }
            self.listOffsetChanged?(offset)
        }
        pane.listNode.didEndScrolling = { [weak self, weak pane] _ in
            guard let self, let pane, pane.folderId == self.selectedId else {
                return
            }
            self.listDidEndScrolling?(pane.listNode)
        }
        self.panes[id] = pane
        if let bottom = self.bottomEdgeEffectView.superview == nil ? nil : self.bottomEdgeEffectView {
            self.view.insertSubview(pane.view, belowSubview: bottom)
        } else {
            self.addSubnode(pane)
        }
        if self.validLayout != nil {
            pane.update(dialogs: self.dialogs, folder: folder)
        }
        return pane
    }

    override func didLoad() {
        super.didLoad()
        self.bottomEdgeEffectView.isUserInteractionEnabled = false
        self.view.addSubview(self.bottomEdgeEffectView)
        // As ChatListContainerNode: left or right from anywhere while there are folders, once the list is at rest.
        let panRecognizer = InteractiveTransitionGestureRecognizer(target: self, action: #selector(self.panGesture(_:)), allowedDirections: { [weak self] _ in
            guard let self, self.folderIds.count > 1, let pane = self.currentPane, self.searchDisplayController == nil else {
                return []
            }
            if pane.listNode.isDragging || pane.listNode.isDeceleratingAfterTracking {
                return []
            }
            return [.leftCenter, .rightCenter]
        }, edgeWidth: .widthMultiplier(factor: 1.0 / 6.0, min: 22.0, max: 80.0))
        panRecognizer.delegate = self.wrappedGestureRecognizerDelegate
        panRecognizer.delaysTouchesBegan = false
        panRecognizer.cancelsTouchesInView = true
        self.panRecognizer = panRecognizer
        self.view.addGestureRecognizer(panRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is InteractiveTransitionGestureRecognizer {
            return false
        }
        return otherGestureRecognizer is UIPanGestureRecognizer
    }

    @objc private func panGesture(_ recognizer: InteractiveTransitionGestureRecognizer) {
        guard let (layout, _) = self.validLayout, let selectedIndex = self.folderIds.firstIndex(of: self.selectedId) else {
            return
        }
        switch recognizer.state {
        case .began:
            self.transitionFractionOffset = 0.0
            // The neighbors scrolled as this one is, so the search field does not jump when one comes in.
            if let pane = self.currentPane, let presentation = pane.layer.presentation() {
                self.transitionFraction = presentation.frame.minX / layout.size.width
                self.transitionFractionOffset = self.transitionFraction
                if !self.transitionFraction.isZero {
                    for pane in self.panes.values {
                        pane.layer.removeAllAnimations()
                    }
                }
            }
            self.updatePanes(transition: .immediate)
            self.switchFractionUpdated?(self.transitionFraction, true, .immediate)
        case .changed:
            let translation = recognizer.translation(in: self.view)
            var fraction = translation.x / layout.size.width
            func rubberBand(_ offset: CGFloat) -> CGFloat {
                let range: CGFloat = 600.0
                return (1.0 - (1.0 / ((offset * 0.4 / range) + 1.0))) * range
            }
            if selectedIndex <= 0 && translation.x > 0.0 {
                fraction = rubberBand(translation.x) / layout.size.width
            }
            if selectedIndex >= self.folderIds.count - 1 && translation.x < 0.0 {
                fraction = -rubberBand(-translation.x) / layout.size.width
            }
            self.transitionFraction = fraction + self.transitionFractionOffset
            self.updatePanes(transition: .immediate)
            self.switchFractionUpdated?(self.transitionFraction, true, .immediate)
        case .cancelled, .ended:
            let translation = recognizer.translation(in: self.view)
            let velocity = recognizer.velocity(in: self.view)
            var toRight: Bool?
            if abs(velocity.x) > 10.0 {
                if translation.x < 0.0 {
                    toRight = velocity.x >= 0.0 ? nil : true
                } else {
                    toRight = velocity.x <= 0.0 ? nil : false
                }
            } else if abs(translation.x) > layout.size.width / 2.0 {
                toRight = translation.x < 0.0
            }
            if recognizer.state == .cancelled {
                toRight = nil
            }
            if let toRight {
                let index = toRight ? min(selectedIndex + 1, self.folderIds.count - 1) : max(selectedIndex - 1, 0)
                self.selectedId = self.folderIds[index]
            }
            self.transitionFraction = 0.0
            let transition: ContainedViewLayoutTransition = .animated(duration: 0.45, curve: .spring)
            self.disablePaneOperations = true
            self.updatePanes(transition: transition)
            DispatchQueue.main.async {
                self.disablePaneOperations = false
                self.updatePanes(transition: .immediate)
            }
            self.selectedFolderChanged?(self.selectedId)
            self.switchFractionUpdated?(0.0, false, transition)
        default:
            break
        }
    }

    /// While the tabs are reordered: the lists half seen and still, as ChatListContainerNode with isReorderingFilters.
    func setDimmed(_ value: Bool, transition: ContainedViewLayoutTransition) {
        for pane in self.panes.values {
            transition.updateAlpha(node: pane, alpha: value ? 0.5 : 1.0)
            pane.isUserInteractionEnabled = !value
        }
        self.panRecognizer?.isEnabled = !value
    }

    /// The tabs changed: the folders the user has, in their order.
    func update(folders: [ChatFolder]) {
        self.folders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids: [ChatListFolderId] = self.mode == .main ? [.all] + folders.map { .folder($0.id) } : [.all]
        self.folderIds = ids
        if !ids.contains(self.selectedId) {
            self.selectedId = .all
            self.selectedFolderChanged?(.all)
        }
        for (id, pane) in self.panes {
            if case let .folder(value) = id {
                if let folder = self.folders[value] {
                    if folder != pane.folder {
                        pane.update(dialogs: self.dialogs, folder: folder)
                    }
                }
            }
        }
        self.updatePanes(transition: .immediate)
    }

    /// A tab tapped: its list slides in from its side, as Telegram's.
    func select(_ id: ChatListFolderId, animated: Bool = true) {
        guard id != self.selectedId, self.folderIds.contains(id) else {
            // The selected tab again: to the top.
            if id == self.selectedId {
                self.currentPane?.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil)
            }
            return
        }
        self.selectedId = id
        self.addPane(id)
        if animated {
            // The one left slides out before it goes.
            self.disablePaneOperations = true
            self.updatePanes(transition: .animated(duration: 0.4, curve: .spring))
            Queue.mainQueue().after(0.42) { [weak self] in
                self?.disablePaneOperations = false
                self?.updatePanes(transition: .immediate)
            }
        } else {
            self.updatePanes(transition: .immediate)
        }
        self.selectedFolderChanged?(id)
        if let pane = self.currentPane, case let .known(offset) = pane.listNode.visibleContentOffset() {
            self.listOffsetChanged?(.known(offset))
        }
    }

    /// The selected list and its neighbors where they belong; the others go. The neighbors stay whether or not a drag is
    /// on, as in Telegram's ChatListContainerNode: the one a swipe leaves slides out with the spring, and the next drag
    /// finds its neighbor laid out.
    private func updatePanes(transition: ContainedViewLayoutTransition) {
        guard let (layout, navigationHeight) = self.validLayout, let selectedIndex = self.folderIds.firstIndex(of: self.selectedId) else {
            return
        }
        let valid = (max(0, selectedIndex - 1) ... min(self.folderIds.count - 1, selectedIndex + 1)).map { self.folderIds[$0] }
        for id in valid where self.panes[id] == nil && !self.disablePaneOperations {
            self.addPane(id)
        }
        let insets = UIEdgeInsets(top: navigationHeight, left: layout.safeInsets.left, bottom: layout.intrinsicInsets.bottom, right: layout.safeInsets.right)
        var slidingOffset: CGFloat?
        var added: [ChatListPaneNode] = []
        for (id, pane) in self.panes {
            guard let index = self.folderIds.firstIndex(of: id) else {
                continue
            }
            let distance = CGFloat(index - selectedIndex) + self.transitionFraction
            let frame = CGRect(origin: CGPoint(x: distance * layout.size.width, y: 0.0), size: layout.size)
            let wasAdded = pane.frame.size.width == 0.0
            var paneTransition = transition
            if wasAdded {
                paneTransition = .immediate
                added.append(pane)
            } else if slidingOffset == nil {
                slidingOffset = pane.frame.minX - frame.minX
            }
            paneTransition.updateFrame(node: pane, frame: frame)
            pane.updateLayout(size: layout.size, insets: insets, transition: paneTransition)
        }
        if let slidingOffset, case .animated = transition {
            for pane in added {
                transition.animatePositionAdditive(node: pane, offset: CGPoint(x: slidingOffset, y: 0.0))
            }
        }
        if !self.disablePaneOperations {
            for (id, pane) in self.panes where !valid.contains(id) {
                pane.removeFromSupernode()
                self.panes[id] = nil
            }
        }
    }

    var listOffsetChanged: ((ListViewVisibleContentOffset) -> Void)?
    var listDidEndScrolling: ((ListView) -> Void)?
    private var searchDisplayController: SearchDisplayController?
    private weak var searchContainerNode: ChatListSearchContainerNode?
    private(set) var dialogs: [DialogModel] = []

    var searchTerms: [SearchTerm] {
        return self.searchContainerNode?.terms ?? []
    }

    func activateSearch(placeholderNode: SearchBarPlaceholderNode, navigationBar: NavigationBar?, open: @escaping (DialogModel, SearchMatch?) -> Void, cancel: @escaping () -> Void) {
        guard let (layout, _) = self.validLayout, self.searchDisplayController == nil else {
            return
        }
        // The same rows as the list, tapping into the chat; a message opens at itself.
        let interaction = ChatListInteraction(open: { dialog in
            open(dialog, nil)
        }, openArchive: {}, contextAction: { _, _, gesture in
            gesture?.cancel()
        }, toggleRead: { _ in }, setArchived: { _, _ in }, delete: { _ in })
        interaction.openSearchResult = { dialog, match in
            open(dialog, match)
        }
        let content = ChatListSearchContainerNode(context: self.context, interaction: interaction, dialogs: { [weak self] in
            return self?.dialogs ?? []
        })
        self.searchContainerNode = content
        let controller = SearchDisplayController(presentationData: self.theme.presentationData, contentNode: content, cancel: cancel, fieldStyle: placeholderNode.fieldStyle)
        self.searchDisplayController = controller
        controller.containerLayoutUpdated(layout, navigationBarHeight: self.searchNavigationBarHeight ?? 0.0, transition: .immediate)
        controller.activate(insertSubnode: { [weak self, weak placeholderNode] subnode, isSearchBar in
            guard let self, let placeholderNode else {
                return
            }
            if isSearchBar {
                placeholderNode.supernode?.insertSubnode(subnode, aboveSubnode: placeholderNode)
            } else if let navigationBar {
                self.insertSubnode(subnode, belowSubnode: navigationBar)
            } else {
                self.addSubnode(subnode)
            }
        }, placeholder: placeholderNode)
    }

    func deactivateSearch(placeholderNode: SearchBarPlaceholderNode) {
        if let controller = self.searchDisplayController {
            controller.deactivate(placeholder: placeholderNode)
            self.searchDisplayController = nil
        }
    }

    private var searchNavigationBarHeight: CGFloat?

    func updateSearchLayout(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.searchNavigationBarHeight = navigationBarHeight
        self.searchDisplayController?.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        self.backgroundColor = theme.chatList.backgroundColor
        for pane in self.panes.values {
            pane.updateTheme(theme)
        }
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .immediate)
        }
    }

    /// Telegram's order: pinned chats on top, the latest pin first, then the rest by activity as the store sorts them.
    static func pinnedFirst(_ dialogs: [DialogModel]) -> [DialogModel] {
        let pinned = dialogs.filter { $0.pinned != nil }.sorted { ($0.pinned ?? 0) > ($1.pinned ?? 0) }
        return pinned + dialogs.filter { $0.pinned == nil }
    }

    func update(dialogs: [DialogModel]) {
        self.dialogs = dialogs
        guard self.validLayout != nil else {
            self.pendingDialogs = dialogs
            return
        }
        for (id, pane) in self.panes {
            var folder: ChatFolder?
            if case let .folder(value) = id {
                folder = self.folders[value]
            }
            pane.update(dialogs: dialogs, folder: folder)
        }
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

        self.updatePanes(transition: transition)

        if isFirstLayout, let dialogs = self.pendingDialogs {
            self.pendingDialogs = nil
            self.update(dialogs: dialogs)
        }
    }
}

/// Telegram's empty folder (ChatListEmptyNode with `.filter`): its animation, a title and a line, and Edit Folder.
final class ChatListFolderEmptyNode: ASDisplayNode {
    private let animation = ComponentView<Empty>()
    private let titleNode = ImmediateTextNode()
    private let textNode = ImmediateTextNode()
    private let buttonNode = HighlightableButtonNode()
    private var theme: TauTheme
    private let action: () -> Void

    init(theme: TauTheme, action: @escaping () -> Void) {
        self.theme = theme
        self.action = action
        super.init()
        self.titleNode.textAlignment = .center
        self.textNode.textAlignment = .center
        self.textNode.maximumNumberOfLines = 3
        self.addSubnode(self.titleNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.buttonNode)
        self.buttonNode.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
        self.buttonNode.accessibilityIdentifier = "editFolder"
        self.updateTheme(theme)
    }

    @objc private func pressed() {
        self.action()
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        let list = theme.presentationTheme.list
        self.titleNode.attributedText = NSAttributedString(string: "Folder is empty", font: Font.semibold(17.0), textColor: list.itemPrimaryTextColor)
        self.textNode.attributedText = NSAttributedString(string: "No chats currently belong to this folder.", font: Font.regular(15.0), textColor: list.itemSecondaryTextColor)
        self.buttonNode.setAttributedTitle(NSAttributedString(string: "Edit Folder", font: Font.regular(17.0), textColor: list.itemAccentColor), for: .normal)
    }

    func animateIn() {
        (self.animation.view as? LottieComponent.View)?.playOnce()
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    func update(size: CGSize, insets: UIEdgeInsets) {
        let animationSize = CGSize(width: 124.0, height: 124.0)
        let _ = self.animation.update(transition: .immediate, component: AnyComponent(LottieComponent(content: LottieComponent.AppBundleContent(name: "ChatListFilterEmpty"), startingPosition: .begin, size: animationSize, lottieSettings: .noAccountFallback)), environment: {}, containerSize: animationSize)
        if let view = self.animation.view, view.superview == nil {
            self.view.addSubview(view)
            (view as? LottieComponent.View)?.playOnce()
        }
        let width = size.width - 64.0
        let titleSize = self.titleNode.updateLayout(CGSize(width: width, height: 100.0))
        let textSize = self.textNode.updateLayout(CGSize(width: width, height: 100.0))
        let buttonSize = self.buttonNode.measure(CGSize(width: width, height: 44.0))
        let total = animationSize.height + 16.0 + titleSize.height + 8.0 + textSize.height + 16.0 + buttonSize.height
        let visible = size.height - insets.top - insets.bottom
        var y = insets.top + max(16.0, floor((visible - total) * 0.45))
        self.animation.view?.frame = CGRect(origin: CGPoint(x: floor((size.width - animationSize.width) / 2.0), y: y), size: animationSize)
        y += animationSize.height + 16.0
        self.titleNode.frame = CGRect(origin: CGPoint(x: floor((size.width - titleSize.width) / 2.0), y: y), size: titleSize)
        y += titleSize.height + 8.0
        self.textNode.frame = CGRect(origin: CGPoint(x: floor((size.width - textSize.width) / 2.0), y: y), size: textSize)
        y += textSize.height + 16.0
        self.buttonNode.frame = CGRect(origin: CGPoint(x: floor((size.width - buttonSize.width) / 2.0), y: y), size: buttonSize)
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

/// A folder tab as a context menu's anchor, as ChatListHeaderBarContextReferenceContentSource: the menu under the tab.
private final class ChatListTabContextReferenceSource: ContextReferenceContentSource {
    let keepInPlace: Bool = true
    let actionsHorizontalAlignment: ContextActionsHorizontalAlignment = .center
    private let sourceView: ContextExtractedContentContainingView

    init(sourceView: ContextExtractedContentContainingView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView.contentView, contentAreaInScreenSpace: UIScreen.main.bounds, actionsPosition: .bottom)
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
