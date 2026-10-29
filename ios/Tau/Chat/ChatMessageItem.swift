import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import InteractiveTextComponent
import StreamingTextReveal
import MosaicLayout
import ChatMessageSelectionNode
import ActivityIndicator
import TextSelectionNode
import TelegramPresentationData
import SemanticStatusNode

/// What a message's neighbors need to know about it: who wrote it, so consecutive user bubbles merge.
private enum ChatHistoryNeighbor: Equatable {
    case user
    case assistant
    case tool
    case service
}

final class ChatMessageItemInteraction {
    /// Lay a row out again, for example when revealed streaming text wraps to a new line.
    let requestRelayout: (Int) -> Void
    let toggleSelection: (Int) -> Void
    /// A long press on a message: open Telegram's context menu with the message lifted out of the list.
    let openContextMenu: (Int, ChatMessageItemNode, ContextGesture?) -> Void
    /// A tap on a tool card: open a subagent's conversation, or show more of the output.
    let openTool: (ChatMessage) -> Void
    /// A tap on a photo: Telegram's media viewer, growing from it. Takes the attachment's id.
    let openImage: (Int) -> Void
    /// A tap on a code block or inline code copied it (Telegram's `.copy` tap action); the chat says so.
    var copied: (String) -> Void = { _ in }
    /// A tap on a link (Telegram's `.url` tap action).
    var openURL: (String) -> Void = { _ in }
    /// A long press on a link: Telegram's link menu over the message, which the press goes on driving.
    var openLinkMenu: (String, Int, TapLongTapOrDoubleTapGestureRecognizer) -> Void = { _, _, _ in }
    /// A tool card's Show All: its whole text, in a viewer.
    var openToolText: (ChatMessage) -> Void = { _ in }
    /// A file's row: where the file is, as its circle shows; a tap fetches, stops fetching, or opens it.
    var fileStatus: (FileAttachment) -> Signal<FileTransferStatus, NoError> = { file in .single(file.localURL.map { .local($0) } ?? .remote) }
    var openFile: (FileAttachment, FileTransferStatus) -> Void = { _, _ in }
    /// Shows a controller above everything, the context menu included: the menu over selected text.
    var presentInGlobalOverlay: (ViewController, Any?) -> Void = { _, _ in }
    /// The chat's view, which text selection keeps its knobs and menu inside.
    var rootView: () -> UIView? = { nil }
    /// A double tap selected text in a row: the chat keeps one selection, ending the one before.
    var beganInlineSelection: (ChatMessageItemNode) -> Void = { _ in }
    /// A selection's knob moves, the finger where it is in the window, nil once it lifts: near the list's ends the
    /// chat scrolls on.
    var selectionKnobMoved: (ChatMessageItemNode, CGPoint?) -> Void = { _, _ in }
    /// Where a selection's menu may point, in the root view: the chat between its bar and its field.
    var selectionMenuArea: () -> CGRect? = { nil }
    /// Quote on selected text: it goes into the field (docs/quotes.md).
    var quote: (String) -> Void = { _ in }
    /// How much of each streaming answer has been revealed, by message: a row that leaves the screen and comes back gets
    /// a new node, which goes on from here instead of revealing the answer again from its first letter. Read by layouts
    /// on background queues.
    let revealProgress = Atomic<[Int: Int]>(value: [:])

    init(requestRelayout: @escaping (Int) -> Void, toggleSelection: @escaping (Int) -> Void, openContextMenu: @escaping (Int, ChatMessageItemNode, ContextGesture?) -> Void, openTool: @escaping (ChatMessage) -> Void, openImage: @escaping (Int) -> Void) {
        self.requestRelayout = requestRelayout
        self.toggleSelection = toggleSelection
        self.openContextMenu = openContextMenu
        self.openTool = openTool
        self.openImage = openImage
    }
}

/// One transcript row in the inverted chat list. User messages are Telegram outgoing bubbles; the assistant writes
/// straight on the background with no bubble; tool results are compact cards. Layout constants follow Telegram-iOS
/// ChatMessageItemLayoutConstants.compact and ChatMessageBubbleItemNode.
final class ChatMessageItem: ListViewItem {
    let theme: TauTheme
    let message: ChatMessage
    let isStreaming: Bool
    /// Nil outside selection mode; otherwise whether this message is selected.
    let selection: Bool?
    /// A tool card showing its whole output.
    let isExpanded: Bool
    /// Long code lines wrap; otherwise each code block scrolls sideways.
    let wrapCode: Bool
    /// Where a message the agent just got from the queue was, in window coordinates: its bubble rises from there.
    let riseFrom: CGRect?
    /// Search's words, marked in the text as Telegram marks a chat search's matches.
    let highlightTerms: [SearchTerm]?
    /// Its tau links' cards, under its text (docs/links.md).
    let references: [LinkReference]
    let interaction: ChatMessageItemInteraction

    init(theme: TauTheme, message: ChatMessage, isStreaming: Bool, selection: Bool?, isExpanded: Bool = false, wrapCode: Bool = true, riseFrom: CGRect? = nil, highlightTerms: [SearchTerm]? = nil, references: [LinkReference] = [], interaction: ChatMessageItemInteraction) {
        self.riseFrom = riseFrom
        self.references = references
        self.highlightTerms = highlightTerms
        self.theme = theme
        self.message = message
        self.isStreaming = isStreaming
        self.selection = selection
        self.isExpanded = isExpanded
        self.wrapCode = wrapCode
        self.interaction = interaction
    }

    var neighborDescriptor: AnyEquatable {
        switch self.message.role {
        case .user:
            return AnyEquatable(ChatHistoryNeighbor.user)
        case .assistant, .thinking:
            return AnyEquatable(ChatHistoryNeighbor.assistant)
        case .tool:
            return AnyEquatable(ChatHistoryNeighbor.tool)
        case .service:
            return AnyEquatable(ChatHistoryNeighbor.service)
        }
    }

    var approximateHeight: CGFloat {
        return 60.0
    }

    var selectable: Bool {
        // An error card's only tap is its button.
        if case .failed = self.message.service, self.selection == nil {
            return false
        }
        return self.selection != nil || self.message.tool != nil || self.message.service != nil
    }

    /// Rows whose updates add to their end: the answer as it streams, a tool's output, a card that expands. A user's
    /// bubble only changes as a whole.
    var growsAtEnd: Bool {
        return self.message.role != .user
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(false)
        if self.selection != nil {
            self.interaction.toggleSelection(self.message.id)
        } else if self.message.tool != nil || self.message.service != nil {
            self.interaction.openTool(self.message)
        }
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = ChatMessageItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, neighbors)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(.None) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? ChatMessageItemNode else {
                assertionFailure()
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            let growsAtEnd = self.growsAtEnd
            async {
                let (layout, apply) = makeLayout(self, params, neighbors)
                Queue.mainQueue().async {
                    completion(layout, { info in
                        apply(animation)
                        // As Telegram's expanding bubbles (ChatMessageTextBubbleContentNode): a row that grows at its
                        // end grows down the screen. At the end of the chat the list still follows it; scrolled back,
                        // what is being read stays where it is and the new text goes on below.
                        if growsAtEnd {
                            info.setInvertOffsetDirection()
                        }
                    })
                }
            }
        }
    }
}

/// A message's date at the theme's text size (Telegram's `floor(fontSize * 11 / 17)`).
private func dateFont(_ theme: TauTheme) -> UIFont {
    return Font.regular(theme.scaled(11.0))
}
private let toolTitleFont = Font.semibold(13.0)
private let toolFont = Font.monospace(13.0)

// Telegram ChatMessageItemLayoutConstants.compact.
private let bubbleEdgeInset: CGFloat = 3.0
private let bubbleTailInset: CGFloat = 6.0
private let bubbleMinimumSize = CGSize(width: 40.0, height: 35.0)
private let textInsets = UIEdgeInsets(top: 6.0 + UIScreenPixel, left: 11.0, bottom: 6.0 - UIScreenPixel, right: 11.0)
private let mediaInset: CGFloat = 2.0

/// A photo's size for laying it out: its own, or as its header declares it; a square when unknown.
private func photoPixelSize(_ attachment: MessageAttachment) -> CGSize {
    switch attachment.kind {
    case let .image(image) where image.size.width > 0.0 && image.size.height > 0.0:
        return image.size
    case let .remote(remote):
        return remote.pixelSize ?? CGSize(width: 256.0, height: 256.0)
    default:
        return CGSize(width: 256.0, height: 256.0)
    }
}

/// Telegram's photo sizes in a bubble (ChatMessageItemLayoutConstants.image on a phone): at most 300 by 380 pt, at least
/// 170 wide; several as an album, 1 pt apart.
private func photoMosaic(_ sizes: [CGSize], maxWidth: CGFloat) -> (frames: [(CGRect, MosaicItemPosition)], size: CGSize) {
    guard !sizes.isEmpty else {
        return ([], CGSize())
    }
    let maxSize = CGSize(width: 300.0, height: 380.0).fittedToWidthOrSmaller(maxWidth)
    if sizes.count == 1 {
        var size = sizes[0].aspectFitted(maxSize)
        size.width = max(size.width, min(170.0, maxSize.width))
        size.height = max(size.height, 74.0)
        let frame = CGRect(origin: CGPoint(), size: CGSize(width: floor(size.width), height: floor(size.height)))
        return ([(frame, [.top, .bottom, .left, .right])], frame.size)
    }
    let (frames, size) = chatMessageBubbleMosaicLayout(maxSize: maxSize, itemSizes: sizes)
    return (frames, size)
}

/// A photo's corners as Telegram rounds them in a bubble (ChatMessageBubbleContentCalclulateImageCorners): those on the
/// bubble's edge as the bubble, 15 pt, or 7 where the bubble meets a neighbour; those inside an album square; the bottom
/// ones square above a caption. A mask, since each corner has its own radius.
private func photoCorners(_ layer: CALayer, position: MosaicItemPosition, captioned: Bool, mergedTop: Bool, mergedBottom: Bool, radius: CGFloat = 15.0) {
    let merged: CGFloat = min(radius, 7.0)
    let topLeft: CGFloat = position.contains(.top) && position.contains(.left) ? radius : 0.0
    let topRight: CGFloat = position.contains(.top) && position.contains(.right) ? (mergedTop ? merged : radius) : 0.0
    let bottomLeft: CGFloat = !captioned && position.contains(.bottom) && position.contains(.left) ? radius : 0.0
    let bottomRight: CGFloat = !captioned && position.contains(.bottom) && position.contains(.right) ? (mergedBottom ? merged : radius) : 0.0
    let rect = CGRect(origin: CGPoint(), size: layer.bounds.size)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRight), radius: topRight)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY), radius: bottomRight)
    path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft), radius: bottomLeft)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + topLeft, y: rect.minY), radius: topLeft)
    path.closeSubpath()
    let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
    mask.frame = rect
    mask.path = path
    layer.mask = mask
    layer.cornerRadius = 0.0
}
private let defaultSpacing: CGFloat = 4.0
private let mergedSpacing: CGFloat = 1.0
/// Margins of bubble-less assistant text.
private let freeTextInset: CGFloat = 16.0
/// How far content moves right to make room for selection checks.
private let selectionInset: CGFloat = 42.0
/// One laid-out block of assistant content, kept so streaming ticks can tell when the row's height changes; `spacing`
/// is the space above it (MarkdownText.spacing), none for the first.
private enum LaidOutBlock {
    case text(start: Int, length: Int, layout: InteractiveTextNodeLayout, spacing: CGFloat)
    case table(start: Int, length: Int, size: CGSize, spacing: CGFloat)

    var start: Int {
        switch self {
        case let .text(start, _, _, _), let .table(start, _, _, _):
            return start
        }
    }

    var length: Int {
        switch self {
        case let .text(_, length, _, _), let .table(_, length, _, _):
            return length
        }
    }

    var spacing: CGFloat {
        switch self {
        case let .text(_, _, _, spacing), let .table(_, _, _, spacing):
            return spacing
        }
    }
}

/// Height of assistant content with `revealed` characters shown; nil shows everything.
private func contentHeight(_ blocks: [LaidOutBlock], revealed: Int?) -> CGFloat {
    var height: CGFloat = 0.0
    var visibleCount = 0
    for block in blocks {
        if let revealed, block.start > 0, revealed <= block.start {
            break
        }
        if visibleCount > 0 {
            height += block.spacing
        }
        visibleCount += 1
        switch block {
        case let .text(start, length, layout, _):
            if let revealed, revealed < start + length {
                height += layout.sizeForCharacterCount(characterCount: max(0, revealed - start)).height
            } else {
                height += layout.size.height
            }
        case let .table(_, _, size, _):
            height += size.height
        }
    }
    return max(1.0, height)
}

final class ChatMessageItemNode: ListViewItemNode {
    private let bubbleNode = GradientBubbleNode()
    private let dateNode = TextNode()
    /// An answer's run, on the left of its footer: "worked for 38s", with the time on the right.
    private let runNode = TextNode()
    /// Telegram's status after the time: the turning clock while on its way, two checks once the model has it.
    private let clockFrameNode = ASImageNode()
    private let clockMinNode = ASImageNode()
    private let checkSentNode = ASImageNode()
    private let checkReadNode = ASImageNode()
    /// ChatMessageDeliveryFailedNode: the red badge beside a refused message.
    private let failedNode = ASImageNode()
    private var statusImagesKey: String?
    private var textNodes: [InteractiveTextNode] = []
    /// Telegram's LinkHighlightingNode behind each text node's matched words.
    private var searchHighlightNodes: [LinkHighlightingNode] = []
    /// A few quoted words' marks (docs/quotes.md), one node per text node that has them.
    private var inlineQuoteNodes: [LinkHighlightingNode] = []
    private var tableNodes: [ChatTableNode] = []
    private var imageNodes: [ChatMediaImageNode] = []
    /// The attachment each visible image node shows.
    private var imageAttachmentIds: [Int] = []
    /// The photo open in the media viewer, hidden here meanwhile.
    private var hiddenAttachmentId: Int?
    private var fileNodes: [FileAttachmentNode] = []
    private let toolBackgroundNode = ASDisplayNode()
    private let toolTitleNode = TextNode()
    private let toolTextNode = TextNode()
    /// Under an expanded card whose text was cut: its whole text, in a viewer.
    private let toolShowAllNode = TextNode()
    private var toolShowAllFrame: CGRect?
    /// A subagent's card: its name and task as the quote over a Telegram reply, then what it said.
    private let subagentQuoteNode = ASDisplayNode()
    private let subagentBarNode = ASDisplayNode()
    private let subagentTaskNode = TextNode()
    private let subagentMetaNode = TextNode()
    private let subagentArrowNode = ASImageNode()
    private var subagentAnswerNode: InteractiveTextNode?
    /// A time that ticks (a tool running, a subagent working, a compaction) or stays (how long one took).
    private let timerNode = ImmediateTextNode()
    private var liveTimer: SwiftSignalKit.Timer?
    private var timerTick: (() -> Void)?
    /// The τ in a compaction's pill.
    private var serviceTauNode: ChatWaitingNode?
    /// Beside the waiting τ while the server retries: when it asks again, and why.
    private var waitingLabelNode: ImmediateTextNode?
    /// The error card's Retry button, for taps.
    private var retryButtonFrame: CGRect?
    /// As in ChatMessageBubbleItemNode: the long-press source wraps the extractable container, whose content node the
    /// context menu lifts out of the list and puts back.
    let containerNode = ContextControllerSourceNode()
    let contextSourceNode = ContextExtractedContentContainingNode()
    private var contentNode: ContextExtractedContentNode {
        return self.contextSourceNode.contentNode
    }
    private var selectionNode: ChatMessageSelectionNode?

    private(set) var item: ChatMessageItem? {
        didSet {
            // Only an answer's footer has it; that layout shows it again.
            self.runNode.isHidden = true
        }
    }
    private var laidOutBlocks: [LaidOutBlock] = []
    private var revealController: TextRevealController? {
        didSet {
            if (oldValue == nil) != (self.revealController == nil) {
                self.updateSlotMask()
            }
        }
    }
    private var revealLink: SharedDisplayLinkDriver.Link?
    /// The visible message content in node coordinates, for context menu previews.
    private(set) var contentFrame: CGRect = .zero

    var messageId: Int? {
        return self.item?.message.id
    }

    init() {
        super.init(layerBacked: false, rotated: true)

        // Items of an inverted list are rotated back upright, as Telegram's chat items are.
        self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        self.dateNode.isUserInteractionEnabled = false
        self.toolBackgroundNode.isLayerBacked = true
        self.toolBackgroundNode.cornerRadius = 14.0

        self.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.contextSourceNode)
        self.containerNode.targetNodeForActivationProgress = self.contextSourceNode.contentNode
        self.contentNode.addSubnode(self.bubbleNode)
        self.contentNode.addSubnode(self.toolBackgroundNode)
        self.contentNode.addSubnode(self.toolTitleNode)
        self.contentNode.addSubnode(self.toolTextNode)
        self.toolShowAllNode.isHidden = true
        self.contentNode.addSubnode(self.toolShowAllNode)
        self.subagentQuoteNode.isLayerBacked = true
        self.subagentQuoteNode.cornerRadius = 8.0
        self.subagentQuoteNode.clipsToBounds = true
        self.subagentBarNode.isLayerBacked = true
        self.subagentQuoteNode.addSubnode(self.subagentBarNode)
        self.subagentArrowNode.isLayerBacked = true
        self.subagentArrowNode.displaysAsynchronously = false
        for node in [self.subagentQuoteNode, self.subagentTaskNode, self.subagentMetaNode, self.subagentArrowNode, self.timerNode] {
            node.isHidden = true
            self.contentNode.addSubnode(node)
        }
        self.timerNode.displaysAsynchronously = false
        self.timerNode.isUserInteractionEnabled = false
        self.contentNode.addSubnode(self.dateNode)
        self.runNode.isHidden = true
        self.contentNode.addSubnode(self.runNode)
        for node in [self.clockFrameNode, self.clockMinNode, self.checkSentNode, self.checkReadNode] {
            node.isLayerBacked = true
            node.displaysAsynchronously = false
            node.isHidden = true
            self.contentNode.addSubnode(node)
        }
        self.failedNode.displaysAsynchronously = false
        self.failedNode.isHidden = true
        self.failedNode.isAccessibilityElement = true
        self.failedNode.accessibilityIdentifier = "deliveryFailed"
        self.failedNode.accessibilityLabel = "Not sent"
        self.failedNode.accessibilityTraits = .button
        self.addSubnode(self.failedNode)

