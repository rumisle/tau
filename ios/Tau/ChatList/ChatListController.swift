import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import MergeLists
import ComponentFlow
import ComponentDisplayAdapters
import EdgeEffect
import ActivityIndicator
import ContextUI
import TelegramPresentationData

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
    private var statusDisposable: Disposable?
    private let titleView = ChatListTitleView()
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
        self.titleView.update(theme: self.theme)
        // As Telegram's chat list: the title says when the list may be stale.
        self.statusDisposable = (context.store.connectionStatus |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let self else {
                return
            }
            switch status {
            case .online:
                self.title = "Chats"
                self.navigationItem.titleView = nil
            case .connecting:
                self.title = ""
                self.titleView.text = "Connecting…"
                self.navigationItem.titleView = self.titleView
            case .updating:
                self.title = ""
                self.titleView.text = "Updating…"
                self.navigationItem.titleView = self.titleView
            }
        })
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
        self.statusDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ChatListControllerNode(context: self.context, theme: self.theme, openDialog: { [weak self] dialog in
            self?.open(conversationId: dialog.id)
        }, contextAction: { [weak self] dialog, sourceNode, gesture in
            self?.openContextMenu(dialog: dialog, sourceNode: sourceNode, gesture: gesture)
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
        self.titleView.update(theme: theme)
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

    /// New Chat, as Telegram's compose button: pick where the agent works, then the chat replaces the picker.
    func compose() {
        let compose = ComposeController(context: self.context, open: { [weak self] cwd in
            self?.startChat(cwd: cwd)
        })
        (self.navigationController as? NavigationController)?.pushViewController(compose)
    }

    func startChat(cwd: String?) {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        let id = self.context.store.createConversation(cwd: cwd)
        let chat = ChatController(context: self.context, conversationId: id)
        // Drop the picker screens under the new chat, so Back returns to the list.
        let kept = navigationController.viewControllers.filter { !($0 is ComposeController || $0 is FolderBrowserController) }
        navigationController.setViewControllers(kept + [chat], animated: true)
        Queue.mainQueue().after(0.45) {
            chat.activateInput()
        }
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
    private func openContextMenu(dialog: DialogModel, sourceNode: ContextControllerSourceNode, gesture: ContextGesture?) {
        let store = self.context.store
        let strings = self.theme.presentationStrings
        let chat = ChatController(context: self.context, conversationId: dialog.id, isPreview: true)
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: strings.ChatList_Context_MarkAsRead, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/MarkAsRead"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
        })))
        items.append(.action(ContextMenuActionItem(text: "Duplicate", icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
            let _ = store.duplicateConversation(dialog.id)
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
        chat.previewTapped = { [weak self, weak contextController] in
            contextController?.dismiss(result: .dismissWithoutContent, completion: nil)
            self?.open(conversationId: dialog.id)
        }
        self.presentInGlobalOverlay(contextController)
    }
}

final class ChatListControllerNode: ASDisplayNode {
    private let context: AppContext
    private var theme: TauTheme
    private let openDialog: (DialogModel) -> Void
    private let contextAction: (DialogModel, ContextControllerSourceNode, ContextGesture?) -> Void
    private let listNode: ListViewImpl
    private let bottomEdgeEffectView = EdgeEffectView()

    private var entries: [ChatListEntry] = []
    private var pendingDialogs: [DialogModel]?
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?

    init(context: AppContext, theme: TauTheme, openDialog: @escaping (DialogModel) -> Void, contextAction: @escaping (DialogModel, ContextControllerSourceNode, ContextGesture?) -> Void) {
        self.context = context
        self.theme = theme
        self.openDialog = openDialog
        self.contextAction = contextAction
        self.listNode = ListViewImpl()
        super.init()
        self.backgroundColor = theme.chatList.backgroundColor
        self.addSubnode(self.listNode)
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
        return ChatListItem(theme: self.theme, dialog: entry.dialog, action: self.openDialog, contextAction: self.contextAction)
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

/// "Connecting…" with Telegram's spinner, in place of the title while the list may be stale (ChatListTitleView).
final class ChatListTitleView: UIView {
    private let label = UILabel()
    private let indicator = ActivityIndicator(type: .custom(.black, 16.0, 1.5, false))

    var text: String = "" {
        didSet {
            self.label.text = self.text
            self.setNeedsLayout()
        }
    }

    init() {
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 200.0, height: 44.0))
        self.label.font = Font.semibold(17.0)
        self.addSubview(self.label)
        self.addSubview(self.indicator.view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(theme: TauTheme) {
        self.label.textColor = theme.navigationBar.primaryTextColor
        self.indicator.type = .custom(theme.navigationBar.secondaryTextColor, 16.0, 1.5, false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelSize = self.label.sizeThatFits(CGSize(width: self.bounds.width - 30.0, height: 30.0))
        let total = 16.0 + 8.0 + labelSize.width
        let x = floor((self.bounds.width - total) / 2.0)
        self.indicator.view.frame = CGRect(x: x, y: floor((self.bounds.height - 16.0) / 2.0), width: 16.0, height: 16.0)
        self.label.frame = CGRect(x: x + 24.0, y: floor((self.bounds.height - labelSize.height) / 2.0), width: labelSize.width, height: labelSize.height)
    }
}
