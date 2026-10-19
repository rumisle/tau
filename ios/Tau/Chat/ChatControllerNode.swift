import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import MergeLists
import GradientBackground

/// A transcript row as the list diffs it. List index 0 is the newest message, at the bottom of the inverted list.
struct ChatHistoryEntry: Comparable, Identifiable {
    let message: ChatMessage
    let isStreaming: Bool

    var stableId: Int {
        return self.message.id
    }

    static func < (lhs: ChatHistoryEntry, rhs: ChatHistoryEntry) -> Bool {
        return lhs.message.id > rhs.message.id
    }

    static func == (lhs: ChatHistoryEntry, rhs: ChatHistoryEntry) -> Bool {
        return lhs.message == rhs.message && lhs.isStreaming == rhs.isStreaming
    }
}

/// Wallpaper, inverted history list and input panel, laid out around the keyboard the way Telegram's
/// ChatControllerNode does: the list's top inset (its visual bottom, as the list is rotated) clears the input panel.
final class ChatControllerNode: ASDisplayNode {
    private let theme: TauTheme
    private let backgroundNode: GradientBackgroundNode
    let historyNode: ListViewImpl
    let inputPanelNode: ChatInputPanelNode

    private var entries: [ChatHistoryEntry] = []
    private var pendingState: (ConversationState, Bool)?
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?
    private var hasAppliedInitialState = false

    var sendMessage: ((String) -> Void)?

    init(theme: TauTheme) {
        self.theme = theme
        self.backgroundNode = createGradientBackgroundNode(colors: theme.chat.wallpaperColors)
        self.historyNode = ListViewImpl()
        self.historyNode.rotated = true
        self.inputPanelNode = ChatInputPanelNode(theme: theme)

        super.init()

        self.backgroundColor = theme.chat.wallpaperColors.first
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.historyNode)
        self.addSubnode(self.inputPanelNode)

        self.historyNode.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
        self.historyNode.verticalScrollIndicatorColor = UIColor(white: 0.0, alpha: 0.3)
        // Dragging the history away puts the keyboard down, as in Telegram.
        self.historyNode.beganInteractiveDragging = { [weak self] _ in
            self?.inputPanelNode.deactivateInput()
        }

        self.inputPanelNode.sendMessage = { [weak self] text in
            guard let self else {
                return
            }
            self.sendMessage?(text)
            // Telegram turns the gradient wallpaper a step with every sent message.
            self.backgroundNode.animateEvent(transition: .animated(duration: 0.5, curve: .spring), extendAnimation: false, backwards: false, completion: {})
        }
        self.inputPanelNode.requestLayout = { [weak self] transition in
            guard let self, let (layout, navigationHeight) = self.validLayout else {
                return
            }
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: transition)
        }
    }

    // MARK: - History

    func update(state: ConversationState) {
        guard self.validLayout != nil else {
            // The list cannot lay items out before it has a size.
            self.pendingState = (state, false)
            return
        }
        var entries = state.messages.map { ChatHistoryEntry(message: $0, isStreaming: false) }
        if let streaming = state.streaming {
            entries.append(ChatHistoryEntry(message: streaming, isStreaming: true))
        }
        entries.sort()

        let previous = self.entries
        self.entries = entries
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: previous, rightList: entries)

        let deletions = deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) }
        let insertions = indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: self.item(for: $0.1), directionHint: nil) }
        let updates = updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: self.item(for: $0.1), directionHint: nil) }

        var options = ListViewDeleteAndInsertOptions()
        var scrollToItem: ListViewScrollToItem?
        if !self.hasAppliedInitialState {
            self.hasAppliedInitialState = true
            options.insert(.Synchronous)
            options.insert(.LowLatency)
        } else {
            options.insert(.AnimateInsertion)
            // A message the user just sent scrolls the history to the end.
            if indicesAndItems.contains(where: { $0.0 == 0 && $0.1.message.role == .user }) {
                scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up)
            }
        }
        self.historyNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: updates, options: options, scrollToItem: scrollToItem, updateOpaqueState: nil)
    }

    private func item(for entry: ChatHistoryEntry) -> ListViewItem {
        return ChatMessageItem(theme: self.theme, message: entry.message, isStreaming: entry.isStreaming, requestRelayout: { [weak self] id in
            self?.relayout(messageId: id)
        })
    }

    /// Re-lays out one row with its current item, animating its height.
    private func relayout(messageId: Int) {
        guard let index = self.entries.firstIndex(where: { $0.message.id == messageId }) else {
            return
        }
        let update = ListViewUpdateItem(index: index, previousIndex: index, item: self.item(for: self.entries[index]), directionHint: nil)
        self.historyNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [update], options: [.AnimateInsertion], updateOpaqueState: nil)
    }

    // MARK: - Layout

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let isFirstLayout = self.validLayout == nil
        self.validLayout = (layout, navigationHeight)
        let size = layout.size

        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(), size: size))
        self.backgroundNode.updateLayout(size: size, transition: transition, extendAnimation: false, backwards: false, completion: {})

        // The keyboard, when up, replaces the bottom safe area.
        let bottomInset = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        let panelSideInset: CGFloat = 10.0
        let panelWidth = size.width - layout.safeInsets.left - layout.safeInsets.right - panelSideInset * 2.0
        let panelHeight = self.inputPanelNode.updateLayout(width: panelWidth, transition: transition)
        let panelBottomGap: CGFloat = layout.inputHeight != nil && layout.inputHeight! > 0.0 ? 8.0 : (layout.intrinsicInsets.bottom > 0.0 ? 0.0 : 8.0)
        let panelFrame = CGRect(origin: CGPoint(x: layout.safeInsets.left + panelSideInset, y: size.height - bottomInset - panelBottomGap - panelHeight), size: CGSize(width: panelWidth, height: panelHeight))
        transition.updateFrame(node: self.inputPanelNode, frame: panelFrame)

        // The history runs under the navigation bar and the panel; its insets keep content clear of both. The list is
        // rotated, so its top inset is the visual bottom.
        let historyInsets = UIEdgeInsets(
            top: size.height - panelFrame.minY + 6.0,
            left: layout.safeInsets.right,
            bottom: navigationHeight + 6.0,
            right: layout.safeInsets.left
        )
        transition.updateFrame(node: self.historyNode, frame: CGRect(origin: CGPoint(), size: size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.historyNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: size, insets: historyInsets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)

        if isFirstLayout, let (state, _) = self.pendingState {
            self.pendingState = nil
            self.update(state: state)
        }
    }
}