        self.containerNode.shouldBegin = { [weak self] point in
            // Over text selected in place, a long press selects a word instead, as in a text view.
            guard let self, let item = self.item, item.selection == nil, !item.isStreaming, self.inlineSelection == nil, self.link(at: point) == nil else {
                return false
            }
            return self.contentFrame.insetBy(dx: -4.0, dy: -4.0).contains(point)
        }
        self.containerNode.activated = { [weak self] gesture, _ in
            guard let self, let item = self.item else {
                return
            }
            item.interaction.openContextMenu(item.message.id, self, gesture)
        }
        self.contextSourceNode.isExtractedToContextPreviewUpdated = { [weak self] value in
            self?.updateIsExtractedToContextPreview(value)
        }
    }

    /// When the touch being recognized began: a press held as long as a long press is not a tap.
    private var touchBegan: CFTimeInterval = 0.0

    override func didLoad() {
        super.didLoad()
        // Telegram's message recognizer (ChatMessageBubbleItemNode): a tap on what acts on a tap (code, a photo, a
        // file) acts at once; one on a message's text waits to see whether a second follows, which selects.
        let recognizer = TapLongTapOrDoubleTapGestureRecognizer(target: self, action: #selector(self.tapLongTapOrDoubleTapGesture(_:)))
        recognizer.tapActionAtPoint = { [weak self, weak recognizer] point in
            guard let self else {
                return .fail
            }
            self.touchBegan = CACurrentMediaTime()
            // A link acts on a tap and, held, opens its menu (Telegram's `.url` action and long tap); the message's own
            // menu does not begin there.
            if self.link(at: point) != nil {
                recognizer?.longTap = { [weak self] point, recognizer in
                    guard let self, let item = self.item, let link = self.link(at: point) else {
                        return
                    }
                    self.updateLinkHighlight(nil)
                    item.interaction.openLinkMenu(link.url, item.message.id, recognizer)
                }
                return .waitForSingleTap
            }
            recognizer?.longTap = nil
            return self.selectableText(at: point) != nil ? .waitForDoubleTap : .keepWithSingleTap
        }
        recognizer.highlight = { [weak self] point in
            self?.updateLinkHighlight(point)
        }
        recognizer.cancelsTouchesInView = false
        self.view.addGestureRecognizer(recognizer)
    }

    /// The link under a point of the row's text, from Markdown or written out: its address, and where it is.
    private func link(at point: CGPoint) -> (url: String, textNode: InteractiveTextNode, index: Int)? {
        guard let item = self.item, item.selection == nil else {
            return nil
        }
        for textNode in self.textNodes where textNode.supernode != nil && !textNode.isHidden {
            let local = self.view.convert(point, to: textNode.view)
            guard textNode.bounds.contains(local), let (index, attributes) = textNode.attributesAtPoint(local, orNearest: false), let url = attributes[MarkdownText.urlKey] as? String else {
                continue
            }
            return (url, textNode, index)
        }
        return nil
    }

    private var linkHighlightNode: LinkHighlightingNode?

    /// Telegram's pressed link: its rects in the link highlight color, under the text, while the finger is on it.
    private func updateLinkHighlight(_ point: CGPoint?) {
        guard let point, let item = self.item, let link = self.link(at: point), let rects = link.textNode.attributeRects(name: MarkdownText.urlKey.rawValue, at: link.index), !rects.isEmpty else {
            if let node = self.linkHighlightNode {
                self.linkHighlightNode = nil
                node.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18, removeOnCompletion: false, completion: { [weak node] _ in
                    node?.removeFromSupernode()
                })
            }
            return
        }
        let message = item.theme.presentationTheme.chat.message
        let color = item.message.role == .user ? message.outgoing.linkHighlightColor : message.incoming.linkHighlightColor
        let node: LinkHighlightingNode
        if let current = self.linkHighlightNode {
            node = current
        } else {
            node = LinkHighlightingNode(color: color)
            self.linkHighlightNode = node
        }
        if node.supernode !== link.textNode.supernode {
            link.textNode.supernode?.insertSubnode(node, belowSubnode: link.textNode)
        }
        node.frame = link.textNode.frame
        node.updateRects(rects, color: color)
    }

    @objc private func tapLongTapOrDoubleTapGesture(_ recognizer: TapLongTapOrDoubleTapGestureRecognizer) {
        guard recognizer.state == .ended, let (gesture, location) = recognizer.lastRecognizedGestureAndLocation else {
            return
        }
        switch gesture {
        case .tap:
            if let item = self.item, let link = self.link(at: location) {
                item.interaction.openURL(link.url)
                return
            }
            // Held long enough for the message's menu: that was the press, not a tap.
            if CACurrentMediaTime() - self.touchBegan < 0.5 {
                self.handleTap(at: location)
            }
        case .doubleTap:
            if let (textNode, index) = self.selectableText(at: location) {
                self.beginInlineSelection(textNode: textNode, at: index)
            }
        default:
            break
        }
    }

    private func handleTap(at location: CGPoint) {
        guard let item = self.item, item.selection == nil else {
            return
        }
        if !self.failedNode.isHidden, self.failedNode.frame.insetBy(dx: -8.0, dy: -8.0).contains(location) {
            // As ChatMessageDeliveryFailedNode's tap: the message's menu, with Resend.
            item.interaction.openContextMenu(item.message.id, self, nil)
            return
        }
        let point = self.view.convert(location, to: self.contentNode.view)
        if let frame = self.toolShowAllFrame, frame.contains(point) {
            item.interaction.openToolText(item.message)
            return
        }
        if let frame = self.retryButtonFrame, frame.contains(point) {
            item.interaction.openTool(item.message)
            return
        }
        for (index, id) in self.imageAttachmentIds.enumerated() where index < self.imageNodes.count {
            if self.imageNodes[index].frame.contains(point) {
                item.interaction.openImage(id)
                return
            }
        }
        for node in self.fileNodes where !node.isHidden && node.frame.contains(point) {
            if let file = node.file {
                item.interaction.openFile(file, node.status)
            }
            return
        }
        // As ChatMessageTextBubbleContentNode's tap actions: a code block or inline code copies.
        for textNode in self.textNodes {
            let local = self.contentNode.view.convert(point, to: textNode.view)
            guard textNode.bounds.contains(local), let (index, attributes) = textNode.attributesAtPoint(local, orNearest: false) else {
                continue
            }
            // All of the code (the longest range of its attribute: highlighting splits it into runs), as written: its
            // tabs and a diff's marks as they were.
            var key: NSAttributedString.Key?
            if attributes[MarkdownText.inlineCodeKey] != nil {
                key = MarkdownText.inlineCodeKey
            } else if let quote = attributes[MarkdownText.blockQuoteKey] as? TextNodeBlockQuoteData, case .code = quote.kind {
                key = MarkdownText.blockQuoteKey
            }
            if let key, let string = textNode.cachedLayout?.attributedString, index < string.length {
                var range = NSRange()
                guard string.attribute(key, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: string.length)) != nil, range.length > 0 else {
                    continue
                }
                let text = MarkdownText.copiedText(string.attributedSubstring(from: range))
                UIPasteboard.general.string = text
                item.interaction.copied(text)
                return
            }
        }
    }

    /// Telegram's text selection in a message lifted into the context menu: a second long press on the text selects
    /// it, with knobs and a Copy / Quote / Look Up menu, while the menu's actions step aside
    /// (ChatMessageTextBubbleContentNode.updateIsExtractedToContextPreview).
    private var previewSelection: (node: TextSelectionNode, surface: MessageTextSurface)?

    private func updateIsExtractedToContextPreview(_ value: Bool) {
        if value {
            self.endInlineSelection(animated: false)
            guard self.previewSelection == nil, let item = self.item, item.message.tool == nil else {
                return
            }
            self.previewSelection = self.addTextSelectionNode(item: item, updateIsActive: { [weak self] value in
                self?.contextSourceNode.updateDistractionFreeMode?(value)
            })
        } else if let selection = self.previewSelection {
            self.previewSelection = nil
            Self.removeTextSelectionNode(selection, animated: true)
        }
    }

    /// The parts of the message a selection runs through, in order (MessageTextSurface): its text nodes and tables,
    /// not its links' cards under it.
    private func selectionParts() -> [MessageTextSurface.Part] {
        guard let item = self.item else {
            return []
        }
        if self.laidOutBlocks.isEmpty {
            return self.textNodes.filter { $0.supernode != nil && !$0.isHidden }.map { .text($0) }
        }
        let textCount = self.laidOutBlocks.filter { if case .text = $0 { return true } else { return false } }.count
        let ownTextCount = textCount - (item.isStreaming ? 0 : min(textCount, item.references.count))
        var parts: [MessageTextSurface.Part] = []
        var textCursor = 0
        var tableCursor = 0
        for block in self.laidOutBlocks {
            switch block {
            case .text:
                if textCursor < ownTextCount, textCursor < self.textNodes.count, self.textNodes[textCursor].supernode != nil {
                    parts.append(.text(self.textNodes[textCursor]))
                }
                textCursor += 1
            case .table:
                if tableCursor < self.tableNodes.count, let text = self.tableNodes[tableCursor].plainText {
                    parts.append(.table(self.tableNodes[tableCursor], text))
                }
                tableCursor += 1
            }
        }
        return parts
    }

    /// Telegram's selection over the message's text, all of it (MessageTextSurface), with Copy / Quote / Look Up over
    /// what it selects.
    private func addTextSelectionNode(item: ChatMessageItem, updateIsActive: @escaping (Bool) -> Void) -> (node: TextSelectionNode, surface: MessageTextSurface) {
        let theme = item.theme.presentationTheme
        let colors = item.message.role == .user ? theme.chat.message.outgoing : theme.chat.message.incoming
        let surface = MessageTextSurface()
        surface.frame = self.contentNode.bounds
        self.contentNode.addSubnode(surface)
        surface.update(parts: self.selectionParts())
        let selectionNode = TextSelectionNode(theme: TextSelectionTheme(selection: colors.textSelectionColor, knob: colors.textSelectionKnobColor, isDark: theme.overallDarkAppearance), strings: item.theme.presentationStrings, textNodeOrView: .node(surface), updateIsActive: updateIsActive, present: { [weak self] controller, arguments in
            self?.item?.interaction.presentInGlobalOverlay(controller, arguments)
        }, rootView: { [weak self] in
            return self?.item?.interaction.rootView()
        }, performAction: { [weak self] text, action in
            self?.performTextSelectionAction(text: text, action: action)
        })
        selectionNode.enableQuote = true
        selectionNode.enableTranslate = false
        // The chat scrolls under a knob itself (ChatControllerNode), the list being no scroll view.
        selectionNode.enableAutomaticScrolling = false
        // A press begins a selection on text, not between it.
        selectionNode.canBeginSelection = { [weak surface] point in
            return surface?.attributesAtPoint(point, orNearest: false) != nil
        }
        selectionNode.menuVisibleRect = { [weak self] in
            return self?.item?.interaction.selectionMenuArea()
        }
        selectionNode.knobMoved = { [weak self] point in
            guard let self else {
                return
            }
            self.item?.interaction.selectionKnobMoved(self, point)
        }
        selectionNode.frame = surface.frame
        selectionNode.highlightAreaNode.frame = surface.frame
        // Under the lowest of the text (and of the scrollers code sits in), over the bubble.
        let textual = Set(surface.parts.map { part -> ObjectIdentifier in
            var node = part.node
            while let supernode = node.supernode, supernode !== self.contentNode {
                node = supernode
            }
            return ObjectIdentifier(node)
        })
        if let lowest = self.contentNode.subnodes?.first(where: { textual.contains(ObjectIdentifier($0)) }) {
            self.contentNode.insertSubnode(selectionNode.highlightAreaNode, belowSubnode: lowest)
        } else {
            self.contentNode.insertSubnode(selectionNode.highlightAreaNode, belowSubnode: self.dateNode)
        }
        self.contentNode.addSubnode(selectionNode)
        return (selectionNode, surface)
    }

    private static func removeTextSelectionNode(_ selection: (node: TextSelectionNode, surface: MessageTextSurface), animated: Bool) {
        let node = selection.node
        selection.surface.removeFromSupernode()
        guard animated else {
            node.highlightAreaNode.removeFromSupernode()
            node.removeFromSupernode()
            return
        }
        node.highlightAreaNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
        node.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak node] _ in
            node?.highlightAreaNode.removeFromSupernode()
            node?.removeFromSupernode()
        })
    }

    /// Text selected in place by a double tap, as a text view selects a word: the selection, the message's text it is
    /// over, and that text when it began, which a layout of other text ends it for.
    private var inlineSelection: (node: TextSelectionNode, surface: MessageTextSurface, text: NSAttributedString)?

    /// The text node and character under a point of the row, when a double tap there selects: a message's own text
    /// (the user's or the answer's, done), not a tool's card, and not code, which a tap copies.
    private func selectableText(at point: CGPoint) -> (InteractiveTextNode, Int)? {
        guard let item = self.item, item.selection == nil, !item.isStreaming, item.message.tool == nil, item.message.role == .assistant || item.message.role == .user else {
            return nil
        }
        for textNode in self.textNodes where textNode.supernode === self.contentNode {
            let local = self.view.convert(point, to: textNode.view)
            guard textNode.bounds.contains(local), let (index, attributes) = textNode.attributesAtPoint(local, orNearest: false) else {
                continue
            }
            if attributes[MarkdownText.inlineCodeKey] != nil {
                return nil
            }
            if let quote = attributes[MarkdownText.blockQuoteKey] as? TextNodeBlockQuoteData, case .code = quote.kind {
                return nil
            }
            return (textNode, index)
        }
        return nil
    }

    /// Selects the word at `index` of `textNode`, with its knobs and menu, where the text is; the knobs go on through
    /// the rest of the message.
    private func beginInlineSelection(textNode: InteractiveTextNode, at index: Int) {
        guard let item = self.item else {
            return
        }
        self.endInlineSelection(animated: false)
        let selection = self.addTextSelectionNode(item: item, updateIsActive: { [weak self] active in
            if !active {
                self?.endInlineSelection(animated: true)
            }
        })
        let text = selection.surface.text
        guard let surfaceIndex = selection.surface.index(of: textNode, index), surfaceIndex < text.length else {
            Self.removeTextSelectionNode(selection, animated: false)
            return
        }
        // A tap elsewhere ends it, as one outside a text view's selection does; a drag scrolls the chat under it
        // (ChatControllerNode's tap, not the menu's touch).
        self.inlineSelection = (selection.node, selection.surface, text)
        item.interaction.beganInlineSelection(self)
        selection.node.setSelection(range: wordRange(in: text.string as NSString, at: surfaceIndex), displayMenu: true)
    }

    func endInlineSelection(animated: Bool) {
        guard let selection = self.inlineSelection else {
            return
        }
        self.inlineSelection = nil
        selection.node.cancelSelection()
        Self.removeTextSelectionNode((selection.node, selection.surface), animated: animated)
    }

    /// While the list scrolls under a selection made in place: its menu steps aside, and comes back where it is now.
    func setInlineSelectionMenuHidden(_ hidden: Bool) {
        guard let selection = self.inlineSelection else {
            return
        }
        if hidden {
            selection.node.hideMenu()
        } else {
            selection.node.showMenu()
        }
    }

    /// The knob being dragged follows the finger again, after the list scrolled under it.
    func updateInlineSelectionKnob() {
        self.inlineSelection?.node.updateMovingKnob()
    }

    /// Whether a point of the row (its own coordinates) is on the selection made in place, which takes its own taps.
    func inlineSelectionContains(_ point: CGPoint) -> Bool {
        guard let node = self.inlineSelection?.node else {
            return false
        }
        return node.hitTest(self.view.convert(point, to: node.view), with: nil) != nil
    }

    /// The message's text on screen, in window coordinates: how far the list may scroll for a knob.
    func selectableFrameInWindow() -> CGRect? {
        guard let surface = self.inlineSelection?.surface, let first = surface.parts.first, let last = surface.parts.last else {
            return nil
        }
        let top = first.node.view.convert(first.node.bounds, to: nil)
        let bottom = last.node.view.convert(last.node.bounds, to: nil)
        return top.union(bottom)
    }

    /// After a layout: the selection follows its text, or ends when the text is not what it selected in.
    private func layoutInlineSelection() {
        if let selection = self.previewSelection {
            selection.surface.frame = self.contentNode.bounds
            selection.node.frame = selection.surface.frame
            selection.node.highlightAreaNode.frame = selection.surface.frame
            selection.surface.update(parts: self.selectionParts())
            selection.node.updateLayout()
        }
        guard let selection = self.inlineSelection else {
            return
        }
        let parts = self.selectionParts()
        guard let item = self.item, item.selection == nil, !item.isStreaming, MessageTextSurface.text(of: parts).0.isEqual(to: selection.text) else {
            self.endInlineSelection(animated: false)
            return
        }
        selection.surface.update(parts: parts)
        selection.surface.frame = self.contentNode.bounds
        selection.node.frame = selection.surface.frame
        selection.node.highlightAreaNode.frame = selection.surface.frame
        selection.node.updateLayout()
    }

    private func performTextSelectionAction(text: NSAttributedString, action: TextSelectionAction) {
        // Formulas copy as their LaTeX, typeset characters as written, kept indentation as plain spaces.
        let string = MarkdownText.copiedText(text)
        switch action {
        case .copy:
            UIPasteboard.general.string = string
        case .share:
            let controller = UIActivityViewController(activityItems: [string], applicationActivities: nil)
            self.view.window?.rootViewController?.present(controller, animated: true)
        case .lookup:
            let controller = UIReferenceLibraryViewController(term: string)
            self.view.window?.rootViewController?.present(controller, animated: true)
        case .quote:
            // Into the field, where the cursor is (docs/quotes.md); the lifted message's menu goes first.
            if self.inlineSelection == nil {
                self.contextSourceNode.requestDismiss?()
            }
            self.item?.interaction.quote(string)
            return
        default:
            break
        }
        if self.inlineSelection != nil {
            // Selected in place: nothing to close; a copy says so, as a tap on code does.
            if case .copy = action {
                self.item?.interaction.copied(string)
            }
            return
        }
        self.contextSourceNode.requestDismiss?()
    }

    /// At least `count` photo nodes; those past what a row shows it hides.
    private func ensureImageNodes(_ count: Int) {
        while self.imageNodes.count < count {
            let imageNode = ChatMediaImageNode()
            self.imageNodes.append(imageNode)
            self.contentNode.addSubnode(imageNode)
        }
    }

    /// The node showing a photo, for the media viewer's transitions.
    func imageNode(attachmentId: Int) -> ASImageNode? {
        guard let index = self.imageAttachmentIds.firstIndex(of: attachmentId), index < self.imageNodes.count else {
            return nil
        }
        return self.imageNodes[index]
    }

    /// Hides the photo the media viewer shows, as Telegram hides a message's media while its gallery is open.
    func setHiddenAttachment(_ id: Int?) {
        self.hiddenAttachmentId = id
        for (index, attachmentId) in self.imageAttachmentIds.enumerated() where index < self.imageNodes.count {
            self.imageNodes[index].alpha = attachmentId == id ? 0.0 : 1.0
        }
    }

    /// Sizes the context containers to the row and marks the message's extent for the context menu.
    private func layoutContainers(size: CGSize) {
        let bounds = CGRect(origin: CGPoint(), size: size)
        self.containerNode.frame = bounds
        self.contextSourceNode.frame = bounds
        self.contentNode.frame = bounds
        self.contextSourceNode.contentRect = self.contentFrame
        self.containerNode.targetNodeForActivationProgressContentRect = self.contentFrame
        // Every row's apply ends here, its text laid out: search's marks and a selection follow the text.
        self.updateSearchHighlight()
        self.updateInlineQuoteMarks()
        self.layoutInlineSelection()
    }

    override func layoutForParams(_ params: ListViewItemLayoutParams, item: ListViewItem, neighbors: ListViewItemNeighbors) {
        guard let item = item as? ChatMessageItem else {
            return
        }
        let (layout, apply) = self.asyncLayout()(item, params, neighbors)
        apply(.None)
        self.contentSize = layout.contentSize
        self.insets = layout.insets
    }

    /// A row is drawn only in the room the list has made for it, while the list animates its height (coming in,
    /// growing, going) and while its text is revealed, and its top stays with that room's top: it comes in from under
    /// the row below (the input panel, at the end) as the rows above move up, and never over them. Otherwise a new row
    /// was drawn whole at once over the rows still moving away, and a revealed line below the row's height until the
    /// row was laid out again for it: a thinking row whose text went on while the answer had begun under it was drawn
    /// over the answer. The list itself keeps a growing row's top in place this way (ListView's update of a rotated
    /// node); this does it for a new one too. The sender's own messages rise from the input field, as Telegram's.
    private var slotMask: CALayer?

    private var clipsToSlot: Bool {
        if case .user = self.item?.message.role {
            return false
        }
        return true
    }

    override var apparentHeight: CGFloat {
        didSet {
            self.updateSlotMask()
        }
    }

    private func updateSlotMask() {
        let height = self.bounds.height
        guard self.clipsToSlot, self.apparentHeight < height - 0.5 || self.revealController != nil, let superlayer = self.layer.superlayer else {
            if self.slotMask != nil {
                self.layer.mask = nil
                self.slotMask = nil
            }
            return
        }
        let mask: CALayer
        if let current = self.slotMask {
            mask = current
        } else {
            mask = CALayer()
            mask.backgroundColor = UIColor.black.cgColor
            self.slotMask = mask
            self.layer.mask = mask
        }
        // The room is the apparent frame, in the list's coordinates; this row's own are rotated and offset.
        let slot = self.layer.convert(self.apparentFrame, from: superlayer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: -1000.0, y: slot.minY, width: self.bounds.width + 2000.0, height: max(0.0, slot.height))
        CATransaction.commit()
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        super.animateInsertion(currentTimestamp, duration: duration, options: options)
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        if self.clipsToSlot {
            // Its top with the room's top, down from it by what the room still lacks, as the room grows in.
            self.transitionOffset = self.apparentHeight - self.bounds.height
            self.addTransitionOffsetAnimation(0.0, duration: duration, beginAt: currentTimestamp)
            self.updateSlotMask()
        }
        if case .user = self.item?.message.role {
            if let source = self.item?.riseFrom, let superview = self.view.superview {
                // From the queue panel to its place in the transcript.
                let bubble = self.view.convert(self.contentFrame, to: nil)
                let from = superview.convert(CGPoint(x: source.midX, y: source.midY), from: nil)
                let to = superview.convert(CGPoint(x: bubble.midX, y: bubble.midY), from: nil)
                self.layer.animatePosition(from: CGPoint(x: 0.0, y: from.y - to.y), to: CGPoint(), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            } else {
                // A sent message rises from the input field, as in Telegram.
                self.layer.animatePosition(from: CGPoint(x: 0.0, y: -40.0), to: CGPoint(), duration: duration, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            }
        }
    }

    override func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        super.animateRemoved(currentTimestamp, duration: duration)
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
    }

    override func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        super.updateAbsoluteRect(rect, within: containerSize)
        // The list moves a row here after each step of its animations, the offset included.
        self.updateSlotMask()
        // The list is rotated, so this row's top on screen is the container height minus its maxY.
        let visualTop = containerSize.height - rect.maxY
        self.bubbleNode.updateAbsolutePosition(visualTop: visualTop, containerSize: containerSize)
    }

    func asyncLayout() -> (_ item: ChatMessageItem, _ params: ListViewItemLayoutParams, _ neighbors: ListViewItemNeighbors) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeDateLayout = TextNode.asyncLayout(self.dateNode)
        let makeRunLayout = TextNode.asyncLayout(self.runNode)
        let makeToolTitleLayout = TextNode.asyncLayout(self.toolTitleNode)
        let makeToolTextLayout = TextNode.asyncLayout(self.toolTextNode)
        let makeToolShowAllLayout = TextNode.asyncLayout(self.toolShowAllNode)
        let makeSubagentTaskLayout = TextNode.asyncLayout(self.subagentTaskNode)
        let makeSubagentMetaLayout = TextNode.asyncLayout(self.subagentMetaNode)
        let makeSubagentAnswerLayout = InteractiveTextNode.asyncLayout(self.subagentAnswerNode)
        let existingTextNodes = self.textNodes
        let existingTableNodes = self.tableNodes
        // Taken here, on the main thread, with the cells each has now.
        let existingTableLayouts = existingTableNodes.map { ChatTableNode.asyncLayout($0) }
        let currentRevealCount = self.revealController.map { Int($0.revealedCount) }

        let layoutImpl: (ChatMessageItem, ListViewItemLayoutParams, ListViewItemNeighbors) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) = { [weak self] item, params, neighbors in
            let theme = item.theme.chat
            let message = item.message
            let isSelecting = item.selection != nil
            let leftShift: CGFloat = isSelecting ? selectionInset : 0.0
            let contentWidth = params.width - params.leftInset - params.rightInset

            // In the inverted list `previous` is the newer row below, `next` the older row above.
            let above = neighbors.next?.base(ChatHistoryNeighbor.self)
            let below = neighbors.previous?.base(ChatHistoryNeighbor.self)

            switch message.role {
            case .user:
                let mergedTop = above == .user
                let mergedBottom = below == .user
                let bubbleNeighbors: MessageBubbleImageNeighbors
                switch (mergedTop, mergedBottom) {
                case (true, true):
                    bubbleNeighbors = .both
                case (true, false):
                    bubbleNeighbors = .bottom
                case (false, true):
                    bubbleNeighbors = .top(side: false)
                case (false, false):
                    bubbleNeighbors = .none
                }

                // Telegram's ChatMessageItemWidthFill: phones leave 36 pt beside a bubble.
                let fillWidth = contentWidth <= 500.0 ? contentWidth - 36.0 : floor(contentWidth * 0.85)
                let maxContentWidth = fillWidth - bubbleEdgeInset * 2.0 - bubbleTailInset
                // Photos as Telegram's media bubbles: one fitted into 300 by 380 pt, several as an album
                // (chatMessageBubbleMosaicLayout, as ChatMessageBubbleItemNode lays out a grouped message), the
                // caption wrapping to their width. Files are rows above the text.
                var photoSizes: [CGSize] = []
                var files: [FileAttachment] = []
                for attachment in message.attachments {
                    switch attachment.kind {
                    case let .image(image):
                        photoSizes.append(image.size.width > 0.0 && image.size.height > 0.0 ? image.size : CGSize(width: 256.0, height: 256.0))
                    case let .remote(remote):
                        photoSizes.append(remote.pixelSize ?? CGSize(width: 256.0, height: 256.0))
                    case let .file(file):
                        files.append(file)
                    }
                }
                let photos = photoMosaic(photoSizes, maxWidth: maxContentWidth - mediaInset * 2.0)
                let imageSizes = photos.frames.map(\.0.size)
                let maxTextWidth = photoSizes.isEmpty ? maxContentWidth - textInsets.left - textInsets.right : photos.size.width + mediaInset * 2.0 - textInsets.left - textInsets.right

                var style = MarkdownStyle(fontSize: item.theme.fontSize, textColor: theme.outgoing.primaryTextColor, linkColor: theme.outgoing.linkTextColor, accentColor: theme.outgoing.primaryTextColor)
                style.math = false
                let textNode = existingTextNodes.first
                let hasText = !message.text.isEmpty
                let (textLayout, textApply) = InteractiveTextNode.asyncLayout(textNode)(InteractiveTextNodeLayoutArguments(attributedString: withReferences(MarkdownText.render(message.text, style: style), item.references, style: style), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude)))
                let (dateLayout, dateApply) = makeDateLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: messageTimeString(message.date), font: dateFont(item.theme), textColor: theme.outgoing.secondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 200.0, height: 40.0)))
                let fileLayouts = files.map { FileAttachmentNode.measure($0, fontSize: item.theme.fontSize, maxWidth: maxTextWidth) }

                // The time and status share the last line when they fit, as ChatMessageDateAndStatusNode's trailing
                // layout does. Its status takes 5 pt plus 13 pt after the time; a refused message has none.
                let isFailed: Bool
                if case .failed = message.delivery {
                    isFailed = true
                } else {
                    isFailed = false
                }
                let statusWidth: CGFloat = isFailed ? 0.0 : 18.0
                let dateAreaWidth = dateLayout.size.width + statusWidth
                let dateSpacing: CGFloat = 6.0
                var textAreaSize = hasText ? textLayout.size : CGSize()
                let trailingWidth = (hasText ? textLayout.trailingLineWidth : 0.0) + dateSpacing + dateAreaWidth
                if hasText && trailingWidth <= maxTextWidth {
                    textAreaSize.width = max(textAreaSize.width, trailingWidth)
                } else {
                    textAreaSize.width = max(textAreaSize.width, dateAreaWidth)
                    textAreaSize.height += dateLayout.size.height
                }
                for fileSize in fileLayouts {
                    textAreaSize.width = max(textAreaSize.width, fileSize.width)
                    textAreaSize.height += fileSize.height + 6.0
                }

                let mediaHeight: CGFloat = imageSizes.isEmpty ? 0.0 : photos.size.height + mediaInset * 2.0
                let mediaWidth: CGFloat = imageSizes.isEmpty ? 0.0 : photos.size.width + mediaInset * 2.0
                // Captioned, the photos' bottom corners meet the text (Telegram's contentMergedCornerRadius); a corner by
                // a neighbouring bubble is the merged radius, as the bubble's own.
                let captioned = hasText || !files.isEmpty

                let bubbleSize = CGSize(
                    width: max(bubbleMinimumSize.width, max(mediaWidth, textAreaSize.width + textInsets.left + textInsets.right)) + bubbleTailInset,
                    height: max(bubbleMinimumSize.height, mediaHeight + (imageSizes.isEmpty ? textInsets.top : 0.0) + textAreaSize.height + textInsets.bottom + (imageSizes.isEmpty ? 0.0 : 4.0))
                )
                let insets = UIEdgeInsets(top: mergedTop ? mergedSpacing : defaultSpacing, left: 0.0, bottom: mergedBottom ? mergedSpacing : defaultSpacing, right: 0.0)
                let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: bubbleSize.height), insets: insets)
                let mask = BubbleImageCache.shared.image(incoming: false, neighbors: bubbleNeighbors, color: .black)
                let fillColors = theme.outgoing.fillColors
                let isSolid = fillColors.allSatisfy { $0.argb == fillColors[0].argb }
                let solidImage = isSolid ? BubbleImageCache.shared.image(incoming: false, neighbors: bubbleNeighbors, color: fillColors[0]) : nil

                return (layout, { animation in
                    guard let self else {
                        return
                    }
                    self.item = item
                    self.stopReveal()
                    self.laidOutBlocks = []
                    self.setToolVisible(false)
                    self.dateNode.isHidden = false
                    self.bubbleNode.isHidden = false

                    // ChatMessageBubbleItemNode: a refused message moves 24 pt left for its red badge.
                    let failedInset: CGFloat = isFailed ? 24.0 : 0.0
                    let backgroundFrame = CGRect(origin: CGPoint(x: params.width - params.rightInset - bubbleEdgeInset - bubbleSize.width - failedInset, y: 0.0), size: bubbleSize)
                    self.contentFrame = backgroundFrame
                    if let solidImage {
                        self.bubbleNode.update(solid: solidImage)
                    } else {
                        self.bubbleNode.update(mask: mask, colors: fillColors)
                    }
                    animation.animator.updateFrame(layer: self.bubbleNode.layer, frame: backgroundFrame.insetBy(dx: -1.0, dy: -1.0), completion: nil)

                    // Photos at the top, inset 2 pt as Telegram's media bubbles.
                    self.ensureImageNodes(imageSizes.count)
                    var imageIndex = 0
                    self.imageAttachmentIds = []
                    for attachment in message.attachments {
                        if attachment.isPhoto {
                            let imageNode = self.imageNodes[imageIndex]
                            let (frame, position) = photos.frames[imageIndex]
                            imageNode.setAttachment(attachment.kind, placeholderColor: item.theme.presentationTheme.chat.message.outgoing.mediaPlaceholderColor)
                            imageNode.isHidden = false
                            imageNode.alpha = attachment.id == self.hiddenAttachmentId ? 0.0 : 1.0
                            self.imageAttachmentIds.append(attachment.id)
                            imageNode.frame = frame.offsetBy(dx: backgroundFrame.minX + mediaInset, dy: mediaInset)
                            photoCorners(imageNode.layer, position: position, captioned: captioned, mergedTop: mergedTop, mergedBottom: mergedBottom)
                            imageIndex += 1
                        }
                    }
                    for index in imageIndex ..< self.imageNodes.count {
                        self.imageNodes[index].isHidden = true
                    }
                    var contentY = imageSizes.isEmpty ? textInsets.top : mediaHeight + 4.0

                    while self.fileNodes.count < files.count {
                        let fileNode = FileAttachmentNode()
                        self.fileNodes.append(fileNode)
                        self.contentNode.addSubnode(fileNode)
                    }
                    for (index, file) in files.enumerated() {
                        let fileNode = self.fileNodes[index]
                        fileNode.isHidden = false
                        let size = fileLayouts[index]
                        fileNode.update(file: file, incoming: false, theme: item.theme, status: item.interaction.fileStatus(file), width: size.width)
                        fileNode.frame = CGRect(origin: CGPoint(x: backgroundFrame.minX + textInsets.left, y: contentY), size: size)
                        contentY += size.height + 6.0
                    }
                    for index in files.count ..< self.fileNodes.count {
                        self.fileNodes[index].isHidden = true
                    }

                    let node = textApply(InteractiveTextNode.ApplyArguments(animation: animation, spoilerTextColor: theme.outgoing.primaryTextColor, spoilerEffectColor: theme.outgoing.primaryTextColor, areContentAnimationsEnabled: true, spoilerExpandRect: nil))
                    self.setTextNodes([node])
                    node.isHidden = !hasText
                    let textFrame = CGRect(origin: CGPoint(x: backgroundFrame.minX + textInsets.left, y: contentY), size: textLayout.size)
                    animation.animator.updateFrame(layer: node.layer, frame: textFrame, completion: nil)
                    self.setTableNodes([])
                    // VoiceOver reads the message, and UI tests find it by its text; one with photos leaves them their
                    // own elements.
                    self.isAccessibilityElement = message.attachments.isEmpty
                    self.accessibilityIdentifier = "userMessage"
                    self.accessibilityLabel = message.text

                    let _ = dateApply()
                    let dateFrame = CGRect(origin: CGPoint(x: backgroundFrame.maxX - bubbleTailInset - textInsets.right - dateAreaWidth, y: backgroundFrame.maxY - textInsets.bottom - dateLayout.size.height + 1.0), size: dateLayout.size)
                    animation.animator.updateFrame(layer: self.dateNode.layer, frame: dateFrame, completion: nil)
                    self.updateStatus(item: item, dateFrame: dateFrame, backgroundFrame: backgroundFrame, failedInset: failedInset, animation: animation)

                    self.layoutContainers(size: layout.contentSize)
                    self.updateSelection(item: item, size: layout.contentSize, animation: animation)
                })

            case .assistant, .thinking:
                let mergedTop = above == .assistant || above == .tool
                if message.isWaiting {
                    let size = ChatWaitingNode.size
                    let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: size.height + 4.0), insets: UIEdgeInsets(top: mergedTop ? 6.0 : 10.0, left: 0.0, bottom: 6.0, right: 0.0))
                    return (layout, { _ in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.stopReveal()
                        self.laidOutBlocks = []
                        self.bubbleNode.isHidden = true
                        self.dateNode.isHidden = true
                        self.hideStatus()
                        self.setToolVisible(false)
                        self.setTextNodes([])
                        // The same τ across updates, so its tracing does not restart.
                        let existing = self.waitingNode
                        self.waitingNode = nil
                        self.setTableNodes([])
                        for node in self.imageNodes {
                            node.isHidden = true
                        }
                        for node in self.fileNodes {
                            node.isHidden = true
                        }
                        let node = existing ?? ChatWaitingNode()
                        self.waitingNode = node
                        if node.supernode !== self.contentNode {
                            self.contentNode.addSubnode(node)
                        }
                        node.update(color: item.theme.accentColor)
                        // Where the answer's first letter will be.
                        node.frame = CGRect(origin: CGPoint(x: params.leftInset + freeTextInset + leftShift - 3.0, y: 2.0), size: size)
                        if let retry = message.retry {
                            let label = self.waitingLabelNode ?? ImmediateTextNode()
                            label.displaysAsynchronously = false
                            label.maximumNumberOfLines = 1
                            if label.supernode !== self.contentNode {
                                self.contentNode.addSubnode(label)
                            }
                            self.waitingLabelNode = label
                            let labelX = node.frame.maxX + 6.0
                            let maxWidth = params.width - params.rightInset - freeTextInset - labelX
                            let color = theme.freeSecondaryTextColor
                            self.setTimerTick { [weak label] in
                                guard let label else {
                                    return
                                }
                                // "retrying in 5s (attempt 3): overloaded", lowercase as the chat's other statuses.
                                var text: String
                                if let at = retry.at, at.timeIntervalSinceNow > 0.5 {
                                    text = "retrying in \(formatElapsed(at.timeIntervalSinceNow.rounded(.up)))"
                                } else {
                                    text = "retrying"
                                }
                                if retry.attempt > 2 {
                                    text += " (attempt \(retry.attempt))"
                                }
                                text += ": " + retry.reason
                                label.attributedText = NSAttributedString(string: text, font: Font.regular(14.0), textColor: color)
                                let labelSize = label.updateLayout(CGSize(width: maxWidth, height: 20.0))
                                label.frame = CGRect(origin: CGPoint(x: labelX, y: node.frame.midY - labelSize.height / 2.0), size: labelSize)
                            }
                        } else if let label = self.waitingLabelNode {
                            self.waitingLabelNode = nil
                            label.removeFromSupernode()
                        }
                        self.contentFrame = .zero
                        self.layoutContainers(size: layout.contentSize)
                    })
                }
                let maxTextWidth = contentWidth - freeTextInset * 2.0 - leftShift
                let isThinking = message.role == .thinking
                // Reasoning is dimmer and smaller.
                var style = MarkdownStyle(fontSize: isThinking ? item.theme.scaled(15.0) : item.theme.fontSize, textColor: isThinking ? theme.freeSecondaryTextColor : theme.freeTextColor, linkColor: theme.linkTextColor, accentColor: item.theme.accentColor)
                style.maxWidth = maxTextWidth
                style.lineSpacing = MarkdownStyle.answerLineSpacing
                // Reasoning shows whole, as the answer does.
                let sourceText = message.text
                let blocks = MarkdownText.blocks(sourceText, style: style, wrapCode: item.wrapCode) + (item.isStreaming ? [] : item.references.map { .text(MarkdownText.reference($0, style: style)) })
                let tableStyle = ChatTableStyle(borderColor: theme.tableBorderColor, headerBackgroundColor: theme.tableHeaderBackgroundColor)

                var laidOut: [LaidOutBlock] = []
                var textApplies: [(InteractiveTextNode.ApplyArguments) -> InteractiveTextNode] = []
                /// Per text block: a code block that scrolls sideways.
                var textScrolls: [Bool] = []
                var tableApplies: [(ChatTableNode, () -> Void)] = []
                var textIndex = 0
                var tableIndex = 0
                var start = 0
                // A streaming answer's text is drawn as it is laid out: drawn in the background, a block laid out again
                // on every step showed blank until it was drawn, and with steps coming faster than that, stayed blank.
                let drawsSynchronously = item.isStreaming || currentRevealCount != nil
                func textNode(_ index: Int) -> InteractiveTextNode? {
                    if index < existingTextNodes.count {
                        return existingTextNodes[index]
                    }
                    guard drawsSynchronously else {
                        return nil
                    }
                    let node = InteractiveTextNode()
                    node.displaysAsynchronously = false
                    return node
                }
                for (blockIndex, block) in blocks.enumerated() {
                    let spacing = blockIndex == 0 ? 0.0 : MarkdownText.spacing(between: blocks[blockIndex - 1], and: block, fontSize: style.fontSize)
                    switch block {
                    case let .text(string):
                        let existing = textNode(textIndex)
                        let (layout, apply) = InteractiveTextNode.asyncLayout(existing)(InteractiveTextNodeLayoutArguments(attributedString: string, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude), lineSpacing: style.lineSpacing))
                        laidOut.append(.text(start: start, length: string.length, layout: layout, spacing: spacing))
                        textApplies.append(apply)
                        textScrolls.append(false)
                        textIndex += 1
                    case let .code(string):
                        // As wide as its longest line; the row shows it through a horizontal scroller.
                        let existing = textNode(textIndex)
                        let (layout, apply) = InteractiveTextNode.asyncLayout(existing)(InteractiveTextNodeLayoutArguments(attributedString: string, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: 100_000.0, height: .greatestFiniteMagnitude), minWidth: maxTextWidth))
                        laidOut.append(.text(start: start, length: string.length, layout: layout, spacing: spacing))
                        textApplies.append(apply)
                        textScrolls.append(true)
                        textIndex += 1
                    case let .table(table):
                        let node = tableIndex < existingTableNodes.count ? existingTableNodes[tableIndex] : ChatTableNode()
                        let makeTableLayout = tableIndex < existingTableLayouts.count ? existingTableLayouts[tableIndex] : ChatTableNode.asyncLayout(node)
                        let (size, apply) = makeTableLayout(table, tableStyle, maxTextWidth)
                        laidOut.append(.table(start: start, length: table.characterCount, size: size, spacing: spacing))
                        tableApplies.append((node, apply))
                        tableIndex += 1
                    }
                    start += block.characterCount
                }
                let totalLength = start

                // While streaming, the row is as tall as the content revealed so far; a new node for a streaming answer
                // goes on from what the last one had revealed.
                let carriedReveal = currentRevealCount ?? (item.isStreaming ? item.interaction.revealProgress.with { $0[message.id] } : nil)
                let revealed: Int? = (item.isStreaming || carriedReveal != nil) ? (carriedReveal ?? 0) : nil
                let textHeight = contentHeight(laidOut, revealed: revealed)
                // The end of a run: when the answer came at the bottom right, as Telegram dates a message, and how the
                // run went at the bottom left, words apart from the time rather than a dot.
                var footerLayout: TextNodeLayout?
                var footerApply: (() -> TextNode)?
                var runLayout: TextNodeLayout?
                var runApply: (() -> TextNode)?
                if let turn = message.turn, !item.isStreaming, revealed == nil {
                    let (layout, apply) = makeDateLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: messageTimeString(turn.finishedAt), font: dateFont(item.theme), textColor: theme.freeSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: 40.0)))
                    footerLayout = layout
                    footerApply = apply
                    var parts: [String] = []
                    if turn.retries > 0 {
                        // The provider failed on the way, and the server asked again.
                        parts.append(turn.retries == 1 ? "retried once" : "retried \(turn.retries) times")
                    }
                    if let duration = turn.duration, duration >= 1.0 {
                        parts.append("worked for \(formatDuration(duration))")
                    }
                    if !parts.isEmpty {
                        let (layout, apply) = makeRunLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: parts.joined(separator: ", "), font: dateFont(item.theme), textColor: theme.freeSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth - layout.size.width - 12.0, height: 40.0)))
                        runLayout = layout
                        runApply = apply
                    }
                }
                let footerSpacing: CGFloat = 5.0
                let height = textHeight + (footerLayout.map { footerSpacing + $0.size.height } ?? 0.0)
                let insets = UIEdgeInsets(top: mergedTop ? 6.0 : 10.0, left: 0.0, bottom: 6.0, right: 0.0)
                let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: insets)

                return (layout, { animation in
                    guard let self else {
                        return
                    }
                    self.item = item
                    self.laidOutBlocks = laidOut
                    self.bubbleNode.isHidden = true
                    if let footerLayout, let footerApply {
                        let _ = footerApply()
                        // The footer comes when the run ends.
                        let appearing = self.dateNode.isHidden
                        if appearing {
                            self.dateNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                        }
                        self.dateNode.isHidden = false
                        let x = params.leftInset + freeTextInset + leftShift
                        self.dateNode.frame = CGRect(origin: CGPoint(x: x + maxTextWidth - footerLayout.size.width, y: textHeight + footerSpacing), size: footerLayout.size)
                        if let runLayout, let runApply {
                            let _ = runApply()
                            if appearing {
                                self.runNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                            }
                            self.runNode.isHidden = false
                            self.runNode.frame = CGRect(origin: CGPoint(x: x, y: textHeight + footerSpacing), size: runLayout.size)
                        }
                    } else {
                        self.dateNode.isHidden = true
                    }
                    self.hideStatus()
                    self.setToolVisible(false)
                    for node in self.imageNodes {
                        node.isHidden = true
                    }
                    for node in self.fileNodes {
                        node.isHidden = true
                    }

                    // While the answer streams its blocks only grow, and new text comes in through the reveal: their
                    // frames move at once. Animating them on every step left each block chasing an animation that the
                    // next step replaced, so blocks drifted into each other until the stream ended. The row's own height
                    // still animates in the list.
                    let contentAnimation: ListViewItemUpdateAnimation = revealed != nil ? .None : animation
                    for node in existingTextNodes {
                        node.displaysAsynchronously = !drawsSynchronously
                    }
                    let applyArguments = InteractiveTextNode.ApplyArguments(animation: contentAnimation, spoilerTextColor: theme.freeTextColor, spoilerEffectColor: theme.freeTextColor, areContentAnimationsEnabled: true, spoilerExpandRect: nil)
                    let textNodes = textApplies.map { $0(applyArguments) }
                    self.setTextNodes(textNodes)
                    for (node, apply) in tableApplies {
                        apply()
                        _ = node
                    }
                    self.setTableNodes(tableApplies.map(\.0))

                    var y: CGFloat = 0.0
                    var textCursor = 0
                    var tableCursor = 0
                    let x = params.leftInset + freeTextInset + leftShift
                    for block in laidOut {
                        if y > 0.0 {
                            y += block.spacing
                        }
                        switch block {
                        case let .text(_, _, layout, _):
                            let node = textNodes[textCursor]
                            let scrolls = textScrolls[textCursor]
                            textCursor += 1
                            if scrolls {
                                // The scroller spans the row, so code scrolls out to the screen's edges.
                                let scroller = self.codeScroller(for: node)
                                contentAnimation.animator.updateFrame(layer: scroller.layer, frame: CGRect(x: 0.0, y: y, width: params.width, height: layout.size.height), completion: nil)
                                node.frame = CGRect(origin: CGPoint(x: x, y: 0.0), size: layout.size)
                                scroller.view.contentSize = CGSize(width: max(params.width, x + layout.size.width + freeTextInset), height: layout.size.height)
                                CodeScrollFade.update(scroller.view)
                            } else {
                                if node.supernode !== self.contentNode {
                                    self.contentNode.insertSubnode(node, belowSubnode: self.dateNode)
                                }
                                contentAnimation.animator.updateFrame(layer: node.layer, frame: CGRect(origin: CGPoint(x: x, y: y), size: layout.size), completion: nil)
                            }
                            y += layout.size.height
                        case let .table(_, _, size, _):
                            let node = tableApplies[tableCursor].0
                            tableCursor += 1
                            contentAnimation.animator.updateFrame(layer: node.layer, frame: CGRect(origin: CGPoint(x: x, y: y), size: size), completion: nil)
                            y += size.height
                        }
                    }
                    self.removeCodeScrollers(keeping: zip(textNodes, textScrolls).filter(\.1).map(\.0))
                    self.contentFrame = CGRect(x: x - 8.0, y: -4.0, width: maxTextWidth + 16.0, height: height + 8.0)
                    // Read as one, as Telegram reads a message.
                    if message.role == .assistant {
                        self.isAccessibilityElement = true
                        self.accessibilityIdentifier = "assistantMessage"
                        self.accessibilityLabel = message.text
                    }
                    self.updateReveal(item: item, totalLength: totalLength)
                    self.layoutContainers(size: layout.contentSize)
                    self.updateSelection(item: item, size: layout.contentSize, animation: animation)
                })

            case .service:
                let serviceText = theme.serviceTextColor
                let insets = UIEdgeInsets(top: 10.0, left: 0.0, bottom: 10.0, right: 0.0)
                switch message.service ?? .compacting(since: Date(), waiting: false) {
                case .compacting, .compactionUnused:
                    // Telegram's service pill: a compaction at work, with the τ tracing in it and the time it has taken
                    // so far; made and waiting for the run's next step; or a note of one that ended unused.
                    var titleText = "Compacting context…"
                    var since: Date?
                    var showsTau = true
                    switch message.service {
                    case let .compacting(start, waiting):
                        if waiting {
                            titleText = "Context summarized · goes in at the next step"
                        } else {
                            since = start
                        }
                    case let .compactionUnused(state, error):
                        showsTau = false
                        switch state {
                        case "stale":
                            titleText = "Compaction not used: the chat moved on"
                        case "empty":
                            titleText = "Nothing to compact"
                        default:
                            titleText = "Compaction failed" + (error.map { ": \($0)" } ?? "")
                        }
                    default:
                        break
                    }
                    let pillHeight: CGFloat = 28.0
                    let title = NSAttributedString(string: titleText, font: Font.medium(13.0), textColor: serviceText)
                    let (titleLayout, titleApply) = makeToolTitleLayout(TextNodeLayoutArguments(attributedString: title, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: contentWidth - 80.0, height: 30.0)))
                    let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: pillHeight), insets: insets)
                    return (layout, { _ in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.stopReveal()
                        self.laidOutBlocks = []
                        self.bubbleNode.isHidden = true
                        self.dateNode.isHidden = true
                        self.hideStatus()
                        self.setTextNodes([])
                        let existingTau = self.serviceTauNode
                        self.serviceTauNode = nil
                        self.setTableNodes([])
                        self.setToolVisible(true)
                        self.setSubagentVisible(false)
                        self.toolTextNode.isHidden = true
                        self.toolShowAllNode.isHidden = true
                        self.toolShowAllFrame = nil
                        for node in self.imageNodes {
                            node.isHidden = true
                        }
                        for node in self.fileNodes {
                            node.isHidden = true
                        }
                        var tau: ChatWaitingNode?
                        if showsTau {
                            let node = existingTau ?? ChatWaitingNode()
                            if node.supernode !== self.contentNode {
                                self.contentNode.addSubnode(node)
                            }
                            self.serviceTauNode = node
                            node.update(color: serviceText)
                            tau = node
                        } else {
                            existingTau?.removeFromSupernode()
                        }
                        self.isAccessibilityElement = true
                        self.accessibilityIdentifier = "compactionPill"
                        self.accessibilityLabel = titleText
                        let _ = titleApply()
                        self.toolBackgroundNode.backgroundColor = theme.serviceFillColor
                        let tauSize: CGFloat = showsTau ? 18.0 : 0.0
                        let tauGap: CGFloat = showsTau ? 5.0 : 2.0
                        let place = { [weak self] in
                            guard let self else {
                                return
                            }
                            let elapsed = since.map { Date().timeIntervalSince($0) } ?? 0.0
                            let time = elapsed >= 1.0 ? "  " + formatElapsed(elapsed) : nil
                            var timeWidth: CGFloat = 0.0
                            if let time {
                                self.timerNode.attributedText = NSAttributedString(string: time, font: Font.with(size: 13.0, weight: .medium, traits: .monospacedNumbers), textColor: serviceText)
                                timeWidth = self.timerNode.updateLayout(CGSize(width: 200.0, height: 30.0)).width
                            }
                            self.timerNode.isHidden = time == nil
                            let width = 10.0 + tauSize + tauGap + titleLayout.size.width + timeWidth + 12.0
                            let pill = CGRect(x: floor((params.width - width) / 2.0), y: 0.0, width: width, height: pillHeight)
                            self.toolBackgroundNode.frame = pill
                            self.contentFrame = pill
                            if let tau {
                                tau.bounds = CGRect(origin: CGPoint(), size: ChatWaitingNode.size)
                                tau.position = CGPoint(x: pill.minX + 10.0 + tauSize / 2.0, y: pill.midY)
                                tau.transform = CATransform3DMakeScale(tauSize / ChatWaitingNode.size.width, tauSize / ChatWaitingNode.size.width, 1.0)
                            }
                            let titleFrame = CGRect(origin: CGPoint(x: pill.minX + 10.0 + tauSize + tauGap, y: floor(pill.midY - titleLayout.size.height / 2.0)), size: titleLayout.size)
                            self.toolTitleNode.frame = titleFrame
                            self.timerNode.frame = CGRect(x: titleFrame.maxX, y: titleFrame.minY, width: timeWidth, height: titleLayout.size.height)
                        }
                        if since != nil {
                            self.setTimerTick(place)
                        } else {
                            self.setTimerTick(nil)
                            place()
                        }
                        self.layoutContainers(size: layout.contentSize)
                    })

                case let .failed(error):
                    // Where the answer would be, as a card: what went wrong, and Retry, which sends the message again,
                    // as an alert's button.
                    let destructive = item.theme.presentationTheme.overallDarkAppearance ? UIColor(rgb: 0xff6961) : UIColor(rgb: 0xd70015)
                    let cardWidth = min(contentWidth - freeTextInset * 2.0 - leftShift, 360.0)
                    let cardInsets = UIEdgeInsets(top: 10.0, left: 12.0, bottom: 0.0, right: 12.0)
                    let innerWidth = cardWidth - cardInsets.left - cardInsets.right
                    let header = NSAttributedString(string: "The model failed", font: Font.semibold(15.0), textColor: destructive)
                    let (headerLayout, headerApply) = makeToolTitleLayout(TextNodeLayoutArguments(attributedString: header, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: innerWidth, height: 30.0)))
                    let body = NSAttributedString(string: error, font: Font.regular(14.0), textColor: theme.toolCardTextColor)
                    let (bodyLayout, bodyApply) = makeSubagentTaskLayout(TextNodeLayoutArguments(attributedString: body, maximumNumberOfLines: item.isExpanded ? 40 : 4, truncationType: .end, constrainedSize: CGSize(width: innerWidth, height: .greatestFiniteMagnitude)))
                    let button = NSAttributedString(string: "Retry", font: Font.semibold(16.0), textColor: item.theme.accentColor)
                    let (buttonLayout, buttonApply) = makeSubagentMetaLayout(TextNodeLayoutArguments(attributedString: button, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: innerWidth, height: 30.0)))
                    let buttonHeight: CGFloat = 44.0
                    let separatorY = cardInsets.top + headerLayout.size.height + 3.0 + bodyLayout.size.height + 10.0
                    let cardHeight = separatorY + buttonHeight
                    let mergedTop = above == .assistant || above == .tool
                    let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: cardHeight), insets: UIEdgeInsets(top: mergedTop ? 6.0 : 10.0, left: 0.0, bottom: 6.0, right: 0.0))
                    return (layout, { animation in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.stopReveal()
                        self.laidOutBlocks = []
                        self.bubbleNode.isHidden = true
                        self.dateNode.isHidden = true
                        self.hideStatus()
                        self.setTextNodes([])
                        self.setTableNodes([])
                        self.setToolVisible(true)
                        self.setSubagentVisible(false)
                        self.toolTextNode.isHidden = true
                        self.toolShowAllNode.isHidden = true
                        self.toolShowAllFrame = nil
                        for node in self.imageNodes {
                            node.isHidden = true
                        }
                        for node in self.fileNodes {
                            node.isHidden = true
                        }
                        self.isAccessibilityElement = true
                        self.accessibilityIdentifier = "modelError"
                        self.accessibilityLabel = error
                        let card = CGRect(x: params.leftInset + freeTextInset - 4.0 + leftShift, y: 0.0, width: cardWidth, height: cardHeight)
                        self.contentFrame = card
                        self.toolBackgroundNode.backgroundColor = theme.toolCardBackgroundColor
                        animation.animator.updateFrame(layer: self.toolBackgroundNode.layer, frame: card, completion: nil)
                        let _ = headerApply()
                        self.toolTitleNode.frame = CGRect(origin: CGPoint(x: card.minX + cardInsets.left, y: card.minY + cardInsets.top), size: headerLayout.size)
                        let _ = bodyApply()
                        self.subagentTaskNode.isHidden = false
                        self.subagentTaskNode.frame = CGRect(origin: CGPoint(x: card.minX + cardInsets.left, y: card.minY + cardInsets.top + headerLayout.size.height + 3.0), size: bodyLayout.size)
                        self.subagentQuoteNode.isHidden = false
                        self.subagentQuoteNode.backgroundColor = theme.toolCardTextColor.withMultipliedAlpha(0.25)
                        self.subagentQuoteNode.frame = CGRect(x: card.minX, y: card.minY + separatorY, width: cardWidth, height: UIScreenPixel)
                        self.subagentBarNode.frame = .zero
                        let _ = buttonApply()
                        self.subagentMetaNode.isHidden = false
                        self.subagentMetaNode.frame = CGRect(origin: CGPoint(x: card.minX + floor((cardWidth - buttonLayout.size.width) / 2.0), y: card.minY + separatorY + floor((buttonHeight - buttonLayout.size.height) / 2.0)), size: buttonLayout.size)
                        self.retryButtonFrame = CGRect(x: card.minX, y: card.minY + separatorY, width: cardWidth, height: buttonHeight)
                        self.layoutContainers(size: layout.contentSize)
                        self.updateSelection(item: item, size: layout.contentSize, animation: animation)
                    })

                case let .compacted(summary, reason, tokensBefore, tokensAfter, cost):
                    // A card on the service fill, as Telegram's service messages with content: what happened, then
                    // the summary the model now reads, folded until tapped.
                    let cardWidth = min(contentWidth - 48.0, 360.0)
                    let cardInsets = UIEdgeInsets(top: 12.0, left: 14.0, bottom: 12.0, right: 14.0)
                    let innerWidth = cardWidth - cardInsets.left - cardInsets.right
                    let header = NSAttributedString(string: "Context compacted", font: Font.semibold(15.0), textColor: serviceText)
                    let (headerLayout, headerApply) = makeToolTitleLayout(TextNodeLayoutArguments(attributedString: header, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: innerWidth, height: 30.0)))
                    // When, and why where it says something: on its own as the context filled, after a request too long
                    // for the model.
                    let time = messageTimeString(message.date)
                    let when: String
                    switch reason {
                    case "threshold":
                        when = "automatically at \(time)"
                    case "overflow":
                        when = "after an overflow at \(time)"
                    default:
                        when = "at \(time)"
                    }
                    // What it means for the model from here on, and what it made of the context and cost.
                    var lines = [when.prefix(1).uppercased() + when.dropFirst(), "The model reads this summary instead of everything above it."]
                    var figures: [String] = []
                    if let tokensBefore, tokensBefore > 0 {
                        figures.append("\(formatTokens(tokensBefore)) → \(tokensAfter.map(formatTokens) ?? "…") tokens")
                    }
                    if let cost, cost > 0.0 {
                        figures.append(formatCost(cost))
                    }
                    if !figures.isEmpty {
                        lines.append(figures.joined(separator: " · "))
                    }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    let subline = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: Font.regular(13.0), .foregroundColor: serviceText.withMultipliedAlpha(0.7), .paragraphStyle: paragraph])
                    let (sublineLayout, sublineApply) = makeSubagentTaskLayout(TextNodeLayoutArguments(attributedString: subline, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: innerWidth, height: .greatestFiniteMagnitude), alignment: .center))
                    var style = MarkdownStyle(fontSize: 14.0, textColor: serviceText, linkColor: serviceText, accentColor: serviceText)
                    style.maxWidth = innerWidth
                    let summaryText = MarkdownText.render(summary.isEmpty ? "No summary." : summary, style: style)
                    let (summaryLayout, summaryApply) = makeSubagentAnswerLayout(InteractiveTextNodeLayoutArguments(attributedString: summaryText, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: innerWidth, height: .greatestFiniteMagnitude)))
                    // Folded, as Telegram folds a long quote: the first lines fade out, with no ellipsis to land on
                    // a line of its own between paragraphs.
                    let foldedHeight: CGFloat = 96.0
                    let isFolded = !item.isExpanded && summaryLayout.size.height > foldedHeight + 16.0
                    let summaryHeight = isFolded ? foldedHeight : summaryLayout.size.height
                    // The arrow only where there is something to fold.
                    let showsArrow = summaryLayout.size.height > foldedHeight + 16.0
                    let arrowImage = generateTintedImage(image: UIImage(bundleImageName: "Item List/ExpandingItemVerticalSmallArrow"), color: serviceText.withMultipliedAlpha(0.7))
                    let arrowHeight = showsArrow ? (arrowImage?.size.height ?? 0.0) + 6.0 : 6.0
                    let separatorY = cardInsets.top + headerLayout.size.height + 2.0 + sublineLayout.size.height + 10.0
                    let summaryY = separatorY + 10.0
                    let cardHeight = summaryY + summaryHeight + 6.0 + arrowHeight + cardInsets.bottom - 6.0
                    let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: cardHeight), insets: insets)
                    return (layout, { animation in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.stopReveal()
                        self.laidOutBlocks = []
                        self.bubbleNode.isHidden = true
                        self.dateNode.isHidden = true
                        self.hideStatus()
                        self.setTextNodes([])
                        self.setTableNodes([])
                        self.setToolVisible(true)
                        self.setSubagentVisible(false)
                        self.toolTextNode.isHidden = true
                        self.toolShowAllNode.isHidden = true
                        self.toolShowAllFrame = nil
                        for node in self.imageNodes {
                            node.isHidden = true
                        }
                        for node in self.fileNodes {
                            node.isHidden = true
                        }
                        self.isAccessibilityElement = true
                        self.accessibilityIdentifier = "compactionCard"
                        self.accessibilityLabel = "Context compacted. " + lines.joined(separator: " ") + " " + summary
                        let card = CGRect(x: floor((params.width - cardWidth) / 2.0), y: 0.0, width: cardWidth, height: cardHeight)
                        self.contentFrame = card
                        self.toolBackgroundNode.backgroundColor = theme.serviceFillColor
                        animation.animator.updateFrame(layer: self.toolBackgroundNode.layer, frame: card, completion: nil)
                        let _ = headerApply()
                        self.toolTitleNode.frame = CGRect(origin: CGPoint(x: card.minX + floor((cardWidth - headerLayout.size.width) / 2.0), y: card.minY + cardInsets.top), size: headerLayout.size)
                        let _ = sublineApply()
                        self.subagentTaskNode.isHidden = false
                        self.subagentTaskNode.frame = CGRect(origin: CGPoint(x: card.minX + floor((cardWidth - sublineLayout.size.width) / 2.0), y: card.minY + cardInsets.top + headerLayout.size.height + 2.0), size: sublineLayout.size)
                        // The hairline between what happened and the summary: the quote bar node, laid flat.
                        self.subagentQuoteNode.isHidden = false
                        self.subagentQuoteNode.backgroundColor = serviceText.withMultipliedAlpha(0.18)
                        self.subagentQuoteNode.frame = CGRect(x: card.minX + cardInsets.left, y: card.minY + separatorY, width: innerWidth, height: UIScreenPixel)
                        self.subagentBarNode.frame = .zero
                        let node = summaryApply(InteractiveTextNode.ApplyArguments(animation: animation, spoilerTextColor: serviceText, spoilerEffectColor: serviceText, areContentAnimationsEnabled: true, spoilerExpandRect: nil))
                        node.isUserInteractionEnabled = false
                        if node.supernode !== self.contentNode {
                            self.contentNode.insertSubnode(node, belowSubnode: self.dateNode)
                        }
                        self.subagentAnswerNode = node
                        node.isHidden = false
                        animation.animator.updateFrame(layer: node.layer, frame: CGRect(origin: CGPoint(x: card.minX + cardInsets.left, y: card.minY + summaryY), size: summaryLayout.size), completion: nil)
                        if isFolded {
                            let mask = CAGradientLayer()
                            mask.frame = CGRect(x: 0.0, y: 0.0, width: summaryLayout.size.width, height: summaryHeight)
                            mask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
                            mask.locations = [0.0, NSNumber(value: Double((summaryHeight - 36.0) / summaryHeight)), 1.0]
                            node.layer.mask = mask
                        } else {
                            node.layer.mask = nil
                        }
                        self.subagentArrowNode.isHidden = !showsArrow
                        if let arrowImage, showsArrow {
                            self.subagentArrowNode.isHidden = false
                            self.subagentArrowNode.image = arrowImage
                            self.subagentArrowNode.frame = CGRect(x: card.midX - arrowImage.size.width / 2.0, y: card.maxY - cardInsets.bottom - arrowImage.size.height + 2.0, width: arrowImage.size.width, height: arrowImage.size.height)
                            self.subagentArrowNode.transform = item.isExpanded ? CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0) : CATransform3DIdentity
                        }
                        self.layoutContainers(size: layout.contentSize)
                        self.updateSelection(item: item, size: layout.contentSize, animation: animation)
                    })
                }

            case let .tool(name):
                if name == "send_file", let tool = message.tool, tool.status == .done, !tool.sentFiles.isEmpty {
                    // What the agent sent: no card, but its photos as an album and its files as Telegram's document rows,
                    // as a message of media from someone writes them, on the background as the agent's text.
                    let maxWidth = min(contentWidth - freeTextInset * 2.0 - leftShift, 320.0)
                    let photos = tool.sentFiles.filter(\.isPhoto)
                    let files = tool.sentFiles.compactMap { attachment -> FileAttachment? in
                        if case let .file(file) = attachment.kind {
                            return file
                        }
                        return nil
                    }
                    let mosaic = photoMosaic(photos.map(photoPixelSize), maxWidth: maxWidth)
                    let fileSizes = files.map { FileAttachmentNode.measure($0, fontSize: item.theme.fontSize, maxWidth: maxWidth) }
                    let fileSpacing: CGFloat = 8.0
                    let photosHeight: CGFloat = photos.isEmpty ? 0.0 : mosaic.size.height
                    let filesHeight = fileSizes.reduce(0.0) { $0 + $1.height } + CGFloat(max(0, files.count - 1)) * fileSpacing
                    let gap: CGFloat = !photos.isEmpty && !files.isEmpty ? 10.0 : 0.0
                    let height = photosHeight + gap + filesHeight
                    let width = max(mosaic.size.width, fileSizes.map(\.width).max() ?? 0.0)
                    let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets(top: 6.0, left: 0.0, bottom: 6.0, right: 0.0))
                    return (layout, { animation in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.stopReveal()
                        self.laidOutBlocks = []
                        self.bubbleNode.isHidden = true
                        self.dateNode.isHidden = true
                        self.hideStatus()
                        self.setTextNodes([])
                        self.setTableNodes([])
                        self.setToolVisible(false)
                        self.setSubagentVisible(false)
                        self.updateToolActivity(isActive: false, color: theme.toolCardTextColor, frame: CGRect())
                        self.setTimerTick(nil)
                        let origin = CGPoint(x: params.leftInset + freeTextInset + leftShift, y: 0.0)
                        self.contentFrame = CGRect(origin: origin, size: CGSize(width: width, height: height))
                        self.ensureImageNodes(photos.count)
                        self.imageAttachmentIds = []
                        for (index, attachment) in photos.enumerated() {
                            let imageNode = self.imageNodes[index]
                            let (frame, position) = mosaic.frames[index]
                            imageNode.setAttachment(attachment.kind, placeholderColor: theme.serviceFillColor)
                            imageNode.isHidden = false
                            imageNode.alpha = attachment.id == self.hiddenAttachmentId ? 0.0 : 1.0
                            imageNode.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
                            photoCorners(imageNode.layer, position: position, captioned: false, mergedTop: false, mergedBottom: false, radius: 12.0)
                            self.imageAttachmentIds.append(attachment.id)
                        }
                        for index in photos.count ..< self.imageNodes.count {
                            self.imageNodes[index].isHidden = true
                        }
                        while self.fileNodes.count < files.count {
                            let fileNode = FileAttachmentNode()
                            self.fileNodes.append(fileNode)
                            self.contentNode.addSubnode(fileNode)
                        }
                        var y = origin.y + photosHeight + gap
                        for (index, file) in files.enumerated() {
                            let fileNode = self.fileNodes[index]
                            fileNode.isHidden = false
                            fileNode.update(file: file, incoming: true, theme: item.theme, status: item.interaction.fileStatus(file), width: fileSizes[index].width)
                            fileNode.frame = CGRect(origin: CGPoint(x: origin.x, y: y), size: fileSizes[index])
                            y += fileSizes[index].height + fileSpacing
                        }
                        for index in files.count ..< self.fileNodes.count {
                            self.fileNodes[index].isHidden = true
                        }
                        self.isAccessibilityElement = false
                        self.accessibilityIdentifier = "sentFiles"
                        self.layoutContainers(size: layout.contentSize)
                        self.updateSelection(item: item, size: layout.contentSize, animation: animation)
                    })
                }
                if let call = message.tool?.subagent {
                    let tool = message.tool!
                    let status = tool.status
                    let working = status == .preparing || status == .pending || status == .running || tool.childBusy
                    let accent = item.theme.accentColor
                    let cardWidth = contentWidth - freeTextInset * 2.0 + 8.0 - leftShift
                    let quoteInset: CGFloat = 6.0
                    let quoteWidth = cardWidth - quoteInset * 2.0
                    // While it works, its time ticks beside the spinner.
                    let workingSince = working && (call.kind == .spawn || call.kind == .send) ? call.startedAt : nil
                    let quoteText = UIEdgeInsets(top: 6.0, left: 11.0, bottom: 7.0, right: 30.0 + (workingSince != nil ? timerWidth("59m 59s") + 4.0 : 0.0))
                    let textWidth = quoteWidth - quoteText.left - quoteText.right

                    // The quote: who, and the task it works on.
                    let header = NSMutableAttributedString(string: call.name, font: Font.semibold(14.0), textColor: accent)
                    let suffix: String
                    switch call.kind {
                    case .spawn:
                        suffix = working ? "working" : status == .stopped ? "stopped" : (call.duration.map { "worked \(formatDuration($0))" } ?? "")
                    case .send:
                        suffix = "message"
                    case .stop:
                        suffix = "stopped"
                    case .answer:
                        suffix = call.duration.map { "answered in \(formatDuration($0))" } ?? "answered"
                    case .failed:
                        suffix = "failed"
                    }
                    if !suffix.isEmpty {
                        header.append(NSAttributedString(string: "  " + suffix, font: Font.regular(14.0), textColor: call.kind == .failed ? item.theme.list.itemDestructiveColor : theme.toolCardTextColor))
                    }
                    let (headerLayout, headerApply) = makeToolTitleLayout(TextNodeLayoutArguments(attributedString: header, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: textWidth, height: .greatestFiniteMagnitude)))
                    let quoted: String
                    switch call.kind {
                    case .spawn, .send:
                        quoted = call.text
                    case .answer, .failed, .stop:
                        quoted = call.task ?? "Subagent"
                    }
                    let quoteLines = call.kind == .spawn ? (item.isExpanded ? 0 : 3) : (call.kind == .send ? 2 : 1)
                    let taskString = NSAttributedString(string: quoted.replacingOccurrences(of: "\n", with: quoteLines == 1 ? " " : "\n"), font: Font.regular(14.0), textColor: theme.toolCardTitleColor)
                    let (taskLayout, taskApply) = makeSubagentTaskLayout(TextNodeLayoutArguments(attributedString: taskString, maximumNumberOfLines: quoteLines, truncationType: .end, constrainedSize: CGSize(width: textWidth, height: .greatestFiniteMagnitude)))
                    let quoteHeight = quoteText.top + headerLayout.size.height + 1.0 + taskLayout.size.height + quoteText.bottom

                    // Below it: the answer, as an answer reads; or what the subagent runs on.
                    let bodyInsets = UIEdgeInsets(top: 7.0, left: 12.0, bottom: 10.0, right: 12.0)
                    let bodyWidth = cardWidth - bodyInsets.left - bodyInsets.right
                    var answerLayout: InteractiveTextNodeLayout?
                    var answerApply: ((InteractiveTextNode.ApplyArguments) -> InteractiveTextNode)?
                    var metaLayout: TextNodeLayout?
                    var metaApply: (() -> TextNode)?
                    if call.kind == .answer || call.kind == .failed, !call.text.isEmpty {
                        var style = MarkdownStyle(fontSize: 15.0, textColor: call.kind == .failed ? theme.toolCardTextColor : theme.toolCardTitleColor, linkColor: theme.linkTextColor, accentColor: accent)
                        style.maxWidth = bodyWidth
                        let answer = MarkdownText.render(call.text, style: style)
                        let (layout, apply) = makeSubagentAnswerLayout(InteractiveTextNodeLayoutArguments(attributedString: answer, maximumNumberOfLines: item.isExpanded ? 0 : 12, truncationType: .end, constrainedSize: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)))
                        answerLayout = layout
                        answerApply = apply
                    } else if call.kind == .spawn {
                        var parts: [String] = []
                        if let model = call.model {
                            parts.append(model.split(separator: "/").last.map(String.init) ?? model)
                        }
                        if let thinking = call.thinking {
                            parts.append("thinking \(thinking)")
                        }
                        if call.fork {
                            parts.append("forked from this chat")
                        }
                        if !parts.isEmpty {
                            let (layout, apply) = makeSubagentMetaLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: parts.joined(separator: ", "), font: Font.regular(13.0), textColor: theme.toolCardTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)))
                            metaLayout = layout
                            metaApply = apply
                        }
                    }
                    var cardHeight = quoteInset + quoteHeight + quoteInset
                    if let answerLayout {
                        cardHeight += bodyInsets.top - quoteInset + answerLayout.size.height + bodyInsets.bottom
                    } else if let metaLayout {
                        cardHeight += 5.0 - quoteInset + metaLayout.size.height + 9.0
                    }
                    let cardSize = CGSize(width: cardWidth, height: cardHeight)
                    let mergedTop = above == .tool
                    let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: cardSize.height), insets: UIEdgeInsets(top: mergedTop ? 3.0 : 6.0, left: 0.0, bottom: 3.0, right: 0.0))
                    let arrowImage = PresentationResourcesItemList.disclosureArrowImage(item.theme.presentationTheme)

                    return (layout, { animation in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.stopReveal()
                        self.laidOutBlocks = []
                        self.bubbleNode.isHidden = true
                        self.dateNode.isHidden = true
                        self.hideStatus()
                        self.setTextNodes([])
                        self.setTableNodes([])
                        self.setToolVisible(true)
                        self.toolTextNode.isHidden = true
                        self.toolShowAllNode.isHidden = true
                        self.toolShowAllFrame = nil
                        self.setSubagentVisible(true)

                        self.toolBackgroundNode.backgroundColor = theme.toolCardBackgroundColor
                        let cardFrame = CGRect(origin: CGPoint(x: params.leftInset + freeTextInset - 4.0 + leftShift, y: 0.0), size: cardSize)
                        self.contentFrame = cardFrame
                        animation.animator.updateFrame(layer: self.toolBackgroundNode.layer, frame: cardFrame, completion: nil)

                        let quoteFrame = CGRect(x: cardFrame.minX + quoteInset, y: cardFrame.minY + quoteInset, width: quoteWidth, height: quoteHeight)
                        self.subagentQuoteNode.backgroundColor = accent.withAlphaComponent(item.theme.presentationTheme.overallDarkAppearance ? 0.16 : 0.1)
                        self.subagentBarNode.backgroundColor = accent
                        animation.animator.updateFrame(layer: self.subagentQuoteNode.layer, frame: quoteFrame, completion: nil)
                        self.subagentBarNode.frame = CGRect(x: 0.0, y: 0.0, width: 3.0, height: quoteHeight)

                        let _ = headerApply()
                        animation.animator.updateFrame(layer: self.toolTitleNode.layer, frame: CGRect(origin: CGPoint(x: quoteFrame.minX + quoteText.left, y: quoteFrame.minY + quoteText.top), size: headerLayout.size), completion: nil)
                        let _ = taskApply()
                        animation.animator.updateFrame(layer: self.subagentTaskNode.layer, frame: CGRect(origin: CGPoint(x: quoteFrame.minX + quoteText.left, y: quoteFrame.minY + quoteText.top + headerLayout.size.height + 1.0), size: taskLayout.size), completion: nil)

                        // Working: Telegram's spinner; otherwise the arrow into its transcript.
                        let accessoryFrame = CGRect(x: quoteFrame.maxX - 22.0, y: quoteFrame.minY + quoteText.top + floor((headerLayout.size.height - 14.0) / 2.0), width: 14.0, height: 14.0)
                        self.updateToolActivity(isActive: working, color: accent, frame: accessoryFrame)
                        if let workingSince {
                            self.setTimerTick { [weak self] in
                                let elapsed = Date().timeIntervalSince(workingSince)
                                self?.showTimer(elapsed >= 1.0 ? formatElapsed(elapsed) : nil, color: accent, maxX: accessoryFrame.minX - 6.0, midY: accessoryFrame.midY)
                            }
                        } else {
                            self.setTimerTick(nil)
                            self.showTimer(nil, color: accent, maxX: 0.0, midY: 0.0)
                        }
                        let hasLink = tool.childConversationId != nil && !working
                        self.subagentArrowNode.isHidden = !hasLink
                        if let arrowImage {
                            self.subagentArrowNode.transform = CATransform3DIdentity
                            self.subagentArrowNode.image = arrowImage
                            self.subagentArrowNode.frame = CGRect(x: quoteFrame.maxX - 10.0 - arrowImage.size.width, y: quoteFrame.minY + floor((quoteHeight - arrowImage.size.height) / 2.0), width: arrowImage.size.width, height: arrowImage.size.height)
                        }

                        if let answerLayout, let answerApply {
                            let node = answerApply(InteractiveTextNode.ApplyArguments(animation: animation, spoilerTextColor: theme.freeTextColor, spoilerEffectColor: theme.freeTextColor, areContentAnimationsEnabled: true, spoilerExpandRect: nil))
                            node.isUserInteractionEnabled = false
                            if node.supernode !== self.contentNode {
                                self.contentNode.insertSubnode(node, belowSubnode: self.dateNode)
                            }
                            self.subagentAnswerNode = node
                            node.isHidden = false
                            animation.animator.updateFrame(layer: node.layer, frame: CGRect(origin: CGPoint(x: cardFrame.minX + bodyInsets.left, y: quoteFrame.maxY + bodyInsets.top), size: answerLayout.size), completion: nil)
                        } else {
                            self.subagentAnswerNode?.isHidden = true
                        }
                        if let metaLayout, let metaApply {
                            let _ = metaApply()
                            self.subagentMetaNode.isHidden = false
                            self.subagentMetaNode.frame = CGRect(origin: CGPoint(x: cardFrame.minX + bodyInsets.left, y: quoteFrame.maxY + 5.0), size: metaLayout.size)
                        } else {
                            self.subagentMetaNode.isHidden = true
                        }
                        self.layoutContainers(size: layout.contentSize)
                        self.updateSelection(item: item, size: layout.contentSize, animation: animation)
                    })
                }
                let maxWidth = contentWidth - freeTextInset * 2.0 - 24.0 - leftShift
                let tool = message.tool
                let status = tool?.status ?? .done
                let isActive = status == .preparing || status == .pending || status == .running
                let isDark = item.theme.presentationTheme.overallDarkAppearance
                let cuts = ClipTracker()
                let (titleText, summaryText, body) = toolCardContent(name: name, tool: tool, fallbackText: message.text, isExpanded: item.isExpanded, isActive: isActive, isDark: isDark, textColor: theme.toolCardTextColor, titleColor: theme.toolCardTitleColor, accentColor: item.theme.accentColor, maxWidth: maxWidth, cuts: cuts)
                // Expanded and cut: Show All, under the text.
                let showsAll = item.isExpanded && cuts.clipped
                let (showAllLayout, showAllApply) = makeToolShowAllLayout(TextNodeLayoutArguments(attributedString: showsAll ? NSAttributedString(string: "Show All", font: Font.medium(14.0), textColor: item.theme.accentColor) : nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: maxWidth, height: .greatestFiniteMagnitude)))
                let showAllHeight: CGFloat = showsAll ? showAllLayout.size.height + 8.0 : 0.0
                // Title: the tool, then what it works on, as a terminal agent prints a call.
                let title = NSMutableAttributedString(string: titleText, font: toolTitleFont, textColor: status == .failed ? item.theme.list.itemDestructiveColor : theme.toolCardTitleColor)
                if !summaryText.isEmpty {
                    title.append(NSAttributedString(string: "  " + summaryText, font: Font.monospace(13.0), textColor: theme.toolCardTextColor))
                }
                // Its time at the right of the title: ticking while it runs past a second, then how long it took.
                let runningSince = status == .running ? tool?.startedAt : nil
                var finalTime: String?
                if status == .stopped {
                    finalTime = "stopped"
                } else if !isActive, let duration = tool?.duration, duration >= 1.0 {
                    finalTime = formatDuration(duration)
                }
                var timerReserve: CGFloat = 0.0
                if let runningSince {
                    let elapsed = Date().timeIntervalSince(runningSince)
                    timerReserve = elapsed >= 1.0 ? timerWidth(formatElapsed(max(elapsed, 10.0))) + 6.0 : 0.0
                } else if let finalTime {
                    timerReserve = timerWidth(finalTime) + 8.0
                }
                let titleWidth = maxWidth - (isActive ? 22.0 : 0.0) - timerReserve
                let (titleLayout, titleApply) = makeToolTitleLayout(TextNodeLayoutArguments(attributedString: title, maximumNumberOfLines: item.isExpanded ? 6 : 1, truncationType: .end, constrainedSize: CGSize(width: titleWidth, height: .greatestFiniteMagnitude)))

                if body.length > 0, body.string.hasSuffix("\n") {
                    body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
                }
                // A script's card has its script, its calls and its output: more lines, each section already cut.
                var isCode = false
                if case .code = tool?.detail {
                    isCode = true
                }
                // Expanded, each part is cut at its lines already (expandedToolLines): all of them, however they wrap.
                let (textLayout, textApply) = makeToolTextLayout(TextNodeLayoutArguments(attributedString: body, maximumNumberOfLines: item.isExpanded ? 0 : (isCode ? 16 : 10), truncationType: .end, constrainedSize: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), lineSpacing: 0.1))

                let cardInsets = UIEdgeInsets(top: 9.0, left: 12.0, bottom: 10.0, right: 12.0)
                let bodyHeight = body.length > 0 ? textLayout.size.height + 3.0 : 0.0
                // What the result showed the model (the read tool's image): in the card under its text, as an album.
                let toolPhotos = (tool?.images ?? []).filter(\.isPhoto)
                let toolMosaic = photoMosaic(toolPhotos.map(photoPixelSize), maxWidth: min(maxWidth, 260.0))
                let photosHeight: CGFloat = toolPhotos.isEmpty ? 0.0 : toolMosaic.size.height + 8.0
                let cardSize = CGSize(
                    width: max(max(titleLayout.size.width + (isActive ? 22.0 : 0.0) + timerReserve, body.length > 0 ? textLayout.size.width : 0.0), toolMosaic.size.width) + cardInsets.left + cardInsets.right,
                    height: titleLayout.size.height + bodyHeight + showAllHeight + photosHeight + cardInsets.top + cardInsets.bottom
                )
                let mergedTop = above == .tool
                let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: cardSize.height), insets: UIEdgeInsets(top: mergedTop ? 3.0 : 6.0, left: 0.0, bottom: 3.0, right: 0.0))

                return (layout, { animation in
                    guard let self else {
                        return
                    }
                    self.item = item
                    self.stopReveal()
                    self.laidOutBlocks = []
                    self.bubbleNode.isHidden = true
                    self.dateNode.isHidden = true
                    self.hideStatus()
                    self.setTextNodes([])
                    self.setTableNodes([])
                    self.setToolVisible(true)
                    self.setSubagentVisible(false)
                    self.toolTextNode.isHidden = body.length == 0
                    for node in self.fileNodes {
                        node.isHidden = true
                    }
                    // Read as one: the title, then what the card shows; with images, which are each their own.
                    self.isAccessibilityElement = toolPhotos.isEmpty
                    self.accessibilityIdentifier = "toolCard"
                    self.accessibilityLabel = [title.string, body.string].filter { !$0.isEmpty }.joined(separator: "\n")
                    if showsAll {
                        self.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show All", actionHandler: { _ in
                            item.interaction.openToolText(item.message)
                            return true
                        })]
                    } else {
                        self.accessibilityCustomActions = nil
                    }
                    self.accessibilityValue = status == .stopped ? "stopped" : isActive ? "working" : status == .failed ? "failed" : "done"

                    self.toolBackgroundNode.backgroundColor = theme.toolCardBackgroundColor
                    let cardFrame = CGRect(origin: CGPoint(x: params.leftInset + freeTextInset - 4.0 + leftShift, y: 0.0), size: cardSize)
                    self.contentFrame = cardFrame
                    animation.animator.updateFrame(layer: self.toolBackgroundNode.layer, frame: cardFrame, completion: nil)

                    let _ = titleApply()
                    animation.animator.updateFrame(layer: self.toolTitleNode.layer, frame: CGRect(origin: CGPoint(x: cardFrame.minX + cardInsets.left, y: cardFrame.minY + cardInsets.top), size: titleLayout.size), completion: nil)
                    let _ = textApply()
                    animation.animator.updateFrame(layer: self.toolTextNode.layer, frame: CGRect(origin: CGPoint(x: cardFrame.minX + cardInsets.left, y: cardFrame.minY + cardInsets.top + titleLayout.size.height + 3.0), size: textLayout.size), completion: nil)
                    let _ = showAllApply()
                    self.toolShowAllNode.isHidden = !showsAll
                    if showsAll {
                        let frame = CGRect(origin: CGPoint(x: cardFrame.minX + cardInsets.left, y: cardFrame.minY + cardInsets.top + titleLayout.size.height + bodyHeight + 6.0), size: showAllLayout.size)
                        animation.animator.updateFrame(layer: self.toolShowAllNode.layer, frame: frame, completion: nil)
                        // The tap's room: the card's width, the line's height and a little.
                        self.toolShowAllFrame = CGRect(x: cardFrame.minX, y: frame.minY - 6.0, width: cardFrame.width, height: frame.height + 6.0 + cardInsets.bottom)
                    } else {
                        self.toolShowAllFrame = nil
                    }
                    self.ensureImageNodes(toolPhotos.count)
                    self.imageAttachmentIds = []
                    let photosOrigin = CGPoint(x: cardFrame.minX + cardInsets.left, y: cardFrame.minY + cardInsets.top + titleLayout.size.height + bodyHeight + showAllHeight + 8.0)
                    for (index, attachment) in toolPhotos.enumerated() {
                        let imageNode = self.imageNodes[index]
                        let (frame, position) = toolMosaic.frames[index]
                        imageNode.setAttachment(attachment.kind, placeholderColor: theme.serviceFillColor)
                        imageNode.isHidden = false
                        imageNode.alpha = attachment.id == self.hiddenAttachmentId ? 0.0 : 1.0
                        imageNode.frame = frame.offsetBy(dx: photosOrigin.x, dy: photosOrigin.y)
                        photoCorners(imageNode.layer, position: position, captioned: false, mergedTop: false, mergedBottom: false, radius: 8.0)
                        self.imageAttachmentIds.append(attachment.id)
                    }
                    for index in toolPhotos.count ..< self.imageNodes.count {
                        self.imageNodes[index].isHidden = true
                    }
                    self.updateToolActivity(isActive: isActive, color: theme.toolCardTextColor, frame: CGRect(x: cardFrame.maxX - cardInsets.right - 14.0, y: cardFrame.minY + cardInsets.top + 1.0, width: 14.0, height: 14.0))
                    let timerMaxX = cardFrame.maxX - cardInsets.right - (isActive ? 22.0 : 0.0)
                    let timerMidY = cardFrame.minY + cardInsets.top + 8.0
                    if let runningSince {
                        let messageId = message.id
                        self.setTimerTick { [weak self] in
                            guard let self else {
                                return
                            }
                            let elapsed = Date().timeIntervalSince(runningSince)
                            let width = self.showTimer(elapsed >= 1.0 ? formatElapsed(elapsed) : nil, color: theme.toolCardTextColor, maxX: timerMaxX, midY: timerMidY)
                            // Past its room (the first second, a new digit): the title makes more.
                            if width + 6.0 > timerReserve + 0.5 {
                                item.interaction.requestRelayout(messageId)
                            }
                        }
                    } else {
                        self.setTimerTick(nil)
                        self.showTimer(finalTime, color: theme.toolCardTextColor, maxX: timerMaxX, midY: timerMidY)
                    }
                    self.layoutContainers(size: layout.contentSize)
                    self.updateSelection(item: item, size: layout.contentSize, animation: animation)
                })
            }
        }
        guard TauTiming.isEnabled else {
            return layoutImpl
        }
        return { item, params, neighbors in
            let start = CACurrentMediaTime()
            let result = layoutImpl(item, params, neighbors)
            TauTiming.log(String(format: "layout %d chars %.1f ms", item.message.text.count, (CACurrentMediaTime() - start) * 1000.0))
            return result
        }
    }

    private var toolActivityNode: ActivityIndicator?

    deinit {
        self.liveTimer?.invalidate()
    }

    /// Runs `tick` now and every second until replaced; nil stops it. A row's apply sets it, so a row that stops
    /// running stops ticking.
    private func setTimerTick(_ tick: (() -> Void)?) {
        self.timerTick = tick
        if let tick {
            tick()
            if self.liveTimer == nil {
                let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
                    self?.timerTick?()
                }, queue: Queue.mainQueue())
                self.liveTimer = timer
                timer.start()
            }
        } else if let timer = self.liveTimer {
            self.liveTimer = nil
            timer.invalidate()
        }
    }

    /// The timer's text, right-aligned to `maxX` and centered on `midY`; nil hides it. Returns its width.
    @discardableResult
    private func showTimer(_ text: String?, color: UIColor, font: UIFont = timerFont, maxX: CGFloat, midY: CGFloat) -> CGFloat {
        guard let text else {
            self.timerNode.isHidden = true
            return 0.0
        }
        self.timerNode.isHidden = false
        self.timerNode.attributedText = NSAttributedString(string: text, font: font, textColor: color)
        let size = self.timerNode.updateLayout(CGSize(width: 200.0, height: 30.0))
        self.timerNode.frame = CGRect(origin: CGPoint(x: maxX - size.width, y: floor(midY - size.height / 2.0)), size: size)
        return size.width
    }

    /// Telegram's activity spinner on a call that is still running.
    private func updateToolActivity(isActive: Bool, color: UIColor, frame: CGRect) {
        if isActive {
            let node: ActivityIndicator
            if let current = self.toolActivityNode {
                node = current
            } else {
                node = ActivityIndicator(type: .custom(color, 14.0, 1.5, true))
                self.toolActivityNode = node
                self.contentNode.addSubnode(node)
            }
            node.type = .custom(color, 14.0, 1.5, true)
            node.frame = frame
        } else if let node = self.toolActivityNode {
            self.toolActivityNode = nil
            node.removeFromSupernode()
        }
    }

    private func setSubagentVisible(_ visible: Bool) {
        self.subagentQuoteNode.isHidden = !visible
        self.subagentTaskNode.isHidden = !visible
        if !visible {
            self.subagentMetaNode.isHidden = true
            self.subagentArrowNode.isHidden = true
            self.subagentAnswerNode?.isHidden = true
        }
    }

    private func setToolVisible(_ visible: Bool) {
        if !visible, let node = self.toolActivityNode {
            self.toolActivityNode = nil
            node.removeFromSupernode()
            self.setSubagentVisible(false)
        } else if !visible {
            self.setSubagentVisible(false)
        }
        self.toolBackgroundNode.isHidden = !visible
        self.toolTitleNode.isHidden = !visible
        self.toolTextNode.isHidden = !visible
        if !visible {
            self.toolShowAllNode.isHidden = true
            self.toolShowAllFrame = nil
        }
    }

    /// ChatMessageTextBubbleContentNode.updateSearchTextHighlightState: the matched words' rects, behind the text.
    private func updateSearchHighlight() {
        var index = 0
        if let item = self.item, let terms = item.highlightTerms, !terms.isEmpty {
            let color = item.theme.presentationTheme.chat.message.incoming.textHighlightColor
            for node in self.textNodes where node.supernode != nil && !node.isHidden {
                guard let string = node.cachedLayout?.attributedString?.string else {
                    continue
                }
                var rects: [CGRect] = []
                for range in SearchText.ranges(in: string, terms: terms) {
                    rects.append(contentsOf: node.rangeRects(in: range)?.rects ?? [])
                }
                guard !rects.isEmpty else {
                    continue
                }
                let highlight: LinkHighlightingNode
                if index < self.searchHighlightNodes.count {
                    highlight = self.searchHighlightNodes[index]
                } else {
                    highlight = LinkHighlightingNode(color: color)
                    self.searchHighlightNodes.append(highlight)
                }
                if highlight.supernode !== node.supernode {
                    node.supernode?.insertSubnode(highlight, belowSubnode: node)
                }
                highlight.frame = node.frame
                highlight.updateRects(rects.map { $0.insetBy(dx: -1.0, dy: 0.0) }, color: color)
                index += 1
            }
        }
        for node in self.searchHighlightNodes[index...] {
            node.removeFromSupernode()
        }
        self.searchHighlightNodes.removeSubrange(index...)
    }

    /// A few quoted words (MarkdownText.inlineQuoteKey) on a tint of the quote's color, as the field shows them.
    private func updateInlineQuoteMarks() {
        var index = 0
        // Not over words a streaming answer has not revealed yet.
        if let item = self.item, item.message.tool == nil, !item.isStreaming {
            let color = (item.message.role == .user ? item.theme.presentationTheme.chat.message.outgoing.primaryTextColor : item.theme.accentColor).withMultipliedAlpha(0.16)
            for node in self.textNodes where node.supernode != nil && !node.isHidden {
                guard let string = node.cachedLayout?.attributedString, string.length > 0 else {
                    continue
                }
                var rects: [CGRect] = []
                string.enumerateAttribute(MarkdownText.inlineQuoteKey, in: NSRange(location: 0, length: string.length), options: []) { value, range, _ in
                    if value != nil {
                        rects.append(contentsOf: node.rangeRects(in: range)?.rects ?? [])
                    }
                }
                guard !rects.isEmpty else {
                    continue
                }
                let mark: LinkHighlightingNode
                if index < self.inlineQuoteNodes.count {
                    mark = self.inlineQuoteNodes[index]
                } else {
                    mark = LinkHighlightingNode(color: color)
                    mark.isUserInteractionEnabled = false
                    mark.innerRadius = 4.0
                    mark.outerRadius = 4.0
                    mark.useModernPathCalculation = true
                    self.inlineQuoteNodes.append(mark)
                }
                if mark.supernode !== node.supernode {
                    node.supernode?.insertSubnode(mark, belowSubnode: node)
                }
                mark.frame = node.frame
                mark.updateRects(rects.map { $0.insetBy(dx: -2.0, dy: 0.0) }, color: color)
                index += 1
            }
        }
        for node in self.inlineQuoteNodes[index...] {
            node.removeFromSupernode()
        }
        self.inlineQuoteNodes.removeSubrange(index...)
    }

    private func setTextNodes(_ nodes: [InteractiveTextNode]) {
        for node in self.textNodes where !nodes.contains(where: { $0 === node }) {
            node.removeFromSupernode()
        }
        for node in nodes where node.supernode == nil {
            node.isUserInteractionEnabled = false
            self.contentNode.insertSubnode(node, belowSubnode: self.dateNode)
        }
        self.textNodes = nodes
    }

    /// Horizontal scrollers of code blocks that do not wrap, by the text node each holds.
    private var codeScrollers: [ObjectIdentifier: ASScrollNode] = [:]
    private var codeScrollFades: [ObjectIdentifier: CodeScrollFade] = [:]

    private func codeScroller(for node: InteractiveTextNode) -> ASScrollNode {
        let key = ObjectIdentifier(node)
        if let scroller = self.codeScrollers[key] {
            if node.supernode !== scroller {
                scroller.addSubnode(node)
            }
            return scroller
        }
        let scroller = ASScrollNode()
        scroller.view.showsHorizontalScrollIndicator = false
        scroller.view.showsVerticalScrollIndicator = false
        scroller.view.alwaysBounceVertical = false
        scroller.view.scrollsToTop = false
        scroller.view.contentInsetAdjustmentBehavior = .never
        // As Telegram's horizontal lists: over the block only a swipe from the screen's edge goes back, and none
        // while it is scrolled away from its start.
        scroller.view.disablesInteractiveTransitionGestureRecognizer = true
        scroller.view.disablesInteractiveTransitionGestureRecognizerNow = { [weak scroller] in
            return (scroller?.view.contentOffset.x ?? 0.0) > 0.0
        }
        self.contentNode.insertSubnode(scroller, belowSubnode: self.dateNode)
        scroller.addSubnode(node)
        self.codeScrollers[key] = scroller
        let fade = CodeScrollFade()
        scroller.view.delegate = fade
        self.codeScrollFades[key] = fade
        return scroller
    }

    private func removeCodeScrollers(keeping nodes: [InteractiveTextNode]) {
        let kept = Set(nodes.map(ObjectIdentifier.init))
        for (key, scroller) in self.codeScrollers where !kept.contains(key) {
            scroller.removeFromSupernode()
            self.codeScrollers[key] = nil
            self.codeScrollFades[key] = nil
        }
    }

    // MARK: - Status

    private func hideStatus() {
        for node in [self.clockFrameNode, self.clockMinNode, self.checkSentNode, self.checkReadNode, self.failedNode] {
            node.isHidden = true
        }
    }

    /// ChatMessageDateAndStatusNode's outgoing status, placed as it places it after the time, and the failed badge.
    private func updateStatus(item: ChatMessageItem, dateFrame: CGRect, backgroundFrame: CGRect, failedInset: CGFloat, animation: ListViewItemUpdateAnimation) {
        let theme = item.theme.presentationTheme
        let key = "\(theme.chat.message.outgoingCheckColor.argb)-\(theme.chat.message.outgoing.pendingActivityColor.argb)"
        if self.statusImagesKey != key {
            self.statusImagesKey = key
            self.checkSentNode.image = generateCheckImage(partial: false, color: theme.chat.message.outgoingCheckColor, width: 11.0)
            self.checkReadNode.image = generateCheckImage(partial: true, color: theme.chat.message.outgoingCheckColor, width: 11.0)
            self.clockFrameNode.image = generateClockFrameImage(color: theme.chat.message.outgoing.pendingActivityColor)
            self.clockMinNode.image = generateClockMinImage(color: theme.chat.message.outgoing.pendingActivityColor)
            self.failedNode.image = PresentationResourcesChat.chatBubbleDeliveryFailedIcon(theme)
        }
        let wasFailed = !self.failedNode.isHidden
        switch item.message.delivery {
        case .sending:
            for node in [self.checkSentNode, self.checkReadNode, self.failedNode] {
                node.isHidden = true
            }
            let center = CGPoint(x: dateFrame.minX + dateFrame.width + 8.5, y: dateFrame.minY + 7.5)
            for node in [self.clockFrameNode, self.clockMinNode] {
                node.isHidden = false
                node.bounds = CGRect(origin: CGPoint(), size: CGSize(width: 11.0, height: 11.0))
                node.position = center
            }
            addClockAnimation(self.clockFrameNode.layer, duration: 6.0)
            addClockAnimation(self.clockMinNode.layer, duration: 1.0)
        case .delivered:
            let showChecks = !self.checkSentNode.isHidden
            for node in [self.clockFrameNode, self.clockMinNode, self.failedNode] {
                node.isHidden = true
                node.layer.removeAllAnimations()
            }
            let checkSize = CGSize(width: 11.0, height: 9.0)
            let sentFrame = CGRect(origin: CGPoint(x: dateFrame.maxX + 1.0, y: dateFrame.minY + 3.0), size: checkSize)
            let readFrame = CGRect(origin: CGPoint(x: dateFrame.maxX + 7.0, y: dateFrame.minY + 3.0), size: checkSize)
            self.checkSentNode.isHidden = false
            self.checkReadNode.isHidden = false
            if showChecks {
                animation.animator.updateFrame(layer: self.checkSentNode.layer, frame: sentFrame, completion: nil)
                animation.animator.updateFrame(layer: self.checkReadNode.layer, frame: readFrame, completion: nil)
            } else {
                self.checkSentNode.frame = sentFrame
                self.checkReadNode.frame = readFrame
                if animation.isAnimated {
                    // The checks pop in, as Telegram's do when a message is read.
                    for node in [self.checkSentNode, self.checkReadNode] {
                        node.layer.animateScale(from: 1.3, to: 1.0, duration: 0.1)
                        node.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
                    }
                }
            }
        case .failed:
            for node in [self.clockFrameNode, self.clockMinNode, self.checkSentNode, self.checkReadNode] {
                node.isHidden = true
                node.layer.removeAllAnimations()
            }
            let size = CGSize(width: 22.0, height: 22.0)
            let frame = CGRect(origin: CGPoint(x: backgroundFrame.maxX + failedInset - size.width, y: backgroundFrame.maxY - size.height), size: size)
            self.failedNode.isHidden = false
            self.failedNode.frame = frame
            if !wasFailed && animation.isAnimated {
                self.failedNode.layer.animatePosition(from: CGPoint(x: failedInset, y: 0.0), to: CGPoint(), duration: 0.3, additive: true)
                self.failedNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
    }

    private var waitingNode: ChatWaitingNode?

    private func setTableNodes(_ nodes: [ChatTableNode]) {
        if let node = self.waitingNode {
            self.waitingNode = nil
            node.removeFromSupernode()
        }
        if let node = self.waitingLabelNode {
            self.waitingLabelNode = nil
            node.removeFromSupernode()
        }
        self.retryButtonFrame = nil
        if let node = self.serviceTauNode {
            self.serviceTauNode = nil
            node.removeFromSupernode()
        }
        // Rows with a time set it again after this, and rows read as one element say so.
        self.setTimerTick(nil)
        self.timerNode.isHidden = true
        self.isAccessibilityElement = false
        self.accessibilityIdentifier = nil
        self.subagentAnswerNode?.layer.mask = nil
        for node in self.tableNodes where !nodes.contains(where: { $0 === node }) {
            node.removeFromSupernode()
        }
        for node in nodes where node.supernode == nil {
            self.contentNode.insertSubnode(node, belowSubnode: self.dateNode)
        }
        self.tableNodes = nodes
    }

    /// Telegram's selection check (ChatMessageSelectionNode, copied): it covers the row, so a tap anywhere toggles the
    /// message, and slides in from the left as in ChatMessageBubbleItemNode.updateSelectionState.
    private func updateSelection(item: ChatMessageItem, size: CGSize, animation: ListViewItemUpdateAnimation) {
        let frame = CGRect(origin: CGPoint(), size: size)
        if let selected = item.selection {
            if let selectionNode = self.selectionNode {
                selectionNode.updateSelected(selected, animated: animation.isAnimated)
                animation.animator.updateFrame(layer: selectionNode.layer, frame: frame, completion: nil)
                selectionNode.updateLayout(size: size, leftInset: 0.0)
            } else {
                let messageId = item.message.id
                let selectionNode = ChatMessageSelectionNode(wallpaper: item.theme.wallpaper, theme: item.theme.presentationTheme, toggle: { [weak self] _ in
                    self?.item?.interaction.toggleSelection(messageId)
                })
                selectionNode.frame = frame
                selectionNode.updateLayout(size: size, leftInset: 0.0)
                selectionNode.updateSelected(selected, animated: false)
                self.addSubnode(selectionNode)
                self.selectionNode = selectionNode
                if animation.isAnimated {
                    selectionNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                    selectionNode.layer.animatePosition(from: CGPoint(x: -42.0, y: 0.0), to: CGPoint(), duration: 0.2, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, additive: true)
                }
            }
        } else if let selectionNode = self.selectionNode {
            self.selectionNode = nil
            if animation.isAnimated {
                selectionNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak selectionNode] _ in
                    selectionNode?.removeFromSupernode()
                })
                selectionNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: -42.0, y: 0.0), duration: 0.2, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, removeOnCompletion: false, additive: true)
            } else {
                selectionNode.removeFromSupernode()
            }
        }
    }

    // MARK: - Streaming reveal (after ChatMessageTextBubbleContentNode.updateTextRevealAnimation)

    private func updateReveal(item: ChatMessageItem, totalLength: Int) {
        let now = CACurrentMediaTime()
        if item.isStreaming {
            if let controller = self.revealController {
                controller.observeUpdate(latestLength: totalLength, at: now)
            } else {
                let carried = min(totalLength, item.interaction.revealProgress.with { $0[item.message.id] } ?? 0)
                let controller = TextRevealController(initialRevealedCount: carried, initialLength: carried)
                controller.observeUpdate(latestLength: totalLength, at: now)
                self.revealController = controller
            }
        } else if let controller = self.revealController {
            controller.finalize(finalLength: totalLength)
        } else {
            self.applyReveal(nil)
            return
        }
        self.applyReveal(Int(self.revealController?.revealedCount ?? 0), force: true)

        guard self.revealLink == nil else {
            return
        }
        self.revealLink = SharedDisplayLinkDriver.shared.add { [weak self] _ in
            guard let self, let controller = self.revealController, let item = self.item else {
                self?.revealLink = nil
                return
            }
            let previous = Int(controller.revealedCount)
            let (count, isComplete) = controller.tick(now: CACurrentMediaTime())
            let id = item.message.id
            let _ = item.interaction.revealProgress.modify { progress in
                var progress = progress
                if isComplete {
                    progress.removeValue(forKey: id)
                } else {
                    progress[id] = count
                }
                return progress
            }
            if isComplete {
                self.revealController = nil
                self.revealLink = nil
                self.applyReveal(nil)
                item.interaction.requestRelayout(item.message.id)
                return
            }
            if count != previous {
                self.applyReveal(count)
                if contentHeight(self.laidOutBlocks, revealed: previous) != contentHeight(self.laidOutBlocks, revealed: count) {
                    item.interaction.requestRelayout(item.message.id)
                }
            }
        }
    }

    /// Shows `revealed` characters across the blocks; nil shows everything.
    /// `force` after a layout: segments it made start with nothing hidden, so they take the count even where it is the same.
    private func applyReveal(_ revealed: Int?, force: Bool = false) {
        var textCursor = 0
        var tableCursor = 0
        for block in self.laidOutBlocks {
            switch block {
            case let .text(start, length, _, _):
                guard textCursor < self.textNodes.count else {
                    continue
                }
                let node = self.textNodes[textCursor]
                textCursor += 1
                // Until the reveal ends every block keeps a count, its whole length once the reveal has passed it. A
                // block the reveal caught up with and that then grew again went from no count back to one, and its
                // mask came back animated: what was on screen faded out and in again.
                if let revealed {
                    let count = min(length, max(0, revealed - start))
                    if force || node.revealCharacterCount != count {
                        node.updateRevealCharacterCount(count: count, animated: true)
                    }
                } else if node.revealCharacterCount != nil {
                    node.updateRevealCharacterCount(count: nil, animated: false)
                }
            case let .table(start, _, _, _):
                guard tableCursor < self.tableNodes.count else {
                    continue
                }
                let node = self.tableNodes[tableCursor]
                tableCursor += 1
                let visible = revealed.map { $0 > start } ?? true
                if visible != (node.alpha > 0.0) {
                    ContainedViewLayoutTransition.animated(duration: 0.25, curve: .easeInOut).updateAlpha(node: node, alpha: visible ? 1.0 : 0.0)
                }
            }
        }
    }

    private func stopReveal() {
        self.revealController = nil
        self.revealLink = nil
        for node in self.textNodes where node.revealCharacterCount != nil {
            node.updateRevealCharacterCount(count: nil, animated: false)
        }
    }
}

