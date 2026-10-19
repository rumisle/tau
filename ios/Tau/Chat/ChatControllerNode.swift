import UIKit
import AsyncDisplayKit
import Display
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
    private let toastView = ToastView()
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
        self.view.addSubview(self.toastView)
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        self.backgroundColor = theme.chat.backgroundColor
        self.wallpaperNode.update(wallpaper: theme.wallpaper, animated: true)
        self.inputPanelNode.updateTheme(theme)
        self.selectionPanel.update(theme: theme)
        self.toastView.update(theme: theme)
        self.reloadItems()
        self.relayout(.immediate)
    }

    private func relayout(_ transition: ContainedViewLayoutTransition) {
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: transition)
        }
    }

    func showToast(_ text: String) {
        self.toastView.show(text)
        self.relayout(.immediate)
    }

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
        self.state = state
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
            // Reopen where the user left off, as Telegram restores a chat's scroll position.
            if let scrollState = self.initialScrollState, let index = entries.firstIndex(where: { $0.message.id == scrollState.messageId }) {
                scrollToItem = ListViewScrollToItem(index: index, position: .top(scrollState.offset), animated: false, curve: .Default(duration: nil), directionHint: .Up)
            }
            self.initialScrollState = nil
        } else {
            options.insert(.AnimateInsertion)
            // A message the user just sent scrolls the history to the end.
            if indicesAndItems.contains(where: { $0.0 == 0 && $0.1.message.role == .user }) {
                scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up)
            }
        }
        self.historyNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: updates, options: options, scrollToItem: scrollToItem, updateOpaqueState: nil)
    }

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
    })

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

    private func item(for entry: ChatHistoryEntry) -> ListViewItem {
        return ChatMessageItem(theme: self.theme, message: entry.message, isStreaming: entry.isStreaming, selection: entry.selection, isExpanded: entry.isExpanded, interaction: self.interaction)
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

            let toastSize = self.toastView.sizeThatFits(CGSize(width: size.width - 80.0, height: 44.0))
            self.toastView.frame = CGRect(x: floor((size.width - toastSize.width) / 2.0), y: panelFrame.minY - toastSize.height - 12.0, width: toastSize.width, height: toastSize.height)

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

/// A short glass notice above the input panel, like Telegram's tooltips.
private final class ToastView: UIView {
    private let backgroundView = GlassBackgroundView()
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?
    private var isDark = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.alpha = 0.0
        self.isUserInteractionEnabled = false
        self.addSubview(self.backgroundView)
        self.backgroundView.contentView.addSubview(self.label)
        self.label.font = Font.medium(15.0)
        self.label.textAlignment = .center
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(theme: TauTheme) {
        self.label.textColor = theme.chat.inputTextColor
        self.isDark = theme.overallDarkAppearance
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = self.label.sizeThatFits(size)
        return CGSize(width: min(size.width, ceil(text.width) + 32.0), height: 40.0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.backgroundView.frame = self.bounds
        self.backgroundView.update(size: self.bounds.size, cornerRadius: self.bounds.height / 2.0, isDark: self.isDark, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
        self.label.frame = self.bounds
    }

    func show(_ text: String) {
        self.label.text = text
        self.setNeedsLayout()
        self.hideWork?.cancel()
        UIView.animate(withDuration: 0.25) {
            self.alpha = 1.0
        }
        self.layer.animateScale(from: 0.8, to: 1.0, duration: 0.35, timingFunction: kCAMediaTimingFunctionSpring)
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.25) {
                self?.alpha = 0.0
            }
        }
        self.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
