import UIKit
import AsyncDisplayKit
import Display
import UndoUI
import SwiftSignalKit
import MergeLists
import ComponentFlow
import ComponentDisplayAdapters
import EdgeEffect
import GlassBackgroundComponent

/// A transcript row as the list diffs it. List index 0 is the newest message, at the bottom of the inverted list.
struct ChatHistoryEntry: Comparable, Identifiable {
    let message: ChatMessage
    /// Position in the transcript; row IDs are stable but not ordered.
    let index: Int
    let isStreaming: Bool
    let selection: Bool?
    let isExpanded: Bool

    var stableId: Int {
        return self.message.id
    }

    static func < (lhs: ChatHistoryEntry, rhs: ChatHistoryEntry) -> Bool {
        return lhs.index > rhs.index
    }

    static func == (lhs: ChatHistoryEntry, rhs: ChatHistoryEntry) -> Bool {
        return lhs.message == rhs.message && lhs.index == rhs.index && lhs.isStreaming == rhs.isStreaming && lhs.selection == rhs.selection && lhs.isExpanded == rhs.isExpanded
    }
}

/// Actions on a message, from its context menu or the selection panel.
enum ChatMessageAction {
    case copy
    case edit
    case select
    case share
}

/// The inverted history list, input panel and selection panel, laid out around the keyboard the way Telegram's
/// ChatControllerNode does: the list's top inset (its visual bottom, as the list is rotated) clears the input panel.
final class ChatControllerNode: ASDisplayNode {
    private var theme: TauTheme
    let historyNode: ListViewImpl
    let inputPanelNode: ChatInputPanelNode
    private let selectionPanel = SelectionPanelView()
    /// Blurs messages as they scroll under the input panel.
    private let bottomEdgeEffectView = EdgeEffectView()
    let wallpaperNode = WallpaperNode()
    /// Telegram's scroll-to-bottom button, with the count of messages that arrived below.
    private var downButton: ChatHistoryNavigationButtonNode?
    /// Glass renders inside a glass container, as the input panel's controls do.
    private let downButtonContainer = GlassBackgroundContainerView()
    private var isAtBottom = true
    private var unseenCount = 0
    private let isPreview: Bool

    private var state: ConversationState?
    private var entries: [ChatHistoryEntry] = []
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?
    private var hasAppliedInitialState = false
    /// Where to open the history; consumed by the first transaction.
    var initialScrollState: ChatScrollState?
    private(set) var selectedIds: Set<Int>?

    var sendMessage: ((String) -> Void)?
    var messageAction: ((ChatMessage, ChatMessageAction) -> Void)?
    var openContextMenu: ((ChatMessage, ChatMessageItemNode, ContextGesture?) -> Void)?
    var openTool: ((ChatMessage) -> Void)?
    /// Scrolled near the oldest loaded message.
    var loadOlder: (() -> Void)?
    var selectionAction: ((ChatMessageAction) -> Void)?
    var selectionChanged: ((Set<Int>?) -> Void)?

    init(theme: TauTheme, isPreview: Bool) {
        self.theme = theme
        self.isPreview = isPreview
        self.historyNode = ListViewImpl()
        self.historyNode.rotated = true
        self.inputPanelNode = ChatInputPanelNode(theme: theme)

        super.init()

        self.backgroundColor = theme.chat.backgroundColor
        self.wallpaperNode.update(wallpaper: theme.wallpaper, animated: false)
        self.addSubnode(self.wallpaperNode)
        self.addSubnode(self.historyNode)
        if !isPreview {
            self.addSubnode(self.inputPanelNode)
        }

        self.historyNode.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
        // Dragging the history away puts the keyboard down, as in Telegram.
        self.historyNode.beganInteractiveDragging = { [weak self] _ in
            self?.inputPanelNode.deactivateInput()
        }
        // The list is inverted, so its top offset is the distance from the end of the chat.
        self.historyNode.visibleContentOffsetChanged = { [weak self] offset, _ in
            guard let self else {
                return
            }
            let atBottom: Bool
            switch offset {
            case let .known(value):
                atBottom = value < 120.0
            case .none:
                atBottom = true
            case .unknown:
                atBottom = false
            }
            if atBottom != self.isAtBottom {
                self.isAtBottom = atBottom
                if atBottom {
                    self.unseenCount = 0
                }
                self.updateDownButton(animated: true)
            }
        }
        // The list is inverted: the highest visible index is the oldest message on screen.
        self.historyNode.displayedItemRangeChanged = { [weak self] range, _ in
            guard let self, let visible = range.visibleRange, let state = self.state, state.hasOlder else {
                return
            }
            if visible.lastIndex >= self.entries.count - 8 {
                self.loadOlder?()
            }
        }
        self.inputPanelNode.sendMessage = { [weak self] text in
            self?.sendMessage?(text)
        }
        self.inputPanelNode.requestLayout = { [weak self] transition in
            self?.relayout(transition)
        }
    }