/// A user bubble filled with a gradient that spans the whole screen, masked to the bubble shape: as in Telegram, a
/// bubble's color depends on where it is on screen and shifts as the chat scrolls.
final class GradientBubbleNode: ASDisplayNode {
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CALayer()
    private var visualTop: CGFloat = 0.0
    private var containerSize = CGSize(width: 1.0, height: 1.0)

    override init() {
        super.init()
        self.isLayerBacked = true
    }

    override func didLoad() {
        super.didLoad()
        self.layer.addSublayer(self.gradientLayer)
    }

    /// A single-color bubble: the stretchable image itself, with no mask and so no offscreen pass, as Telegram draws
    /// bubbles.
    func update(solid image: UIImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.gradientLayer.isHidden = true
        self.layer.mask = nil
        if self.layer.contents as AnyObject? !== image.cgImage {
            self.layer.contents = image.cgImage
            self.layer.contentsScale = image.scale
            let insets = image.capInsets
            let size = image.size
            self.layer.contentsCenter = CGRect(x: insets.left / size.width, y: insets.top / size.height, width: 1.0 / size.width, height: 1.0 / size.height)
        }
        CATransaction.commit()
    }

    func update(mask: UIImage, colors: [UIColor]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer.contents = nil
        self.gradientLayer.isHidden = false
        if self.layer.mask !== self.maskLayer {
            self.layer.mask = self.maskLayer
        }
        self.gradientLayer.colors = colors.map(\.cgColor)
        if self.maskLayer.contents as AnyObject? !== mask.cgImage {
            self.maskLayer.contents = mask.cgImage
            self.maskLayer.contentsScale = mask.scale
            let insets = mask.capInsets
            let size = mask.size
            self.maskLayer.contentsCenter = CGRect(x: insets.left / size.width, y: insets.top / size.height, width: 1.0 / size.width, height: 1.0 / size.height)
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.maskLayer.frame = self.bounds
        self.layoutGradient()
        CATransaction.commit()
    }

    func updateAbsolutePosition(visualTop: CGFloat, containerSize: CGSize) {
        self.visualTop = visualTop
        self.containerSize = containerSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layoutGradient()
        CATransaction.commit()
    }

    /// The gradient layer is only as big as the bubble; its start and end points place the screen-high gradient so that
    /// the bubble shows its slice of it. A screen-sized layer per bubble, masked, would cost a full-screen offscreen pass
    /// per bubble on every frame of a scroll or a swipe back.
    private func layoutGradient() {
        let bounds = self.bounds
        self.gradientLayer.frame = bounds
        guard bounds.height > 0.0 else {
            return
        }
        let top = self.visualTop + self.frame.minY
        let screenHeight = max(self.containerSize.height, 1.0)
        self.gradientLayer.startPoint = CGPoint(x: 0.5, y: -top / bounds.height)
        self.gradientLayer.endPoint = CGPoint(x: 0.5, y: (screenHeight - top) / bounds.height)
    }
}

/// A file in a user bubble: an icon, the name and the size.
/// A file of a message, as Telegram's ChatMessageInteractiveFileNode shows a document: a 44 pt circle (its
/// SemanticStatusNode, in the message's media color) with a download arrow, the progress of a transfer, or the
/// document icon once the file is here; the name, and the size, or how much of it came so far. Followed as its
/// transfer goes (Server/FileTransfer.swift).
final class FileAttachmentNode: ASDisplayNode {
    private var statusNode: SemanticStatusNode?
    private let nameNode = ImmediateTextNode()
    private let sizeNode = ImmediateTextNode()
    private var statusDisposable: Disposable?
    private(set) var file: FileAttachment?
    private(set) var status: FileTransferStatus = .remote
    private var colors: (name: UIColor, size: UIColor, fill: UIColor, icon: UIColor, document: UIImage?)?
    private var fontSize: CGFloat = 17.0

