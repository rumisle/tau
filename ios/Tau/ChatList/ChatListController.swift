import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import MergeLists
import ComponentFlow
import ComponentDisplayAdapters
import TabBarComponent
import EdgeEffect

private struct ChatListEntry: Comparable, Identifiable {
    let dialog: DialogModel
    /// Position in the list; the store sorts by last activity.
    let index: Int

    var stableId: Int {
        return self.dialog.id
    }

    static func < (lhs: ChatListEntry, rhs: ChatListEntry) -> Bool {
        return lhs.index < rhs.index
    }

    static func == (lhs: ChatListEntry, rhs: ChatListEntry) -> Bool {
        return lhs.dialog == rhs.dialog && lhs.index == rhs.index
    }
}

final class ChatListController: ViewController {
    private let store: MockStore
    private let theme: TauTheme
    private let dialogsDisposable = MetaDisposable()

    private var controllerNode: ChatListControllerNode {
        return self.displayNode as! ChatListControllerNode
    }

    init(store: MockStore, theme: TauTheme) {
        self.store = store
        self.theme = theme
        // iOS 26 Telegram: glass buttons and a blurred edge instead of a bar.
        super.init(navigationBarPresentationData: theme.navigationBarPresentationData(style: .glass))
        self.title = "Chats"
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .plain, target: self, action: #selector(self.composePressed))
        self.statusBar.statusBarStyle = .Black
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.dialogsDisposable.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ChatListControllerNode(theme: self.theme, openDialog: { [weak self] dialog in
            self?.open(conversationId: dialog.id)
        })
        self.dialogsDisposable.set((self.store.dialogsSignal() |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            self?.controllerNode.update(dialogs: dialogs)
        }))
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }

    @objc private func composePressed() {
        let id = self.store.createConversation(cwd: "~/work/tau")
        self.open(conversationId: id)
    }

    private func open(conversationId: Int) {
        let controller = ChatController(store: self.store, theme: self.theme, conversationId: conversationId)
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }
}

private enum RootTab: Hashable {
    case chats
    case settings
}

final class ChatListControllerNode: ASDisplayNode {
    private let theme: TauTheme
    private let openDialog: (DialogModel) -> Void
    private let listNode: ListViewImpl
    /// Telegram's floating glass tab bar (TabBarComponent, copied verbatim).
    private let tabBarView = ComponentView<Empty>()
    private let bottomEdgeEffectView = EdgeEffectView()
    private let settingsPlaceholderNode = ImmediateTextNode()
    private var selectedTab: RootTab = .chats
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?

    private var entries: [ChatListEntry] = []
    private var pendingDialogs: [DialogModel]?
    private var hasLayout = false

    init(theme: TauTheme, openDialog: @escaping (DialogModel) -> Void) {
        self.theme = theme
        self.openDialog = openDialog
        self.listNode = ListViewImpl()
        super.init()
        self.backgroundColor = theme.chatList.backgroundColor
        self.addSubnode(self.listNode)
        self.settingsPlaceholderNode.attributedText = NSAttributedString(string: "Settings come with the server connection.", font: Font.regular(15.0), textColor: theme.chatList.messageTextColor)
        self.settingsPlaceholderNode.isHidden = true
        self.addSubnode(self.settingsPlaceholderNode)
    }

    override func didLoad() {
        super.didLoad()
        self.bottomEdgeEffectView.isUserInteractionEnabled = false
        self.view.addSubview(self.bottomEdgeEffectView)
    }

