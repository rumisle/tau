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
    let isStreaming: Bool
    let selection: Bool?

    var stableId: Int {
        return self.message.id
    }

    static func < (lhs: ChatHistoryEntry, rhs: ChatHistoryEntry) -> Bool {
        return lhs.message.id > rhs.message.id
    }

    static func == (lhs: ChatHistoryEntry, rhs: ChatHistoryEntry) -> Bool {
        return lhs.message == rhs.message && lhs.isStreaming == rhs.isStreaming && lhs.selection == rhs.selection
    }
}

/// Actions on a message, from its context menu.
enum ChatMessageAction {
    case copy
    case edit
    case select
    case delete
}

/// The inverted history list, input panel and selection panel, laid out around the keyboard the way Telegram's
/// ChatControllerNode does: the list's top inset (its visual bottom, as the list is rotated) clears the input panel.
final class ChatControllerNode: ASDisplayNode, UIContextMenuInteractionDelegate {
    private var theme: TauTheme
    let historyNode: ListViewImpl
    let inputPanelNode: ChatInputPanelNode
    private let selectionPanel = SelectionPanelView()
    /// Blurs messages as they scroll under the input panel.
    private let bottomEdgeEffectView = EdgeEffectView()
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
        self.addSubnode(self.historyNode)
        if !isPreview {
            self.addSubnode(self.inputPanelNode)
        }

        self.historyNode.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
        // Dragging the history away puts the keyboard down, as in Telegram.
        self.historyNode.beganInteractiveDragging = { [weak self] _ in
            self?.inputPanelNode.deactivateInput()
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
        self.historyNode.view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func updateTheme(_ theme: TauTheme) {
        self.theme = theme
        self.backgroundColor = theme.chat.backgroundColor
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

    func setSelection(_ ids: Set<Int>?) {
        self.selectedIds = ids
        self.selectionChanged?(ids)
        if let state = self.state {
            self.update(state: state)
        }
        self.relayout(.animated(duration: 0.3, curve: .easeInOut))
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
        var entries = state.messages.map { message in ChatHistoryEntry(message: message, isStreaming: false, selection: selectedIds.map { $0.contains(message.id) }) }
        if let streaming = state.streaming {
            entries.append(ChatHistoryEntry(message: streaming, isStreaming: true, selection: nil))
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
    })

    private func item(for entry: ChatHistoryEntry) -> ListViewItem {
        return ChatMessageItem(theme: self.theme, message: entry.message, isStreaming: entry.isStreaming, selection: entry.selection, interaction: self.interaction)
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
            transition.updateAlpha(node: self.inputPanelNode, alpha: isSelecting ? 0.0 : 1.0)
            self.inputPanelNode.isUserInteractionEnabled = !isSelecting

            let selectionFrame = CGRect(x: panelFrame.minX, y: size.height - max(layout.intrinsicInsets.bottom, 8.0) - 48.0, width: panelWidth, height: 48.0)
            transition.updateFrame(view: self.selectionPanel, frame: selectionFrame)
            self.selectionPanel.layout(size: selectionFrame.size, theme: self.theme, count: self.selectedIds?.count ?? 0, transition: ComponentTransition(transition))
            transition.updateAlpha(layer: self.selectionPanel.layer, alpha: isSelecting ? 1.0 : 0.0)
            self.selectionPanel.isUserInteractionEnabled = isSelecting

            let toastSize = self.toastView.sizeThatFits(CGSize(width: size.width - 80.0, height: 44.0))
            self.toastView.frame = CGRect(x: floor((size.width - toastSize.width) / 2.0), y: panelFrame.minY - toastSize.height - 12.0, width: toastSize.width, height: toastSize.height)

            let edgeEffectHeight = size.height - panelFrame.minY + 16.0
            let edgeEffectFrame = CGRect(origin: CGPoint(x: 0.0, y: size.height - edgeEffectHeight), size: CGSize(width: size.width, height: edgeEffectHeight))
            transition.updateFrame(view: self.bottomEdgeEffectView, frame: edgeEffectFrame)
            // A color fade, not a variable blur: a blur re-samples what is behind it on every frame of a swipe back.
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
        transition.updateFrame(node: self.historyNode, frame: CGRect(origin: CGPoint(), size: size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.historyNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: size, insets: historyInsets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)

        if isFirstLayout, let state = self.state {
            self.update(state: state)
        }
    }

    // MARK: - Context menu

    /// The row under `point` in `view`'s coordinates. Rows sit in the list's own containers and both are rotated, so the
    /// point is converted into each row rather than compared with frames.
    private func itemNode(at point: CGPoint, in view: UIView) -> ChatMessageItemNode? {
        var result: ChatMessageItemNode?
        self.historyNode.forEachItemNode { node in
            guard result == nil, let node = node as? ChatMessageItemNode, node.isNodeLoaded, node.item?.isStreaming == false else {
                return
            }
            let local = node.view.convert(point, from: view)
            if node.contentFrame.insetBy(dx: -4.0, dy: -4.0).contains(local) {
                result = node
            }
        }
        return result
    }

    private var hiddenMenuNode: ChatMessageItemNode?

    private func itemNode(messageId: Int) -> ChatMessageItemNode? {
        var result: ChatMessageItemNode?
        self.historyNode.forEachItemNode { node in
            if let node = node as? ChatMessageItemNode, node.messageId == messageId {
                result = node
            }
        }
        return result
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard self.selectedIds == nil, let view = interaction.view, let node = self.itemNode(at: location, in: view), let message = node.item?.message else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: NSNumber(value: message.id), previewProvider: nil, actionProvider: { [weak self] _ in
            let perform: (ChatMessageAction) -> Void = { action in
                self?.messageAction?(message, action)
            }
            var actions: [UIMenuElement] = []
            if !message.text.isEmpty {
                actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in perform(.copy) })
            }
            if message.role == .user {
                actions.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in perform(.edit) })
            }
            actions.append(UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle")) { _ in perform(.select) })
            actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in perform(.delete) })
            return UIMenu(children: actions)
        })
    }

    /// The list and its rows are both rotated, so preview an image of the row placed upright on this view. The row's
    /// layer renders in its own coordinates, which the two rotations make upright.
    private func targetedPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? NSNumber, let node = self.itemNode(messageId: id.intValue), node.bounds.width > 0.0 else {
            return nil
        }
        // Only the message itself, so the lifted preview stays where the message is.
        let contentFrame = node.contentFrame.intersection(node.bounds)
        guard !contentFrame.isEmpty else {
            return nil
        }
        let wasHidden = node.isHidden
        node.isHidden = false
        let image = UIGraphicsImageRenderer(bounds: contentFrame).image { context in
            node.layer.render(in: context.cgContext)
        }
        node.isHidden = wasHidden
        let snapshot = UIImageView(image: image)
        snapshot.frame = CGRect(origin: CGPoint(), size: contentFrame.size)
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let isBubble = node.item?.message.role == .user
        parameters.visiblePath = UIBezierPath(roundedRect: snapshot.bounds, cornerRadius: isBubble ? 17.0 : 14.0)
        let center = node.view.convert(CGPoint(x: contentFrame.midX, y: contentFrame.midY), to: self.view)
        return UITargetedPreview(view: snapshot, parameters: parameters, target: UIPreviewTarget(container: self.view, center: center))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        return self.targetedPreview(for: configuration)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        return self.targetedPreview(for: configuration)
    }

    // The preview is a snapshot, so the row itself is hidden while the menu shows it lifted.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        guard let id = configuration.identifier as? NSNumber, let node = self.itemNode(messageId: id.intValue) else {
            return
        }
        self.hiddenMenuNode = node
        node.isHidden = true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        let node = self.hiddenMenuNode
        self.hiddenMenuNode = nil
        if let animator {
            animator.addCompletion {
                node?.isHidden = false
            }
        } else {
            node?.isHidden = false
        }
    }
}