    override func didLoad() {
        super.didLoad()
        guard !self.isPreview else {
            return
        }
        self.bottomEdgeEffectView.isUserInteractionEnabled = false
        self.view.insertSubview(self.bottomEdgeEffectView, belowSubview: self.inputPanelNode.view)
        self.selectionPanel.alpha = 0.0
        self.selectionPanel.action = { [weak self] action in
            self?.selectionAction?(action)
        }
        self.view.addSubview(self.selectionPanel)
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        self.backgroundColor = theme.chat.backgroundColor
        self.wallpaperNode.update(wallpaper: theme.wallpaper, animated: true)
        self.downButton?.updateTheme(theme: theme.presentationTheme, preferClearGlass: false)
        self.inputPanelNode.updateTheme(theme)
        self.selectionPanel.update(theme: theme)
        self.reloadItems()
        self.relayout(.immediate)
    }

    private func relayout(_ transition: ContainedViewLayoutTransition) {
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: transition)
        }
    }

    /// As Telegram's ChatControllerNode while previewing: touches reach only the history's scrolling, so the preview
    /// scrolls and a tap anywhere opens the chat instead of acting on a message.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.isPreview, self.bounds.contains(point) {
            return self.historyNode.scroller
        }
        return super.hitTest(point, with: event)
    }

    /// The card of an empty new chat (NewChatCardNode); nil hides it.
    var newChatCard: NewChatCardNode.Content? {
        didSet {
            if self.newChatCard != oldValue {
                self.relayout(.immediate)
            }
        }
    }
    private var newChatCardNode: NewChatCardNode?
    var newChatProjectTapped: (() -> Void)?
    var newChatModelTapped: (() -> Void)?

    private func layoutNewChatCard(size: CGSize, top: CGFloat, bottom: CGFloat) {
        let isEmpty = (self.state?.messages.isEmpty ?? true) && self.state?.streaming == nil
        guard let content = self.newChatCard, isEmpty, !self.isPreview else {
            if let node = self.newChatCardNode {
                self.newChatCardNode = nil
                node.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak node] _ in
                    node?.removeFromSupernode()
                })
                node.layer.animateScale(from: 1.0, to: 0.8, duration: 0.2, removeOnCompletion: false)
            }
            return
        }
        let node: NewChatCardNode
        if let current = self.newChatCardNode {
            node = current
        } else {
            node = NewChatCardNode()
            node.projectTapped = { [weak self] in
                self?.newChatProjectTapped?()
            }
            node.modelTapped = { [weak self] in
                self?.newChatModelTapped?()
            }
            self.newChatCardNode = node
            self.insertSubnode(node, aboveSubnode: self.historyNode)
        }
        let cardSize = node.update(content: content, theme: self.theme, width: size.width)
        // Centered in the area the transcript would fill, as ChatEmptyNode is.
        node.frame = CGRect(origin: CGPoint(x: floor((size.width - cardSize.width) / 2.0), y: floor(top + (bottom - top - cardSize.height) / 2.0)), size: cardSize)
    }

    /// Telegram's toast (UndoOverlayController), which ChatController presents above the input panel.
    var presentToast: ((UndoOverlayContent) -> Void)?

    /// How far from the bottom the input panel's top is: what overlays presented over the chat keep clear of.
    private(set) var inputPanelInset: CGFloat = 0.0

    // MARK: - Selection

    /// Enters, updates or leaves selection mode. Rows animate their checks in; the input panel gives way to the
    /// selection panel with `transition`, which the context menu reuses to put a lifted message back.
    func setSelection(_ ids: Set<Int>?, transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .spring)) {
        self.selectedIds = ids
        self.selectionChanged?(ids)
        if let state = self.state {
            self.update(state: state)
        }
        self.relayout(transition)
    }

    private func toggleSelection(_ id: Int) {
        guard var ids = self.selectedIds else {
            return
        }
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        self.setSelection(ids)
    }

    // MARK: - History

    func update(state: ConversationState) {
        // Messages leaving the queue for the transcript rise from the panel.
        let left = (self.state?.queued ?? []).filter { old in old.mode != .newContext && !state.queued.contains(where: { $0.id == old.id }) }
        if !left.isEmpty, let source = self.inputPanelNode.accessoryFrameInWindow() {
            for queued in left {
                self.riseSources[queued.text] = source
            }
        }
        let wasEmpty = self.state.map { $0.messages.isEmpty && $0.streaming == nil } ?? true
        self.state = state
        self.inputPanelNode.setQueue(state.queued)
        if wasEmpty != (state.messages.isEmpty && state.streaming == nil) {
            self.relayout(.immediate)
        }
        guard self.validLayout != nil else {
            // The list cannot lay items out before it has a size.
            return
        }
        let selectedIds = self.selectedIds
        let expanded = self.expandedIds
        var messages = state.messages
        if let streaming = state.streaming {
            var streaming = streaming
            streaming.isStreaming = true
            messages.append(streaming)
        }
        var entries = messages.enumerated().map { index, message in
            ChatHistoryEntry(message: message, index: index, isStreaming: message.isStreaming, selection: message.isStreaming ? nil : selectedIds.map { $0.contains(message.id) }, isExpanded: expanded.contains(message.id))
        }
        entries.sort()

        let previous = self.entries
        self.entries = entries
        if !self.isAtBottom && !previous.isEmpty {
            // New rows below the screen: committed answers and messages, counted as Telegram counts unread ones.
            let known = Set(previous.map(\.stableId))
            let added = entries.filter { !known.contains($0.stableId) && !$0.isStreaming && $0.message.role != .thinking }.count
            if added > 0 {
                self.unseenCount += added
                self.updateDownButton(animated: true)
            }
        }
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: previous, rightList: entries)

        let deletions = deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) }
        let insertions = indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: self.item(for: $0.1), directionHint: nil) }
        let updates = updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: self.item(for: $0.1), directionHint: nil) }
        self.riseSources.removeAll()

        var options = ListViewDeleteAndInsertOptions()
        var scrollToItem: ListViewScrollToItem?
        if !self.hasAppliedInitialState {
            // The first rows may come in more than one step (cached entries, then the server's); the saved position
            // applies once its message is there.
            if !entries.isEmpty {
                self.hasAppliedInitialState = true
            }
            options.insert(.Synchronous)
            options.insert(.LowLatency)
            // Reopen where the user left off, as Telegram restores a chat's scroll position.
            if let scrollState = self.initialScrollState, let index = entries.firstIndex(where: { $0.message.id == scrollState.messageId }) {
                scrollToItem = ListViewScrollToItem(index: index, position: .top(scrollState.offset), animated: false, curve: .Default(duration: nil), directionHint: .Up)
                self.initialScrollState = nil
            } else if self.hasAppliedInitialState && !state.hasOlder {
                self.initialScrollState = nil
            }
        } else if let scrollState = self.initialScrollState, let index = entries.firstIndex(where: { $0.message.id == scrollState.messageId }) {
            // The saved position's message arrived after the first rows.
            options.insert(.Synchronous)
            scrollToItem = ListViewScrollToItem(index: index, position: .top(scrollState.offset), animated: false, curve: .Default(duration: nil), directionHint: .Up)
            self.initialScrollState = nil
        } else {
            options.insert(.AnimateInsertion)
            // A message the user just sent scrolls the history to the end.
            if indicesAndItems.contains(where: { $0.0 == 0 && $0.1.message.role == .user }) {
                scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up)
            }
        }
        self.historyNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: updates, options: options, scrollToItem: scrollToItem, updateOpaqueState: nil)
        if state.isLoaded, let contentReady = self.contentReady {
            self.contentReady = nil
            contentReady()
        }
    }

    /// Called once, when the first known transcript is laid out.
    var contentReady: (() -> Void)?

    private func reloadItems() {
        let updates = self.entries.enumerated().map { ListViewUpdateItem(index: $0.offset, previousIndex: $0.offset, item: self.item(for: $0.element), directionHint: nil) }
        self.historyNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: updates, options: [.Synchronous], updateOpaqueState: nil)
    }

    private lazy var interaction = ChatMessageItemInteraction(requestRelayout: { [weak self] id in
        self?.relayout(messageId: id)
    }, toggleSelection: { [weak self] id in
        self?.toggleSelection(id)
    }, openContextMenu: { [weak self] id, node, gesture in
        guard let self, let message = self.entries.first(where: { $0.message.id == id })?.message else {
            return
        }
        self.openContextMenu?(message, node, gesture)
    }, openTool: { [weak self] message in
        self?.openTool?(message)
    }, openImage: { [weak self] attachmentId in
        self?.openImage?(attachmentId)
    })

    var openImage: ((Int) -> Void)?

    /// Set by the controller: text selection's menu goes above the context menu.
    var presentInGlobalOverlay: ((ViewController, Any?) -> Void)? {
        didSet {
            let present = self.presentInGlobalOverlay
            self.interaction.presentInGlobalOverlay = { controller, arguments in
                present?(controller, arguments)
            }
            self.interaction.rootView = { [weak self] in
                return self?.view
            }
            self.interaction.copied = { [weak self] _ in
                guard let self else {
                    return
                }
                self.presentToast?(.copy(text: self.theme.presentationStrings.Conversation_TextCopied))
            }
        }
    }

    /// Every photo in the transcript, oldest first, for the media viewer to page through.
    func imageEntries() -> [ImageGalleryEntry] {
        var result: [ImageGalleryEntry] = []
        for entry in self.entries.reversed() {
            for attachment in entry.message.attachments {
                if case let .image(image) = attachment.kind {
                    result.append(ImageGalleryEntry(attachmentId: attachment.id, image: image))
                }
            }
        }
        return result
    }

    func imageNode(attachmentId: Int) -> ASImageNode? {
        var result: ASImageNode?
        self.historyNode.forEachItemNode { node in
            if result == nil, let node = node as? ChatMessageItemNode {
                result = node.imageNode(attachmentId: attachmentId)
            }
        }
        return result
    }

    func setHiddenAttachment(_ id: Int?) {
        self.historyNode.forEachItemNode { node in
            (node as? ChatMessageItemNode)?.setHiddenAttachment(id)
        }
    }

    /// Tool cards showing their whole output.
    private(set) var expandedIds = Set<Int>()

    func toggleExpanded(_ id: Int) {
        if self.expandedIds.contains(id) {
            self.expandedIds.remove(id)
        } else {
            self.expandedIds.insert(id)
        }
        if let state = self.state {
            self.update(state: state)
        }
    }

    /// Panel positions of messages that just left the queue, by text, for their rows' first layout.
    private var riseSources: [String: CGRect] = [:]

    private func item(for entry: ChatHistoryEntry) -> ListViewItem {
        var riseFrom: CGRect?
        if entry.message.role == .user, !self.riseSources.isEmpty {
            riseFrom = self.riseSources.removeValue(forKey: entry.message.text)
        }
        return ChatMessageItem(theme: self.theme, message: entry.message, isStreaming: entry.isStreaming, selection: entry.selection, isExpanded: entry.isExpanded, wrapCode: self.wrapCode, riseFrom: riseFrom, interaction: self.interaction)
    }

    /// Settings > Appearance > Wrap Lines in Code.
    var wrapCode = true {
        didSet {
            if self.wrapCode != oldValue {
                self.reloadItems()
            }
        }
    }

    /// Re-lays out one row with its current item, animating its height.
    private func relayout(messageId: Int) {
        guard let index = self.entries.firstIndex(where: { $0.message.id == messageId }) else {
            return
        }
        let update = ListViewUpdateItem(index: index, previousIndex: index, item: self.item(for: self.entries[index]), directionHint: nil)
        self.historyNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [update], options: [.AnimateInsertion], updateOpaqueState: nil)
    }

    /// The message at the bottom of the screen and how far it is scrolled, or nil at the end of the chat.
    func currentScrollState() -> ChatScrollState? {
        let bottom = self.historyNode.insets.top
        var candidate: (node: ChatMessageItemNode, frame: CGRect)?
        self.historyNode.forEachItemNode { node in
            guard let node = node as? ChatMessageItemNode, node.messageId != nil else {
                return
            }
            let frame = node.frame
            guard frame.maxY > bottom else {
                return
            }
            if candidate == nil || frame.minY < candidate!.frame.minY {
                candidate = (node, frame)
            }
        }
        guard let (node, frame) = candidate, let id = node.messageId else {
            return nil
        }
        if id == self.entries.first?.message.id && frame.minY >= bottom - 2.0 {
            return nil
        }
        return ChatScrollState(messageId: id, offset: frame.minY - bottom)
    }

    // MARK: - Layout

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let isFirstLayout = self.validLayout == nil
        self.validLayout = (layout, navigationHeight)
        let size = layout.size

        // The keyboard, when up, replaces the bottom safe area.
        let keyboardHeight = layout.inputHeight ?? 0.0
        let bottomInset = max(layout.intrinsicInsets.bottom, keyboardHeight)
        let panelSideInset: CGFloat = 10.0
        let panelWidth = size.width - layout.safeInsets.left - layout.safeInsets.right - panelSideInset * 2.0
        var panelFrame = CGRect(x: 0.0, y: size.height, width: panelWidth, height: 0.0)
        if !self.isPreview {
            let panelHeight = self.inputPanelNode.updateLayout(width: panelWidth, transition: transition)
            let panelBottomGap: CGFloat = keyboardHeight > 0.0 ? 8.0 : (layout.intrinsicInsets.bottom > 0.0 ? 0.0 : 8.0)
            panelFrame = CGRect(origin: CGPoint(x: layout.safeInsets.left + panelSideInset, y: size.height - bottomInset - panelBottomGap - panelHeight), size: CGSize(width: panelWidth, height: panelHeight))
            transition.updateFrame(node: self.inputPanelNode, frame: panelFrame)
            let isSelecting = self.selectedIds != nil
            let inputAlpha: CGFloat = isSelecting ? 0.0 : 1.0
            if self.inputPanelNode.view.alpha != inputAlpha {
                if transition.isAnimated {
                    UIView.animate(withDuration: 0.25, animations: {
                        self.inputPanelNode.view.alpha = inputAlpha
                    })
                } else {
                    self.inputPanelNode.view.alpha = inputAlpha
                }
            }
            self.inputPanelNode.isUserInteractionEnabled = !isSelecting

            let selectionFrame = CGRect(x: panelFrame.minX, y: size.height - max(layout.intrinsicInsets.bottom, 8.0) - 48.0, width: panelWidth, height: 48.0)
            transition.updateFrame(view: self.selectionPanel, frame: selectionFrame)
            self.selectionPanel.layout(size: selectionFrame.size, theme: self.theme, count: self.selectedIds?.count ?? 0, transition: ComponentTransition(transition))
            // View alpha, not layer opacity: glass renders wrongly under a layer opacity.
            let selectionAlpha: CGFloat = isSelecting ? 1.0 : 0.0
            if self.selectionPanel.alpha != selectionAlpha {
                if transition.isAnimated {
                    UIView.animate(withDuration: 0.25, animations: {
                        self.selectionPanel.alpha = selectionAlpha
                    })
                } else {
                    self.selectionPanel.alpha = selectionAlpha
                }
            }
            self.selectionPanel.isUserInteractionEnabled = isSelecting

            if let downButton = self.downButton {
                let buttonSize = CGSize(width: 40.0, height: 40.0)
                // Room above for the badge.
                let containerFrame = CGRect(origin: CGPoint(x: size.width - layout.safeInsets.right - 10.0 - buttonSize.width, y: panelFrame.minY - 10.0 - buttonSize.height - 10.0), size: CGSize(width: buttonSize.width, height: buttonSize.height + 10.0))
                transition.updateFrame(view: self.downButtonContainer, frame: containerFrame)
                self.downButtonContainer.update(size: containerFrame.size, isDark: self.theme.overallDarkAppearance, transition: ComponentTransition(transition))
                downButton.position = CGPoint(x: buttonSize.width / 2.0, y: 10.0 + buttonSize.height / 2.0)
                downButton.bounds = CGRect(origin: CGPoint(), size: buttonSize)
            }

            self.inputPanelInset = size.height - panelFrame.minY

            let edgeEffectHeight = size.height - panelFrame.minY + 16.0
            let edgeEffectFrame = CGRect(origin: CGPoint(x: 0.0, y: size.height - edgeEffectHeight), size: CGSize(width: size.width, height: edgeEffectHeight))
            transition.updateFrame(view: self.bottomEdgeEffectView, frame: edgeEffectFrame)
            // A color fade, not a variable blur: a blur re-samples what is behind it on every frame of a swipe back.
            // On a wallpaper the panel floats over it without a fade, as in Telegram.
            self.bottomEdgeEffectView.isHidden = !self.theme.wallpaper.isPlainColor
            self.bottomEdgeEffectView.update(content: self.theme.chat.backgroundColor, blur: false, alpha: 0.85, rect: edgeEffectFrame, edge: .bottom, edgeSize: min(edgeEffectHeight, 48.0), transition: ComponentTransition(transition))
        }

        // The history runs under the navigation bar and the panel; its insets keep content clear of both. The list is
        // rotated, so its top inset is the visual bottom.
        self.layoutNewChatCard(size: size, top: navigationHeight, bottom: panelFrame.minY)
        let historyInsets = UIEdgeInsets(
            top: size.height - panelFrame.minY + 6.0,
            left: layout.safeInsets.right,
            bottom: navigationHeight + 6.0,
            right: layout.safeInsets.left
        )
        transition.updateFrame(node: self.wallpaperNode, frame: CGRect(origin: CGPoint(), size: size))
        self.wallpaperNode.updateLayout(size: size, transition: transition)
        transition.updateFrame(node: self.historyNode, frame: CGRect(origin: CGPoint(), size: size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.historyNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: size, insets: historyInsets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)

        if isFirstLayout, let state = self.state {
            self.update(state: state)
        }
    }

    // MARK: - Scroll to bottom

    private func updateDownButton(animated: Bool) {
        guard !self.isPreview else {
            return
        }
        let button: ChatHistoryNavigationButtonNode
        if let current = self.downButton {
            button = current
        } else {
            button = ChatHistoryNavigationButtonNode(theme: self.theme.presentationTheme, preferClearGlass: false, type: .down)
            self.downButtonContainer.alpha = 0.0
            button.isUserInteractionEnabled = false
            button.tapped = { [weak self] in
                self?.scrollToBottom()
            }
            self.downButton = button
            self.view.insertSubview(self.downButtonContainer, belowSubview: self.inputPanelNode.view)
            self.downButtonContainer.contentView.addSubview(button.view)
            self.relayout(.immediate)
        }
        button.badge = self.unseenCount > 0 ? "\(self.unseenCount)" : ""
        let visible = !self.isAtBottom && self.selectedIds == nil
        button.isUserInteractionEnabled = visible
        // View alpha on the container, not layer opacity: glass renders wrongly under a layer opacity.
        let alpha: CGFloat = visible ? 1.0 : 0.0
        let transform = visible ? CGAffineTransform.identity : CGAffineTransform(scaleX: 0.2, y: 0.2)
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, options: [.beginFromCurrentState], animations: {
                self.downButtonContainer.alpha = alpha
                button.view.transform = transform
            })
        } else {
            self.downButtonContainer.alpha = alpha
            button.view.transform = transform
        }
    }

    func scrollToBottom() {
        guard !self.entries.isEmpty else {
            return
        }
        self.unseenCount = 0
        self.historyNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Spring(duration: 0.4), directionHint: .Up), updateOpaqueState: nil)
    }

    // MARK: - Context menu

    func itemNode(messageId: Int) -> ChatMessageItemNode? {
        var result: ChatMessageItemNode?
        self.historyNode.forEachItemNode { node in
            if let node = node as? ChatMessageItemNode, node.messageId == messageId {
                result = node
            }
        }
        return result
    }

    /// The part of the screen messages show in, between the navigation bar and the input panel, for the context menu to
    /// keep a lifted message within.
    func frameForVisibleArea() -> CGRect {
        guard let (layout, navigationHeight) = self.validLayout else {
            return self.bounds
        }
        let bottom = self.isPreview ? layout.size.height : self.inputPanelNode.frame.minY
        return CGRect(x: 0.0, y: navigationHeight, width: layout.size.width, height: max(0.0, bottom - navigationHeight))
    }
}