    static func titleFont(_ fontSize: CGFloat) -> UIFont {
        return Font.regular(floor(fontSize * 16.0 / 17.0))
    }

    static func sizeFont(_ fontSize: CGFloat) -> UIFont {
        return Font.with(size: floor(fontSize * 13.0 / 17.0), design: .regular, weight: .regular, traits: [.monospacedNumbers])
    }

    /// ChatMessageInteractiveFileNode's: the circle, 8 pt, then the text, at least as tall as the circle.
    static func measure(_ file: FileAttachment, fontSize: CGFloat, maxWidth: CGFloat) -> CGSize {
        let nameWidth = ceil((file.name as NSString).size(withAttributes: [.font: FileAttachmentNode.titleFont(fontSize)]).width)
        let sizeWidth = ceil(("0000.0 MB / 0000.0 MB" as NSString).size(withAttributes: [.font: FileAttachmentNode.sizeFont(fontSize)]).width)
        return CGSize(width: min(maxWidth, 52.0 + max(nameWidth, min(sizeWidth, 120.0))), height: 44.0)
    }

    override init() {
        super.init()
        self.nameNode.maximumNumberOfLines = 1
        self.nameNode.truncationMode = .byTruncatingMiddle
        self.nameNode.displaysAsynchronously = false
        self.sizeNode.maximumNumberOfLines = 1
        self.sizeNode.displaysAsynchronously = false
        self.addSubnode(self.nameNode)
        self.addSubnode(self.sizeNode)
    }

