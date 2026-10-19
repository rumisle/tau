import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import MergeLists

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
        super.init(navigationBarPresentationData: theme.navigationBarPresentationData())
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

final class ChatListControllerNode: ASDisplayNode {
    private let theme: TauTheme
    private let openDialog: (DialogModel) -> Void
    private let listNode: ListViewImpl

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
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        let insets = UIEdgeInsets(top: navigationHeight, left: layout.safeInsets.left, bottom: layout.intrinsicInsets.bottom, right: layout.safeInsets.right)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)
        if !self.hasLayout {
            self.hasLayout = true
            if let dialogs = self.pendingDialogs {
                self.pendingDialogs = nil
                self.update(dialogs: dialogs)
            }
        }
    }
}