/// The bar that replaces the input panel in selection mode, as Telegram's ChatMessageSelectionInputPanelNode: round
/// glass buttons spread across the width. tau's actions are Copy and Share.
private final class SelectionPanelView: UIView {
    private let copyButton = SelectionGlassButtonView(icon: "Chat/Context Menu/Copy", label: "Copy")
    private let shareButton = SelectionGlassButtonView(icon: "Chat/Input/Accessory Panels/MessageSelectionAction", label: "Share")
    /// Glass needs a container to render in, as the input panels have in Telegram's chat.
    private let container = GlassBackgroundContainerView()
    var action: ((ChatMessageAction) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.container)
        self.container.contentView.addSubview(self.copyButton)
        self.container.contentView.addSubview(self.shareButton)
        self.copyButton.button.addTarget(self, action: #selector(self.copyTapped), for: .touchUpInside)
        self.shareButton.button.addTarget(self, action: #selector(self.shareTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func copyTapped() {
        self.action?(.copy)
    }

    @objc private func shareTapped() {
        self.action?(.share)
    }

    func update(theme: TauTheme) {
    }

    func layout(size: CGSize, theme: TauTheme, count: Int, transition: ComponentTransition) {
        transition.setFrame(view: self.container, frame: CGRect(origin: CGPoint(), size: size))
        self.container.update(size: size, isDark: theme.overallDarkAppearance, transition: transition)
        let buttonSize = CGSize(width: 40.0, height: 40.0)
        let y = floor((size.height - buttonSize.height) / 2.0)
        let buttons = [self.copyButton, self.shareButton]
        for (index, button) in buttons.enumerated() {
            let x = index == buttons.count - 1 ? size.width - buttonSize.width : 0.0
            transition.setFrame(view: button, frame: CGRect(origin: CGPoint(x: x, y: y), size: buttonSize))
            button.isEnabled = count > 0
            button.update(theme: theme, size: buttonSize, transition: transition)
        }
    }
}

/// ChatMessageSelectionInputPanelNode's GlassButtonView: an icon in a round interactive glass background.
private final class SelectionGlassButtonView: UIView {
    private let backgroundView = GlassBackgroundView()
    let button = HighlightTrackingButton()
    private let iconView = GlassBackgroundView.ContentImageView()
    private var theme: TauTheme?