    deinit {
        self.statusDisposable?.dispose()
    }

    /// `incoming`: the agent's, in its colors; else the user's, in the outgoing bubble's.
    func update(file: FileAttachment, incoming: Bool, theme: TauTheme, status: Signal<FileTransferStatus, NoError>, width: CGFloat) {
        let message = incoming ? theme.presentationTheme.chat.message.incoming : theme.presentationTheme.chat.message.outgoing
        let fill = message.mediaActiveControlColor
        // Telegram's: white on an incoming circle; cut out of an outgoing one, so the bubble shows through.
        let icon: UIColor = incoming && fill.rgb != 0xffffff ? .white : .clear
        let document = generateTintedImage(image: UIImage(bundleImageName: "Chat/Message/RadialProgressIconDocument"), color: .black)
        self.colors = (message.fileTitleColor, message.fileDescriptionColor, fill, icon, document)
        self.fontSize = theme.fontSize
        let changed = self.file?.serverId != file.serverId || self.file?.transferKey != file.transferKey || self.file?.name != file.name
        self.file = file
        if self.statusNode == nil {
            let statusNode = SemanticStatusNode(backgroundNodeColor: fill, foregroundNodeColor: icon)
            statusNode.displaysAsynchronously = false
            self.statusNode = statusNode
            self.addSubnode(statusNode)
        }
        self.statusNode?.backgroundNodeColor = fill
        self.statusNode?.foregroundNodeColor = icon
        self.statusNode?.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
        self.nameNode.attributedText = NSAttributedString(string: file.name, font: FileAttachmentNode.titleFont(theme.fontSize), textColor: message.fileTitleColor)
        self.isAccessibilityElement = true
        self.accessibilityLabel = file.name
        self.accessibilityTraits = .button
        let textWidth = max(10.0, width - 52.0)
        let nameSize = self.nameNode.updateLayout(CGSize(width: textWidth, height: 24.0))
        self.nameNode.frame = CGRect(origin: CGPoint(x: 52.0, y: 2.0), size: nameSize)
        self.layoutSize(width: width)
        if changed || self.statusDisposable == nil {
            self.statusDisposable?.dispose()
            var first = true
            self.statusDisposable = (status |> deliverOnMainQueue).start(next: { [weak self] status in
                guard let self else {
                    return
                }
                self.apply(status, animated: !first)
                first = false
            })
        } else {
            self.apply(self.status, animated: false)
        }
    }

