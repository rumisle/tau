import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import MergeLists
import ComponentFlow
import ComponentDisplayAdapters
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
    private let context: AppContext
    private var theme: TauTheme
    private let dialogsDisposable = MetaDisposable()
    private var themeDisposable: Disposable?

    private var controllerNode: ChatListControllerNode {
        return self.displayNode as! ChatListControllerNode
    }

    init(context: AppContext) {
        self.context = context
        self.theme = context.theme
        // iOS 26 Telegram: glass buttons and a blurred edge instead of a bar.
        super.init(navigationBarPresentationData: context.theme.navigationBarPresentationData())
        self.title = "Chats"
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil")?.withRenderingMode(.alwaysTemplate), style: .plain, target: self, action: #selector(self.composePressed))
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
    }

    override func loadDisplayNode() {
        self.displayNode = ChatListControllerNode(context: self.context, theme: self.theme, openDialog: { [weak self] dialog in
            self?.open(conversationId: dialog.id)
        }, previewController: { [weak self] dialog in
            guard let self else {
                return nil
            }
            return ChatController(context: self.context, conversationId: dialog.id, isPreview: true)
        })
        self.dialogsDisposable.set((self.context.store.dialogsSignal() |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            self?.controllerNode.update(dialogs: dialogs)
        }))
        self.displayNodeDidLoad()
    }

    private func updateTheme(_ theme: TauTheme) {
        guard theme !== self.theme else {
            return
        }
        self.theme = theme
        self.statusBar.statusBarStyle = theme.statusBarStyleValue
        self.navigationBar?.updatePresentationData(theme.navigationBarPresentationData(), transition: .immediate)
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

    func compose() {
        let id = self.context.store.createConversation(cwd: "~/work/tau")
        self.open(conversationId: id)
    }

    func open(conversationId: Int) {
        let controller = ChatController(context: self.context, conversationId: conversationId)
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }
}

final class ChatListControllerNode: ASDisplayNode, UIContextMenuInteractionDelegate {
    private let context: AppContext
    private var theme: TauTheme
    private let openDialog: (DialogModel) -> Void
    private let previewController: (DialogModel) -> ChatController?
    private let listNode: ListViewImpl
    private let bottomEdgeEffectView = EdgeEffectView()

    private var entries: [ChatListEntry] = []
    private var pendingDialogs: [DialogModel]?
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?

    init(context: AppContext, theme: TauTheme, openDialog: @escaping (DialogModel) -> Void, previewController: @escaping (DialogModel) -> ChatController?) {
        self.context = context
        self.theme = theme
        self.openDialog = openDialog
        self.previewController = previewController
        self.listNode = ListViewImpl()
        super.init()
        self.backgroundColor = theme.chatList.backgroundColor
        self.addSubnode(self.listNode)
    }

    override func didLoad() {
        super.didLoad()
        self.bottomEdgeEffectView.isUserInteractionEnabled = false
        self.view.addSubview(self.bottomEdgeEffectView)
        // Long press a row: a live preview of the chat with actions, as Telegram's chat list context menu.
        self.listNode.view.addInteraction(UIContextMenuInteraction(delegate: self))
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
        return ChatListItem(theme: self.theme, dialog: entry.dialog, action: self.openDialog)
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
        let entries = dialogs.enumerated().map { ChatListEntry(dialog: $0.element, index: $0.offset) }
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

    // MARK: - Long press preview

    private func dialog(at point: CGPoint, in view: UIView) -> (DialogModel, ChatListItemNode)? {
        var result: (DialogModel, ChatListItemNode)?
        self.listNode.forEachItemNode { itemNode in
            guard result == nil, let itemNode = itemNode as? ChatListItemNode, itemNode.isNodeLoaded, let dialog = itemNode.dialog else {
                return
            }
            if itemNode.bounds.contains(itemNode.view.convert(point, from: view)) {
                result = (dialog, itemNode)
            }
        }
        return result
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let view = interaction.view, let (dialog, _) = self.dialog(at: location, in: view) else {
            return nil
        }
        let store = self.context.store
        return UIContextMenuConfiguration(identifier: NSNumber(value: dialog.id), previewProvider: { [weak self] in
            guard let self, let chat = self.previewController(dialog) else {
                return nil
            }
            return ChatPreviewHostController(chat: chat, size: CGSize(width: self.bounds.width - 32.0, height: floor(self.bounds.height * 0.62)))
        }, actionProvider: { _ in
            let pin = UIAction(title: "Mark as Read", image: UIImage(systemName: "checkmark.message")) { _ in }
            let duplicate = UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { _ in
                let _ = store.duplicateConversation(dialog.id)
            }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                store.deleteConversation(dialog.id)
            }
            return UIMenu(children: [pin, duplicate, delete])
        })
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? NSNumber else {
            return nil
        }
        var target: UITargetedPreview?
        self.listNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ChatListItemNode, itemNode.dialog?.id == id.intValue {
                let parameters = UIPreviewParameters()
                parameters.visiblePath = UIBezierPath(roundedRect: itemNode.view.bounds, cornerRadius: 16.0)
                target = UITargetedPreview(view: itemNode.view, parameters: parameters)
            }
        }
        return target
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        guard let id = configuration.identifier as? NSNumber, let dialog = self.entries.first(where: { $0.dialog.id == id.intValue })?.dialog else {
            return
        }
        animator.preferredCommitStyle = .pop
        animator.addCompletion { [weak self] in
            self?.openDialog(dialog)
        }
    }
}

/// Hosts a chat screen as a context menu preview: Display's ViewController lays out from a ContainerViewLayout, which
/// nothing provides inside a preview, so this computes one from its own bounds.
final class ChatPreviewHostController: UIViewController {
    private let chat: ChatController

    init(chat: ChatController, size: CGSize) {
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
        self.preferredContentSize = size
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.addChild(self.chat)
        self.view.addSubview(self.chat.view)
        self.chat.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = self.view.bounds.size
        guard size.width > 0.0 else {
            return
        }
        self.chat.view.frame = CGRect(origin: CGPoint(), size: size)
        let layout = ContainerViewLayout(size: size, metrics: LayoutMetrics(), deviceMetrics: .unknown(screenSize: size, statusBarHeight: 0.0, onScreenNavigationHeight: nil, screenCornerRadius: 0.0), intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), additionalInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false)
        self.chat.containerLayoutUpdated(layout, transition: .immediate)
    }
}