    var isEnabled: Bool = true {
        didSet {
            self.iconView.alpha = self.isEnabled ? 1.0 : 0.5
            self.iconView.tintMask.alpha = self.iconView.alpha
            self.button.isEnabled = self.isEnabled
        }
    }

    init(icon: String, label: String) {
        super.init(frame: CGRect())
        self.iconView.image = UIImage(bundleImageName: icon)?.withRenderingMode(.alwaysTemplate)
        self.backgroundView.contentView.addSubview(self.iconView)
        self.backgroundView.contentView.addSubview(self.button)
        self.addSubview(self.backgroundView)
        self.button.isAccessibilityElement = true
        self.button.accessibilityLabel = label
        self.button.accessibilityIdentifier = label.lowercased()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(theme: TauTheme, size: CGSize, transition: ComponentTransition) {
        self.iconView.tintColor = theme.chat.panelControlColor
        if let image = self.iconView.image {
            transition.setFrame(view: self.iconView, frame: image.size.centered(in: CGRect(origin: CGPoint(), size: size)))
        }
        transition.setFrame(view: self.button, frame: CGRect(origin: CGPoint(), size: size))
        transition.setFrame(view: self.backgroundView, frame: CGRect(origin: CGPoint(), size: size))
        self.backgroundView.update(size: size, cornerRadius: size.height * 0.5, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: true, transition: transition)
    }
}