    private var width: CGFloat = 0.0

    private func layoutSize(width: CGFloat) {
        self.width = width
        let textWidth = max(10.0, width - 52.0)
        let sizeSize = self.sizeNode.updateLayout(CGSize(width: textWidth, height: 20.0))
        self.sizeNode.frame = CGRect(origin: CGPoint(x: 52.0, y: 24.0), size: sizeSize)
    }

    private func apply(_ status: FileTransferStatus, animated: Bool) {
        guard let file = self.file, let colors = self.colors else {
            return
        }
        self.status = status
        let total = fileSizeString(file.size)
        var sizeText = total
        let state: SemanticStatusNodeState
        switch status {
        case .remote:
            state = .download
        case let .downloading(progress), let .uploading(progress):
            // As Telegram's "1.2 MB / 4.8 MB" while it moves.
            sizeText = "\(fileSizeString(Int64(Double(file.size) * progress))) / \(total)"
            state = .progress(value: CGFloat(max(0.027, progress)), cancelEnabled: true, appearance: nil, animateRotation: true)
        case .local:
            state = colors.document.map { .customIcon($0) } ?? .none
        }
        self.sizeNode.attributedText = NSAttributedString(string: sizeText, font: FileAttachmentNode.sizeFont(self.fontSize), textColor: colors.size)
        self.layoutSize(width: self.width)
        self.statusNode?.transitionToState(state, animated: animated)
    }
}

/// The word around `index`, as TextSelectionNode's long press finds it (CFStringTokenizer); the character alone
/// where no word is, such as in punctuation or space.
private func wordRange(in string: NSString, at index: Int) -> NSRange {
    let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, string as CFString, CFRangeMake(0, string.length), UInt(kCFStringTokenizerUnitWord), CFLocaleCopyCurrent())
    if !CFStringTokenizerGoToTokenAtIndex(tokenizer, index).isEmpty {
        let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        if range.location <= index && range.location + range.length > index {
            return NSRange(location: range.location, length: range.length)
        }
    }
    return string.rangeOfComposedCharacterSequence(at: index)
}

