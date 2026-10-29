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
    /// In place of the input panel while the chat is searched: where in the results, and Up and Down to step.
    private let searchPanel = ChatSearchPanelView()
    /// The chat's own search: the result shown (0 the newest) of how many, nil while not searching.
    var searchPanelState: (index: Int, count: Int, isSearching: Bool)? {
        didSet {
            if (oldValue == nil) != (self.searchPanelState == nil) {
                self.updateDownButton(animated: true)
            }
            if let (layout, navigationHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .animated(duration: 0.25, curve: .easeInOut))
            }
        }
    }
    /// Up (+1, older) or Down (-1, newer) in the results.
    var searchStep: ((Int) -> Void)?
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
    /// A message found by search, to open at; cleared once it is on screen.
    var focus: ChatFocus?
    /// Asks for older history until the entry is loaded, for `focus`.
    var requestHistory: ((Int) -> Void)?
    private var requestedHistoryFor: Int?
    /// Messages whose matched words are marked, and the words.
    var searchHighlight: (entryIds: Set<Int>, terms: [SearchTerm])? {
        didSet {
            self.reloadItems()
        }
    }

    /// The row of an entry that shows what was found: its prompt, answer or reasoning.
    private func row(of entryId: Int, kind: SearchMatch.Kind, in entries: [ChatHistoryEntry]) -> Int? {
        let rows = entries.indices.filter { entries[$0].message.entryId == entryId }
        let preferred = rows.first { index in
            switch (kind, entries[index].message.role) {
            case (.user, .user), (.assistant, .assistant), (.reasoning, .thinking):
                return true
            default:
                return false
            }
        }
        return preferred ?? rows.last
    }

    /// Scroll so the row of `entryId` is in the middle, as Telegram moves to a found message.
    func scroll(toEntry entryId: Int, kind: SearchMatch.Kind, animated: Bool) -> Bool {
        guard let index = self.row(of: entryId, kind: kind, in: self.entries) else {
            return false
        }
        self.historyNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous], scrollToItem: ListViewScrollToItem(index: index, position: .center(.top), animated: animated, curve: .Spring(duration: 0.4), directionHint: .Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil)
        return true
    }
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
            // A selection stays as the text scrolls with it; its menu, which would stay where the text was, steps
            // aside until the list stops.
            self?.inlineSelectionNode?.setInlineSelectionMenuHidden(true)
        }
        self.historyNode.didEndScrolling = { [weak self] _ in
            self?.inlineSelectionNode?.setInlineSelectionMenuHidden(false)
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
        // A tap anywhere else ends a selection made in place; a drag scrolls under it.
        let selectionTap = UITapGestureRecognizer(target: self, action: #selector(self.selectionTapped(_:)))
        selectionTap.cancelsTouchesInView = false
        selectionTap.delaysTouchesEnded = false
        selectionTap.delegate = self.selectionTapDelegate
        self.view.addGestureRecognizer(selectionTap)
        self.bottomEdgeEffectView.isUserInteractionEnabled = false
        self.view.insertSubview(self.bottomEdgeEffectView, belowSubview: self.inputPanelNode.view)
        self.selectionPanel.alpha = 0.0
        self.searchPanel.alpha = 0.0
        self.searchPanel.isUserInteractionEnabled = false
        self.searchPanel.step = { [weak self] delta in
            self?.searchStep?(delta)
        }
        self.selectionPanel.action = { [weak self] action in
            self?.selectionAction?(action)
        }
        self.view.addSubview(self.selectionPanel)
        self.view.addSubview(self.searchPanel)
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
    var newChatServerTapped: ((UIView) -> Void)?
    var newChatModelTapped: (() -> Void)?

    private func layoutNewChatCard(size: CGSize, top: CGFloat, bottom: CGFloat, transition: ContainedViewLayoutTransition) {
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
        var transition = transition
        if let current = self.newChatCardNode {
            node = current
        } else {
            transition = .immediate
            node = NewChatCardNode()
            node.serverTapped = { [weak self] view in
                self?.newChatServerTapped?(view)
            }
            node.modelTapped = { [weak self] in
                self?.newChatModelTapped?()
            }
            self.newChatCardNode = node
            self.insertSubnode(node, aboveSubnode: self.historyNode)
        }
        let cardSize = node.update(content: content, theme: self.theme, width: size.width)
        // Centered in the area the transcript would fill, as ChatEmptyNode is.
        // It moves with the keyboard, on the keyboard's own curve, as ChatEmptyNode does.
        transition.updateFrame(node: node, frame: CGRect(origin: CGPoint(x: floor((size.width - cardSize.width) / 2.0), y: floor(top + (bottom - top - cardSize.height) / 2.0)), size: cardSize))
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
        self.updateTestState(state)
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
        if ChatControllerNode.isWaiting(state: state, messages: messages) {
            // Working with nothing to show yet: the τ where the answer will start.
            messages.append(ChatMessage(id: ChatControllerNode.waitingRowId, role: .assistant, text: "", date: Date(timeIntervalSince1970: 0.0), isStreaming: true, isWaiting: true, retry: state.retry))
        }
        // One row per ID: the list's diff pairs rows by it, and two with one ID gave two rows one item node, which
        // crashed the list laying out its rows (a stale live answer beside its committed message did).
        var seenIds = Set<Int>()
        messages = messages.filter { message in
            if seenIds.insert(message.id).inserted {
                return true
            }
            assertionFailure("two rows with ID \(message.id)")
            return false
        }
        // The answer's blocks come one after another: once the next has begun, the one before is written, and goes on
        // to its end at once instead of at the reveal's pace for text still coming (a provider that buffers sends the
        // whole thinking, then the answer, and the thinking took seconds to show while pushing the answer down).
        let lastStreaming = messages.lastIndex(where: \.isStreaming)
        var entries = messages.enumerated().map { index, message in
            ChatHistoryEntry(message: message, index: index, isStreaming: message.isStreaming && (index == lastStreaming || message.tool != nil), selection: message.isStreaming ? nil : selectedIds.map { $0.contains(message.id) }, isExpanded: expanded.contains(message.id))
        }
        entries.sort()

        let previous = self.entries
        self.entries = entries
        self.isMakingRows = true
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
            if indicesAndItems.contains(where: { $0.0 <= 1 && $0.1.message.role == .user }) {
                scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up)
            }
        }
        // A message found by search: there once its entry is loaded, older history loading until it is.
        if let focus = self.focus {
            if let index = self.row(of: focus.entryId, kind: focus.kind, in: entries) {
                self.focus = nil
                self.initialScrollState = nil
                options.insert(.Synchronous)
                scrollToItem = ListViewScrollToItem(index: index, position: .center(.top), animated: false, curve: .Default(duration: nil), directionHint: .Up)
            } else if state.hasOlder {
                if self.requestedHistoryFor != focus.entryId || entries.count != previous.count {
                    self.requestedHistoryFor = focus.entryId
                    self.requestHistory?(focus.entryId)
                }
            } else if state.isLoaded && !entries.isEmpty {
                self.focus = nil
            }
        }
        self.historyNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: updates, options: options, scrollToItem: scrollToItem, updateOpaqueState: nil)
        self.isMakingRows = false
        if self.reloadAfterRows {
            self.reloadAfterRows = false
            self.reloadItems()
        }
        // Nothing here yet and the server's still to come: Telegram's spinner until it does. Shown with the chat as it
        // opens, gone with an animation.
        self.updateIsLoading(!state.isLoaded && entries.isEmpty, animated: self.contentReady == nil)
        if let contentReady = self.contentReady {
            self.contentReady = nil
            contentReady()
        }
    }

    // MARK: - Loading

    private var loadingNode: ChatLoadingNode?
    private var isLoadingValue = false
    private var loadingInsets = UIEdgeInsets()

    /// As Telegram's ChatControllerNode.updateIsLoading for a one-to-one chat.
    private func updateIsLoading(_ isLoading: Bool, animated: Bool) {
        guard isLoading != self.isLoadingValue else {
            return
        }
        self.isLoadingValue = isLoading
        if isLoading {
            let loadingNode: ChatLoadingNode
            if let current = self.loadingNode {
                loadingNode = current
            } else {
                loadingNode = ChatLoadingNode(theme: self.theme.presentationTheme, chatWallpaper: self.theme.wallpaper)
                self.loadingNode = loadingNode
                self.insertSubnode(loadingNode, belowSubnode: self.historyNode)
                self.layoutLoadingNode(transition: .immediate)
            }
            loadingNode.isHidden = false
            loadingNode.layer.removeAllAnimations()
            loadingNode.alpha = 1.0
            if animated {
                loadingNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            }
        } else if let loadingNode = self.loadingNode {
            loadingNode.alpha = 0.0
            if animated {
                loadingNode.layer.animateScale(from: 1.0, to: 0.1, duration: 0.3, removeOnCompletion: false)
                loadingNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, completion: { [weak loadingNode] completed in
                    loadingNode?.layer.removeAllAnimations()
                    if completed {
                        loadingNode?.isHidden = true
                    }
                })
            } else {
                loadingNode.isHidden = true
            }
        }
    }

    private func layoutLoadingNode(transition: ContainedViewLayoutTransition) {
        guard let loadingNode = self.loadingNode, let (layout, _) = self.validLayout else {
            return
        }
        transition.updateFrame(node: loadingNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        loadingNode.updateLayout(size: layout.size, insets: self.loadingInsets, transition: transition)
    }

    static let waitingRowId = Int.min / 2

    /// The agent has the message and nothing of its answer is on screen: not writing, no tool card spinning. A message
    /// still on its way has its clock instead: the agent has nothing to work on yet.
    private static func isWaiting(state: ConversationState, messages: [ChatMessage]) -> Bool {
        // A compaction's pill says the conversation is busy with it; under it, the last message.
        if messages.contains(where: { if case .compacting = $0.service { return true } else { return false } }) {
            return false
        }
        guard state.busy, let last = messages.last(where: { $0.role != .service }), !last.isStreaming, last.delivery == .delivered else {
            return false
        }
        // A call still running has its own spinner.
        for message in messages.reversed() {
            if message.role == .user {
                break
            }
            if let status = message.tool?.status, status == .preparing || status == .pending || status == .running {
                return false
            }
        }
        return true
    }

    /// Called once, when the first update is laid out: what the phone has, or the loading spinner. As Telegram's
    /// history node is ready with its loading state, a chat never waits for the network to open.
    var contentReady: (() -> Void)?

    /// While the rows of an update are being made: `entries` is already the new list and the list's items are not yet,
    /// so a reload asked for meanwhile (something an item reads answering at once) waits for the update's transaction;
    /// one between the two updated rows the list did not have, and crashed it.
    private var isMakingRows = false
    private var reloadAfterRows = false

    private func reloadItems() {
        if self.isMakingRows {
            self.reloadAfterRows = true
            return
        }
        self.isMakingRows = true
        let updates = self.entries.enumerated().map { ListViewUpdateItem(index: $0.offset, previousIndex: $0.offset, item: self.item(for: $0.element), directionHint: nil) }
        self.isMakingRows = false
        self.reloadAfterRows = false
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
        // One selection at a time: the lifted message's own.
        self.endInlineSelection()
        self.openContextMenu?(message, node, gesture)
    }, openTool: { [weak self] message in
        self?.openTool?(message)
    }, openImage: { [weak self] attachmentId in
        self?.openImage?(attachmentId)
    })

    var openImage: ((Int) -> Void)?

    /// Set by the controller: a link's tap and its long press.
    func setLinkHandlers(open: @escaping (String) -> Void, menu: @escaping (String, Int, TapLongTapOrDoubleTapGestureRecognizer) -> Void) {
        self.interaction.openURL = open
        self.interaction.openLinkMenu = menu
    }

    /// The row whose text a double tap selected, in place (ChatMessageItemNode.beginInlineSelection): one at a time.
    private weak var inlineSelectionNode: ChatMessageItemNode?

    private let selectionTapDelegate = SimultaneousGestureDelegate()

    /// For the UI tests (`-uiTesting`): what the chat is doing, as an element they wait on instead of sleeping:
    /// "loading" until its transcript is known, "busy" while the agent works, streams, has messages queued or a message
    /// is on its way, else "idle".
    private lazy var testStateView: UIView? = {
        guard UserDefaults.standard.bool(forKey: "uiTesting"), !self.isPreview else {
            return nil
        }
        let view = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "chatState"
        self.view.addSubview(view)
        return view
    }()

    private func updateTestState(_ state: ConversationState) {
        guard let view = self.testStateView else {
            return
        }
        let busy = state.busy || state.streaming != nil || !state.queued.isEmpty || state.messages.contains(where: { $0.delivery == .sending })
        view.accessibilityValue = !state.isLoaded ? "loading" : busy ? "busy" : "idle"
    }

    @objc private func selectionTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let node = self.inlineSelectionNode else {
            return
        }
        if node.inlineSelectionContains(recognizer.location(in: node.view)) {
            return
        }
        self.endInlineSelection()
    }

    func endInlineSelection() {
        self.inlineSelectionNode?.endInlineSelection(animated: true)
        self.inlineSelectionNode = nil
        self.stopSelectionScrolling()
    }

    // MARK: - Scrolling under a selection's knob

    /// As ChatHistoryListNode scrolls while a finger selects messages: a knob held within 50 pt of the list's ends
    /// scrolls it on after 0.45 s, faster the nearer the end, and the knob follows what passes under the finger.
    private var selectionScrollActivationTimer: SwiftSignalKit.Timer?
    private var selectionScrollDisplayLink: ConstantDisplayLinkAnimator?
    private var selectionScrollDelta: CGFloat?
    private var selectionScrollSkipUpdate = false

    private func selectionKnobMoved(_ node: ChatMessageItemNode, _ windowPoint: CGPoint?) {
        guard let windowPoint, node === self.inlineSelectionNode else {
            self.stopSelectionScrolling()
            return
        }
        // The list is inverted: its y runs up from the field.
        let location = self.historyNode.view.convert(windowPoint, from: nil)
        let insets = self.historyNode.insets
        let height = self.historyNode.bounds.height
        let scrollingAreaHeight: CGFloat = 50.0
        var delta: CGFloat?
        if location.y < scrollingAreaHeight + insets.top {
            delta = (scrollingAreaHeight - (location.y - insets.top)) / scrollingAreaHeight
        } else if location.y > height - scrollingAreaHeight - insets.bottom {
            delta = -(scrollingAreaHeight - min(scrollingAreaHeight, max(0.0, height - insets.bottom - location.y))) / scrollingAreaHeight
        }
        // Only toward more of the message: past its end there is nothing to select.
        if let value = delta, let frame = node.selectableFrameInWindow() {
            let visible = self.historyNode.view.convert(CGRect(x: 0.0, y: insets.top, width: self.historyNode.bounds.width, height: height - insets.top - insets.bottom), to: nil)
            if value > 0.0 ? frame.maxY <= visible.maxY : frame.minY >= visible.minY {
                delta = nil
            }
        }
        self.selectionScrollDelta = delta
        guard delta != nil else {
            self.selectionScrollDisplayLink?.isPaused = true
            self.selectionScrollActivationTimer?.invalidate()
            self.selectionScrollActivationTimer = nil
            return
        }
        if let displayLink = self.selectionScrollDisplayLink {
            displayLink.isPaused = false
        } else if self.selectionScrollActivationTimer == nil {
            let timer = SwiftSignalKit.Timer(timeout: 0.45, repeat: false, completion: { [weak self] in
                self?.setupSelectionScrolling()
            }, queue: .mainQueue())
            timer.start()
            self.selectionScrollActivationTimer = timer
        }
    }

    private func setupSelectionScrolling() {
        self.selectionScrollActivationTimer = nil
        self.selectionScrollDisplayLink = ConstantDisplayLinkAnimator(update: { [weak self] in
            guard let self, let delta = self.selectionScrollDelta, let node = self.inlineSelectionNode else {
                self?.stopSelectionScrolling()
                return
            }
            let distance: CGFloat = 15.0 * min(1.0, 0.15 + abs(delta * delta))
            let _ = self.historyNode.scrollWithDirection(delta > 0.0 ? .up : .down, distance: distance)
            if !self.selectionScrollSkipUpdate {
                node.updateInlineSelectionKnob()
            }
            self.selectionScrollSkipUpdate = !self.selectionScrollSkipUpdate
        })
        self.selectionScrollDisplayLink?.isPaused = false
    }

    private func stopSelectionScrolling() {
        self.selectionScrollActivationTimer?.invalidate()
        self.selectionScrollActivationTimer = nil
        self.selectionScrollDisplayLink?.invalidate()
        self.selectionScrollDisplayLink = nil
        self.selectionScrollDelta = nil
    }

    /// Set by the controller: where a file of the chat is, and a tap on its row (docs/files.md).
    func setFileHandlers(status: @escaping (FileAttachment) -> Signal<FileTransferStatus, NoError>, open: @escaping (FileAttachment, FileTransferStatus) -> Void) {
        self.interaction.fileStatus = status
        self.interaction.openFile = open
    }

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
            self.interaction.beganInlineSelection = { [weak self] node in
                guard let self else {
                    return
                }
                if let current = self.inlineSelectionNode, current !== node {
                    current.endInlineSelection(animated: true)
                }
                self.inlineSelectionNode = node
            }
            self.interaction.selectionKnobMoved = { [weak self] node, point in
                self?.selectionKnobMoved(node, point)
            }
            self.interaction.selectionMenuArea = { [weak self] in
                guard let self, let (_, navigationHeight) = self.validLayout else {
                    return nil
                }
                let bottom = self.isPreview ? self.bounds.height : self.inputPanelNode.frame.minY
                return CGRect(x: 0.0, y: navigationHeight, width: self.bounds.width, height: max(0.0, bottom - navigationHeight))
            }
            self.interaction.quote = { [weak self] text in
                self?.inputPanelNode.insertQuote(text)
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
        // A user's photos, and the images tools gave the model; those on the server once the chat shows them.
        for entry in self.entries.reversed() {
            for attachment in entry.message.attachments + (entry.message.tool?.images ?? []) + (entry.message.tool?.sentFiles ?? []) {
                switch attachment.kind {
                case let .image(image):
                    result.append(ImageGalleryEntry(attachmentId: attachment.id, image: image, date: entry.message.date))
                case let .remote(remote):
                    if let image = remote.cachedDisplay {
                        result.append(ImageGalleryEntry(attachmentId: attachment.id, image: image, remote: remote, date: entry.message.date))
                    }
                case .file:
                    break
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
        let highlight = self.searchHighlight.flatMap { highlight in entry.message.entryId.flatMap { highlight.entryIds.contains($0) ? highlight.terms : nil } }
        let references = self.linkReferences?.references(in: entry.message.text) ?? []
        return ChatMessageItem(theme: self.theme, message: entry.message, isStreaming: entry.isStreaming, selection: entry.selection, isExpanded: entry.isExpanded, wrapCode: self.wrapCode, riseFrom: riseFrom, highlightTerms: highlight, references: references, interaction: self.interaction)
    }

    /// What the chat's tau links name (docs/links.md); set by the controller. A linked message that comes later lays the
    /// rows out again.
    var linkReferences: LinkReferenceResolver? {
        didSet {
            self.linkReferences?.updated = { [weak self] in
                self?.reloadItems()
                self?.linkReferencesUpdated?()
            }
        }
    }

    /// A linked message came: the field's preview may show it now.
    var linkReferencesUpdated: (() -> Void)?

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
            let isSearchingChat = self.searchPanelState != nil
            let inputAlpha: CGFloat = isSelecting || isSearchingChat ? 0.0 : 1.0
            if self.inputPanelNode.view.alpha != inputAlpha {
                if transition.isAnimated {
                    UIView.animate(withDuration: 0.25, animations: {
                        self.inputPanelNode.view.alpha = inputAlpha
                    })
                } else {
                    self.inputPanelNode.view.alpha = inputAlpha
                }
            }
            self.inputPanelNode.isUserInteractionEnabled = !isSelecting && !isSearchingChat

            let searchFrame = CGRect(x: panelFrame.minX, y: size.height - bottomInset - (keyboardHeight > 0.0 ? 8.0 : max(0.0, 8.0 - layout.intrinsicInsets.bottom)) - 48.0, width: panelWidth, height: 48.0)
            transition.updateFrame(view: self.searchPanel, frame: searchFrame)
            if let state = self.searchPanelState {
                self.searchPanel.layout(size: searchFrame.size, theme: self.theme, index: state.index, count: state.count, isSearching: state.isSearching, transition: ComponentTransition(transition))
            }
            let searchAlpha: CGFloat = isSearchingChat ? 1.0 : 0.0
            if self.searchPanel.alpha != searchAlpha {
                if transition.isAnimated {
                    UIView.animate(withDuration: 0.25, animations: {
                        self.searchPanel.alpha = searchAlpha
                    })
                } else {
                    self.searchPanel.alpha = searchAlpha
                }
            }
            self.searchPanel.isUserInteractionEnabled = isSearchingChat

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
        self.layoutNewChatCard(size: size, top: navigationHeight, bottom: panelFrame.minY, transition: transition)
        let historyInsets = UIEdgeInsets(
            // Room under the last answer, as Telegram leaves under its last message.
            top: size.height - panelFrame.minY + 16.0,
            left: layout.safeInsets.right,
            bottom: navigationHeight + 6.0,
            right: layout.safeInsets.left
        )
        transition.updateFrame(node: self.wallpaperNode, frame: CGRect(origin: CGPoint(), size: size))
        self.wallpaperNode.updateLayout(size: size, transition: transition)
        // Centered in what the transcript would fill, as Telegram's visible area: between the bar and the panel.
        self.loadingInsets = UIEdgeInsets(top: navigationHeight, left: layout.safeInsets.left, bottom: size.height - panelFrame.minY + 8.0, right: layout.safeInsets.right)
        self.layoutLoadingNode(transition: transition)
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
        // Search's arrows take its place while the chat is searched.
        let visible = !self.isAtBottom && self.selectedIds == nil && self.searchPanelState == nil
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

/// The bar that replaces the input panel while the chat is searched, as Telegram's search panel: where in the results
/// on a glass pill, and round glass Up and Down buttons, Up going to older results.
private final class ChatSearchPanelView: UIView {
    private let container = GlassBackgroundContainerView()
    private let labelBackground = GlassBackgroundView()
    private let label = UILabel()
    private let upButton = SelectionGlassButtonView(icon: "Chat/Input/Search/UpButton", label: "Previous Result")
    private let downButton = SelectionGlassButtonView(icon: "Chat/Input/Search/DownButton", label: "Next Result")
    var step: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.container)
        self.container.contentView.addSubview(self.labelBackground)
        self.labelBackground.contentView.addSubview(self.label)
        self.container.contentView.addSubview(self.upButton)
        self.container.contentView.addSubview(self.downButton)
        self.label.accessibilityIdentifier = "searchResultCount"
        self.upButton.button.addTarget(self, action: #selector(self.upTapped), for: .touchUpInside)
        self.downButton.button.addTarget(self, action: #selector(self.downTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func upTapped() {
        self.step?(1)
    }

    @objc private func downTapped() {
        self.step?(-1)
    }

    func layout(size: CGSize, theme: TauTheme, index: Int, count: Int, isSearching: Bool, transition: ComponentTransition) {
        transition.setFrame(view: self.container, frame: CGRect(origin: CGPoint(), size: size))
        self.container.update(size: size, isDark: theme.overallDarkAppearance, transition: transition)
        let strings = theme.presentationStrings
        let text: String
        // Nothing typed yet: no count, as Telegram's search panel until there is a query.
        transition.setAlpha(view: self.labelBackground, alpha: count < 0 ? 0.0 : 1.0)
        if count < 0 {
            text = self.label.text ?? ""
        } else if isSearching && count == 0 {
            text = "Searching…"
        } else if count == 0 {
            text = strings.Conversation_SearchNoResults
        } else {
            // Telegram's "3 of 12", counting from the newest.
            text = strings.Items_NOfM("\(index + 1)", "\(count)").string
        }
        self.label.text = text
        self.label.font = Font.regular(15.0)
        self.label.textColor = theme.chat.panelControlColor
        let labelSize = self.label.sizeThatFits(CGSize(width: size.width - 120.0, height: 40.0))
        let pill = CGRect(x: 0.0, y: floor((size.height - 40.0) / 2.0), width: ceil(labelSize.width) + 32.0, height: 40.0)
        transition.setFrame(view: self.labelBackground, frame: pill)
        self.labelBackground.update(size: pill.size, cornerRadius: 20.0, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: transition)
        self.label.frame = CGRect(x: 16.0, y: floor((40.0 - labelSize.height) / 2.0), width: ceil(labelSize.width), height: ceil(labelSize.height))
        let buttonSize = CGSize(width: 40.0, height: 40.0)
        let y = floor((size.height - buttonSize.height) / 2.0)
        transition.setFrame(view: self.downButton, frame: CGRect(origin: CGPoint(x: size.width - buttonSize.width, y: y), size: buttonSize))
        transition.setFrame(view: self.upButton, frame: CGRect(origin: CGPoint(x: size.width - buttonSize.width * 2.0 - 8.0, y: y), size: buttonSize))
        self.upButton.isEnabled = index + 1 < count
        self.downButton.isEnabled = index > 0
        self.upButton.update(theme: theme, size: buttonSize, transition: transition)
        self.downButton.update(theme: theme, size: buttonSize, transition: transition)
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


/// A recognizer that watches alongside the others, taking nothing from them.
private final class SimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