    private func select(_ tab: RootTab) {
        guard tab != self.selectedTab else {
            return
        }
        self.selectedTab = tab
        self.listNode.isHidden = tab != .chats
        self.settingsPlaceholderNode.isHidden = tab != .settings
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
        }
    }

    func update(dialogs: [DialogModel]) {
        guard self.hasLayout else {
            self.pendingDialogs = dialogs
            return
        }
        let entries = dialogs.enumerated().map { ChatListEntry(dialog: $0.element, index: $0.offset) }
        let isInitial = self.entries.isEmpty
        let previous = self.entries
        self.entries = entries
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: previous, rightList: entries)
        let theme = self.theme
        let openDialog = self.openDialog
        let makeItem: (ChatListEntry) -> ListViewItem = { entry in
            ChatListItem(theme: theme, dialog: entry.dialog, action: openDialog)
        }
        self.listNode.transaction(
            deleteIndices: deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) },
            insertIndicesAndItems: indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: makeItem($0.1), directionHint: nil) },
            updateIndicesAndItems: updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: makeItem($0.1), directionHint: nil) },
            options: isInitial ? [.Synchronous, .LowLatency] : [.AnimateInsertion],
            updateOpaqueState: nil
        )
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationHeight)
        let tabBarHeight = self.updateTabBar(layout: layout, transition: transition)

        let placeholderSize = self.settingsPlaceholderNode.updateLayout(CGSize(width: layout.size.width - 40.0, height: 100.0))
        self.settingsPlaceholderNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - placeholderSize.width) / 2.0), y: floor((layout.size.height - placeholderSize.height) / 2.0)), size: placeholderSize)

        // Rows scroll under the tab bar; a white fade keeps it legible, as in Telegram's ChatListContainerItemNode.
        let edgeEffectHeight = tabBarHeight + 8.0
        let edgeEffectFrame = CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - edgeEffectHeight), size: CGSize(width: layout.size.width, height: edgeEffectHeight))
        transition.updateFrame(view: self.bottomEdgeEffectView, frame: edgeEffectFrame)
        self.bottomEdgeEffectView.update(content: self.theme.chatList.backgroundColor, alpha: 0.6, rect: edgeEffectFrame, edge: .bottom, edgeSize: min(edgeEffectFrame.height, 40.0), transition: ComponentTransition(transition))

        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        let insets = UIEdgeInsets(top: navigationHeight, left: layout.safeInsets.left, bottom: tabBarHeight, right: layout.safeInsets.right)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)
        if !self.hasLayout {
            self.hasLayout = true
            if let tabBar = self.tabBarView.view {
                self.view.bringSubviewToFront(tabBar)
            }
            if let dialogs = self.pendingDialogs {
                self.pendingDialogs = nil
                self.update(dialogs: dialogs)
            }
        }
    }
}

extension ChatListControllerNode {
    /// Lays out the floating tab bar as Telegram's TabBarControllerNode.updateImpl does and returns the height it covers
    /// at the bottom of the screen.
    fileprivate func updateTabBar(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) -> CGFloat {
        let panelsBottomInset = max(layout.insets(options: []).bottom, 8.0)
        let sideInset: CGFloat = panelsBottomInset <= 28.0 ? 20.0 : 12.0

        let items: [(RootTab, String, String)] = [
            (.chats, "Chats", "Chat List/Tabs/IconChats"),
            (.settings, "Settings", "Chat List/Tabs/IconSettings"),
        ]
        let tabBarSize = self.tabBarView.update(
            transition: ComponentTransition(transition),
            component: AnyComponent(TabBarComponent(
                theme: self.theme.presentationTheme,
                strings: self.theme.presentationStrings,
                items: items.map { tab, title, icon in
                    TabBarComponent.Item(
                        content: .customItem(.init(id: AnyHashable(tab), title: title, icon: .bundleIcon(name: icon))),
                        action: { [weak self] _ in
                            self?.select(tab)
                        },
                        doubleTapAction: nil,
                        contextAction: nil
                    )
                },
                search: nil,
                selectedId: AnyHashable(self.selectedTab),
                outerInsets: UIEdgeInsets(top: 0.0, left: sideInset, bottom: panelsBottomInset, right: sideInset)
            )),
            environment: {},
            containerSize: CGSize(width: layout.size.width - sideInset * 2.0, height: 100.0)
        )
        let tabBarFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - tabBarSize.width) * 0.5), y: layout.size.height - tabBarSize.height - panelsBottomInset), size: tabBarSize)
        if let tabBar = self.tabBarView.view {
            if tabBar.superview == nil {
                self.view.addSubview(tabBar)
            }
            transition.updateFrame(view: tabBar, frame: tabBarFrame)
        }
        return tabBarSize.height + panelsBottomInset
    }
}