/// The bar that replaces the input panel in selection mode: Copy and Delete in glass, as Telegram's selection panel.
private final class SelectionPanelView: UIView {
    private let container = GlassBackgroundContainerView()
    private let copyBackground = GlassBackgroundView()
    private let deleteBackground = GlassBackgroundView()
    private let copyLabel = UILabel()
    private let deleteLabel = UILabel()
    var action: ((ChatMessageAction) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.container)
        self.container.contentView.addSubview(self.copyBackground)
        self.container.contentView.addSubview(self.deleteBackground)
        self.copyBackground.contentView.addSubview(self.copyLabel)
        self.deleteBackground.contentView.addSubview(self.deleteLabel)
        for label in [self.copyLabel, self.deleteLabel] {
            label.font = Font.semibold(17.0)
            label.textAlignment = .center
        }
        self.copyLabel.text = "Copy"
        self.deleteLabel.text = "Delete"
        self.copyBackground.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.copyTapped)))
        self.deleteBackground.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.deleteTapped)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func copyTapped() {
        self.action?(.copy)
    }

    @objc private func deleteTapped() {
        self.action?(.delete)
    }

    func update(theme: TauTheme) {
        self.copyLabel.textColor = theme.chat.panelControlColor
        self.deleteLabel.textColor = theme.list.itemDestructiveColor
    }

    func layout(size: CGSize, theme: TauTheme, count: Int, transition: ComponentTransition) {
        self.update(theme: theme)
        self.copyLabel.alpha = count > 0 ? 1.0 : 0.4
        self.deleteLabel.alpha = count > 0 ? 1.0 : 0.4
        transition.setFrame(view: self.container, frame: CGRect(origin: CGPoint(), size: size))
        self.container.update(size: size, isDark: theme.overallDarkAppearance, transition: transition)
        let spacing: CGFloat = 8.0
        let width = floor((size.width - spacing) / 2.0)
        let copyFrame = CGRect(x: 0.0, y: 0.0, width: width, height: size.height)
        let deleteFrame = CGRect(x: size.width - width, y: 0.0, width: width, height: size.height)
        transition.setFrame(view: self.copyBackground, frame: copyFrame)
        transition.setFrame(view: self.deleteBackground, frame: deleteFrame)
        self.copyBackground.update(size: copyFrame.size, cornerRadius: size.height / 2.0, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: true, transition: transition)
        self.deleteBackground.update(size: deleteFrame.size, cornerRadius: size.height / 2.0, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: true, transition: transition)
        self.copyLabel.frame = CGRect(origin: CGPoint(), size: copyFrame.size)
        self.deleteLabel.frame = CGRect(origin: CGPoint(), size: deleteFrame.size)
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