/// A size as Telegram's dataSizeString writes one: 25 B, 812 KB, 2.9 MB, 1.2 GB.
func fileSizeString(_ bytes: Int64) -> String {
    let value = Double(bytes)
    if bytes < 1024 {
        return "\(bytes) B"
    }
    if bytes < 1024 * 1024 {
        return String(format: "%.1f KB", value / 1024.0).replacingOccurrences(of: ".0 ", with: " ")
    }
    if bytes < 1024 * 1024 * 1024 {
        return String(format: "%.1f MB", value / 1024.0 / 1024.0).replacingOccurrences(of: ".0 ", with: " ")
    }
    return String(format: "%.1f GB", value / 1024.0 / 1024.0 / 1024.0).replacingOccurrences(of: ".0 ", with: " ")
}

private let timerFont = Font.with(size: 12.0, traits: .monospacedNumbers)

private func timerWidth(_ text: String) -> CGFloat {
    return ceil(NSAttributedString(string: text, font: timerFont, textColor: .black).size().width)
}

/// A time while it runs, a second at a time: 8s, 42s, 1m 05s, 1h 03m.
func formatElapsed(_ elapsed: TimeInterval) -> String {
    let seconds = max(0, Int(elapsed))
    if seconds < 60 {
        return "\(seconds)s"
    }
    if seconds < 3600 {
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }
    return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
}

/// A run's length as a stopwatch reads it: 4.2s, 38s, 2m 05s, 1h 03m.
func formatDuration(_ duration: TimeInterval) -> String {
    if duration < 10.0 {
        return String(format: "%.1fs", duration)
    }
    let seconds = Int(duration.rounded())
    if seconds < 60 {
        return "\(seconds)s"
    }
    if seconds < 3600 {
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }
    return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
}

func messageTimeString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private let diffAddedLight = UIColor(rgb: 0x248a3d)
private let diffAddedDark = UIColor(rgb: 0x30d158)
private let diffRemovedLight = UIColor(rgb: 0xd70015)
private let diffRemovedDark = UIColor(rgb: 0xff6961)

/// A path as the card shows it: its last two components, the whole path once expanded.
private func shortPath(_ path: String, isExpanded: Bool) -> String {
    if isExpanded {
        return path
    }
    let components = path.split(separator: "/")
    return components.count <= 2 ? path : components.suffix(2).joined(separator: "/")
}

/// The first or last `count` lines, with an ellipsis line where the rest was cut.
/// Notes whether a card's body was cut: an expanded card that was offers Show All, the whole of it in a viewer.
final class ClipTracker {
    var clipped = false
}

/// An expanded card's lines of each part (a command, an output, a file, a diff, a script); the rest is in its viewer.
let expandedToolLines = 200

private func clippedLines(_ text: String, count: Int, fromStart: Bool, cuts: ClipTracker? = nil) -> String {
    let lines = text.components(separatedBy: "\n")
    guard lines.count > count else {
        return text
    }
    cuts?.clipped = true
    if fromStart {
        var head = Array(lines.prefix(count))
        while let last = head.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            head.removeLast()
        }
        return head.joined(separator: "\n") + "\n…"
    }
    return "…\n" + lines.suffix(count).joined(separator: "\n")
}

/// What a tool card says: the tool, what it works on, and a body made for the tool: a command with the end of its
/// output, a file's first lines highlighted by its language, a diff in red and green.
/// Expanded, each part shows `limit` lines (`Int.max`: the viewer's whole text), and `cuts` notes whether one was cut.
func toolCardContent(name: String, tool: ToolCallInfo?, fallbackText: String, isExpanded: Bool, isActive: Bool, isDark: Bool, textColor: UIColor, titleColor: UIColor, accentColor: UIColor, maxWidth: CGFloat, limit: Int = expandedToolLines, cuts: ClipTracker? = nil) -> (String, String, NSMutableAttributedString) {
    let body = NSMutableAttributedString()
    var output = (tool?.output ?? fallbackText).trimmingCharacters(in: .whitespacesAndNewlines)
    let codeFont = Font.monospace(12.0)
    // pi wraps a tool's error in <harness> tags for the model; the card shows the message.
    if output.hasPrefix("<harness>") {
        output = output.replacingOccurrences(of: "<harness>", with: "").replacingOccurrences(of: "</harness>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if case let .code(script, error) = tool?.detail {
        return ("Code", codeCallCount(tool?.nested.count ?? 0), codeCardBody(script: script, calls: tool?.nested ?? [], output: output, error: error, isExpanded: isExpanded, isActive: isActive, errorColor: isDark ? diffRemovedDark : diffRemovedLight, textColor: textColor, titleColor: titleColor, maxWidth: maxWidth, limit: limit, cuts: cuts))
    }
    if tool?.status == .failed, !output.isEmpty {
        let errorColor = isDark ? diffRemovedDark : diffRemovedLight
        switch tool?.detail ?? .none {
        case let .read(path):
            body.append(NSAttributedString(string: clippedLines(output, count: isExpanded ? limit : 4, fromStart: true, cuts: isExpanded ? cuts : nil), font: codeFont, textColor: errorColor))
            return ("Read", shortPath(tool?.summary ?? path, isExpanded: isExpanded), body)
        case let .bash(command):
            body.append(MarkdownText.code("$ " + clippedLines(command, count: isExpanded ? limit : 3, fromStart: true, cuts: isExpanded ? cuts : nil), language: "bash", font: codeFont, textColor: titleColor))
            body.append(NSAttributedString(string: "\n" + clippedLines(output, count: isExpanded ? limit : 6, fromStart: false, cuts: isExpanded ? cuts : nil), font: codeFont, textColor: errorColor))
            return ("Bash", "", body)
        default:
            break
        }
    }
    switch tool?.detail ?? .none {
    case let .bash(command):
        let shownCommand = clippedLines(command.trimmingCharacters(in: .whitespacesAndNewlines), count: isExpanded ? limit : 3, fromStart: true, cuts: isExpanded ? cuts : nil)
        body.append(MarkdownText.code("$ " + shownCommand, language: "bash", font: codeFont, textColor: titleColor))
        if !output.isEmpty {
            body.append(NSAttributedString(string: "\n"))
            // A command says how it went at the end.
            body.append(NSAttributedString(string: clippedLines(output, count: isExpanded ? limit : (isActive ? 4 : 6), fromStart: false, cuts: isExpanded ? cuts : nil), font: codeFont, textColor: textColor))
        }
        return ("Bash", "", body)
    case let .read(path):
        // An image read: the card shows it, and what pi said of it, as a note.
        if tool?.images.isEmpty == false {
            if !output.isEmpty {
                body.append(NSAttributedString(string: clippedLines(output, count: isExpanded ? limit : 2, fromStart: true, cuts: isExpanded ? cuts : nil), font: Font.regular(13.0), textColor: textColor))
            }
            return ("Read", shortPath(tool?.summary ?? path, isExpanded: isExpanded), body)
        }
        if !output.isEmpty {
            let lines = output.components(separatedBy: "\n").count
            body.append(MarkdownText.code(clippedLines(output, count: isExpanded ? limit : 5, fromStart: true, cuts: isExpanded ? cuts : nil), language: MarkdownText.language(forPath: path), font: codeFont, textColor: textColor))
            return ("Read", shortPath(tool?.summary ?? path, isExpanded: isExpanded) + (isExpanded ? "" : "  \(lines) lines"), body)
        }
        return ("Read", shortPath(tool?.summary ?? path, isExpanded: isExpanded), body)
    case let .write(path, content):
        let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
        body.append(MarkdownText.code(clippedLines(content, count: isExpanded ? limit : 6, fromStart: true, cuts: isExpanded ? cuts : nil), language: MarkdownText.language(forPath: path), font: codeFont, textColor: textColor))
        if tool?.status == .failed, !output.isEmpty {
            body.append(NSAttributedString(string: "\n" + output, font: codeFont, textColor: isDark ? diffRemovedDark : diffRemovedLight))
        }
        return ("Write", shortPath(path, isExpanded: isExpanded) + "  \(lines) lines", body)
    case let .edit(path, diff):
        let added = isDark ? diffAddedDark : diffAddedLight
        let removed = isDark ? diffRemovedDark : diffRemovedLight
        let lines = diff.components(separatedBy: "\n")
        let addedCount = lines.filter { $0.hasPrefix("+") }.count
        let removedCount = lines.filter { $0.hasPrefix("-") }.count
        let shown = isExpanded ? lines.prefix(limit) : lines.prefix(10)
        for (index, line) in shown.enumerated() {
            if index > 0 {
                body.append(NSAttributedString(string: "\n"))
            }
            let color = line.hasPrefix("+") ? added : (line.hasPrefix("-") ? removed : textColor)
            body.append(NSAttributedString(string: line, font: codeFont, textColor: color))
        }
        if shown.count < lines.count {
            body.append(NSAttributedString(string: "\n…", font: codeFont, textColor: textColor))
            if isExpanded {
                cuts?.clipped = true
            }
        }
        if tool?.status == .failed, !output.isEmpty {
            body.append(NSAttributedString(string: "\n" + output, font: codeFont, textColor: removed))
        }
        return ("Edit", shortPath(path, isExpanded: isExpanded) + "  +\(addedCount) −\(removedCount)", body)
    case .code:
        // Made above.
        return (name, "", body)
    case .none:
        if tool?.childConversationId != nil {
            // An earlier, foreground subagent: the spinner says it works; once done, a link to its transcript.
            if !(isActive || tool?.childBusy == true) {
                body.append(NSAttributedString(string: "Open subagent ›\n", font: Font.medium(14.0), textColor: accentColor))
            }
        }
        if !output.isEmpty {
            // Commands say how they went at the end; answers are read from the start.
            let fromStart = name == "subagent"
            body.append(NSAttributedString(string: clippedLines(output, count: isExpanded ? limit : (isActive ? 4 : 6), fromStart: fromStart, cuts: isExpanded ? cuts : nil), font: toolFont, textColor: textColor))
        }
        return (name == "subagent" ? "Subagent" : name, tool?.summary ?? "", body)
    }
}

/// "3 calls", as the title of a script's card counts them; nothing before the first.
private func codeCallCount(_ count: Int) -> String {
    return count == 0 ? "" : (count == 1 ? "1 call" : "\(count) calls")
}

/// A tool's name as its own card's title says it.
private func toolTitle(_ name: String) -> String {
    switch name {
    case "bash":
        return "Bash"
    case "read":
        return "Read"
    case "write":
        return "Write"
    case "edit":
        return "Edit"
    case "send_file":
        return "Send"
    case "subagent":
        return "Subagent"
    default:
        return name
    }
}

/// A code mode script's card (docs/codemode.md): the script, highlighted; a line for each call it made, as the call's
/// own card would title it, the one running bright and those done quieter; then what it wrote, or its error. Folded,
/// the script's first lines, its last three calls (the one at work among them), and the start of its output.
private func codeCardBody(script: String, calls: [NestedToolCall], output: String, error: String?, isExpanded: Bool, isActive: Bool, errorColor: UIColor, textColor: UIColor, titleColor: UIColor, maxWidth: CGFloat, limit: Int, cuts: ClipTracker?) -> NSMutableAttributedString {
    let body = NSMutableAttributedString()
    let codeFont = Font.monospace(12.0)
    let nameFont = Font.semibold(12.0)
    let spacer = NSAttributedString(string: "\n", font: Font.regular(6.0), textColor: textColor)
    func section() {
        if body.length > 0 {
            body.append(NSAttributedString(string: "\n"))
            body.append(spacer)
        }
    }
    // An options line says how long it may run and how much it may write: nothing to read here.
    var lines = script.components(separatedBy: "\n")
    if let first = lines.first, first.hasPrefix("// @options:") {
        lines.removeFirst()
    }
    let source = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if !source.isEmpty {
        body.append(MarkdownText.code(clippedLines(source, count: isExpanded ? limit : 3, fromStart: true, cuts: isExpanded ? cuts : nil), language: "javascript", font: codeFont, textColor: titleColor))
    }

    let shown = isExpanded ? calls.suffix(limit) : calls.suffix(3)
    if !shown.isEmpty {
        section()
        if shown.count < calls.count {
            if isExpanded {
                cuts?.clipped = true
            }
            let earlier = calls.count - shown.count
            body.append(NSAttributedString(string: earlier == 1 ? "1 earlier call\n" : "\(earlier) earlier calls\n", font: Font.regular(12.0), textColor: textColor))
        }
        for (index, call) in shown.enumerated() {
            if index > 0 {
                body.append(NSAttributedString(string: "\n"))
            }
            let nameColor: UIColor
            switch call.status {
            case .running:
                nameColor = titleColor
            case .failed:
                nameColor = errorColor
            case .done, .cancelled:
                nameColor = textColor
            }
            var suffix = ""
            if call.status == .cancelled {
                suffix = "  cancelled"
            } else if let duration = call.duration, duration >= 1.0 {
                suffix = "  " + formatDuration(duration)
            }
            body.append(fittedLine(name: toolTitle(call.name), nameFont: nameFont, nameColor: nameColor, detail: call.summary.replacingOccurrences(of: "\n", with: " "), detailFont: codeFont, detailColor: call.status == .running ? titleColor : textColor, suffix: suffix, maxWidth: maxWidth))
            // At work: the last line it wrote, as a command's card ends with its output.
            if call.status == .running, let last = call.output?.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                body.append(NSAttributedString(string: "\n" + fittedText(last.trimmingCharacters(in: .whitespaces), font: codeFont, maxWidth: maxWidth), font: codeFont, textColor: textColor))
            }
            if call.status == .failed, let error = call.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                let text = isExpanded ? clippedLines(error, count: limit == Int.max ? limit : 4, fromStart: true) : fittedText(error.replacingOccurrences(of: "\n", with: " "), font: codeFont, maxWidth: maxWidth)
                body.append(NSAttributedString(string: "\n" + text, font: codeFont, textColor: errorColor))
            }
        }
    }

    if !output.isEmpty {
        section()
        body.append(NSAttributedString(string: clippedLines(output, count: isExpanded ? limit : 3, fromStart: true, cuts: isExpanded ? cuts : nil), font: codeFont, textColor: textColor))
    }
    if let error, !error.isEmpty {
        section()
        body.append(NSAttributedString(string: clippedLines(error, count: isExpanded ? limit : 3, fromStart: true, cuts: isExpanded ? cuts : nil), font: codeFont, textColor: errorColor))
    }
    return body
}

/// One line however long what it says: the detail cut at the end to fit, the name and the suffix kept.
private func fittedLine(name: String, nameFont: UIFont, nameColor: UIColor, detail: String, detailFont: UIFont, detailColor: UIColor, suffix: String, maxWidth: CGFloat) -> NSAttributedString {
    func line(_ detail: String) -> NSAttributedString {
        let line = NSMutableAttributedString(string: name, font: nameFont, textColor: nameColor)
        if !detail.isEmpty {
            line.append(NSAttributedString(string: "  " + detail, font: detailFont, textColor: detailColor))
        }
        if !suffix.isEmpty {
            line.append(NSAttributedString(string: suffix, font: detailFont, textColor: detailColor.withAlphaComponent(0.7)))
        }
        return line
    }
    let whole = line(detail)
    if whole.size().width <= maxWidth {
        return whole
    }
    var low = 0
    var high = detail.count
    while low < high {
        let middle = (low + high + 1) / 2
        if line(String(detail.prefix(middle)) + "…").size().width <= maxWidth {
            low = middle
        } else {
            high = middle - 1
        }
    }
    return line(String(detail.prefix(low)) + "…")
}

/// Text cut at the end to one line.
private func fittedText(_ text: String, font: UIFont, maxWidth: CGFloat) -> String {
    if NSAttributedString(string: text, font: font, textColor: .black).size().width <= maxWidth {
        return text
    }
    var low = 0
    var high = text.count
    while low < high {
        let middle = (low + high + 1) / 2
        if NSAttributedString(string: String(text.prefix(middle)) + "…", font: font, textColor: .black).size().width <= maxWidth {
            low = middle
        } else {
            high = middle - 1
        }
    }
    return String(text.prefix(low)) + "…"
}

/// The edges of a code block that scrolls sideways fade where there is more of it: the right one until it is scrolled
/// to its end, the left one once it is scrolled from its start. A mask over the scroller, kept on screen as it scrolls.
private final class CodeScrollFade: NSObject, UIScrollViewDelegate {
    private static let width: CGFloat = 28.0

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        CodeScrollFade.update(scrollView)
    }

    static func update(_ scrollView: UIScrollView) {
        let bounds = scrollView.bounds
        let more = scrollView.contentSize.width - bounds.width
        guard more > 1.0, bounds.width > CodeScrollFade.width * 2.0 else {
            scrollView.layer.mask = nil
            return
        }
        let mask = (scrollView.layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.startPoint = CGPoint(x: 0.0, y: 0.5)
        mask.endPoint = CGPoint(x: 1.0, y: 0.5)
        let fade = CodeScrollFade.width / bounds.width
        let left: CGFloat = scrollView.contentOffset.x > 1.0 ? 0.0 : 1.0
        let right: CGFloat = scrollView.contentOffset.x < more - 1.0 ? 0.0 : 1.0
        mask.colors = [UIColor(white: 0.0, alpha: left).cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor(white: 0.0, alpha: right).cgColor]
        mask.locations = [0.0, NSNumber(value: Double(fade)), NSNumber(value: Double(1.0 - fade)), 1.0]
        mask.frame = bounds
        CATransaction.commit()
        if scrollView.layer.mask !== mask {
            scrollView.layer.mask = mask
        }
    }
}

/// A message's text with its tau links' cards under it (docs/links.md).
private func withReferences(_ text: NSAttributedString, _ references: [LinkReference], style: MarkdownStyle) -> NSAttributedString {
    guard !references.isEmpty else {
        return text
    }
    let result = NSMutableAttributedString(attributedString: text)
    for reference in references {
        result.append(NSAttributedString(string: "\n", font: Font.regular(style.fontSize), textColor: style.textColor))
        result.append(MarkdownText.reference(reference, style: style))
    }
    return result
}

