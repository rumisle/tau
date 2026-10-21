import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import InteractiveTextComponent
import StreamingTextReveal
import ChatMessageSelectionNode
import ActivityIndicator
import TextSelectionNode
import TelegramPresentationData

/// What a message's neighbors need to know about it: who wrote it, so consecutive user bubbles merge.
private enum ChatHistoryNeighbor: Equatable {
    case user
    case assistant
    case tool
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
    /// Shows a controller above everything, the context menu included: the menu over selected text.
    var presentInGlobalOverlay: (ViewController, Any?) -> Void = { _, _ in }
    /// The chat's view, which text selection keeps its knobs and menu inside.
    var rootView: () -> UIView? = { nil }

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
    let interaction: ChatMessageItemInteraction

    init(theme: TauTheme, message: ChatMessage, isStreaming: Bool, selection: Bool?, isExpanded: Bool = false, wrapCode: Bool = true, riseFrom: CGRect? = nil, interaction: ChatMessageItemInteraction) {
        self.riseFrom = riseFrom
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
        }
    }

    var approximateHeight: CGFloat {
        return 60.0
    }

    var selectable: Bool {
        return self.selection != nil || self.message.tool != nil
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(false)
        if self.selection != nil {
            self.interaction.toggleSelection(self.message.id)
        } else if self.message.tool != nil {
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
            async {
                let (layout, apply) = makeLayout(self, params, neighbors)
                Queue.mainQueue().async {
                    completion(layout, { _ in apply(animation) })
                }
            }
        }
    }
}

private let messageFontSize: CGFloat = 17.0
private let dateFont = Font.regular(11.0)
private let toolTitleFont = Font.semibold(13.0)
private let toolFont = Font.monospace(13.0)
private let fileTitleFont = Font.semibold(16.0)
private let fileSizeFont = Font.regular(13.0)

// Telegram ChatMessageItemLayoutConstants.compact.
private let bubbleEdgeInset: CGFloat = 3.0
private let bubbleTailInset: CGFloat = 6.0
private let bubbleMinimumSize = CGSize(width: 40.0, height: 35.0)
private let textInsets = UIEdgeInsets(top: 6.0 + UIScreenPixel, left: 11.0, bottom: 6.0 - UIScreenPixel, right: 11.0)
private let mediaInset: CGFloat = 2.0
private let defaultSpacing: CGFloat = 4.0
private let mergedSpacing: CGFloat = 1.0
/// Margins of bubble-less assistant text.
private let freeTextInset: CGFloat = 16.0
/// How far content moves right to make room for selection checks.
private let selectionInset: CGFloat = 42.0
private let blockSpacing: CGFloat = 12.0

/// One laid-out block of assistant content, kept so streaming ticks can tell when the row's height changes.
private enum LaidOutBlock {
    case text(start: Int, length: Int, layout: InteractiveTextNodeLayout)
    case table(start: Int, length: Int, size: CGSize)

    var start: Int {
        switch self {
        case let .text(start, _, _), let .table(start, _, _):
            return start
        }
    }

    var length: Int {
        switch self {
        case let .text(_, length, _), let .table(_, length, _):
            return length
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
            height += blockSpacing
        }
        visibleCount += 1
        switch block {
        case let .text(start, length, layout):
            if let revealed, revealed < start + length {
                height += layout.sizeForCharacterCount(characterCount: max(0, revealed - start)).height
            } else {
                height += layout.size.height
            }
        case let .table(_, _, size):
            height += size.height
        }
    }
    return max(1.0, height)
}

final class ChatMessageItemNode: ListViewItemNode {
    private let bubbleNode = GradientBubbleNode()
    private let dateNode = TextNode()
    /// Telegram's status after the time: the turning clock while on its way, two checks once the model has it.
    private let clockFrameNode = ASImageNode()
    private let clockMinNode = ASImageNode()
    private let checkSentNode = ASImageNode()
    private let checkReadNode = ASImageNode()
    /// ChatMessageDeliveryFailedNode: the red badge beside a refused message.
    private let failedNode = ASImageNode()
    private var statusImagesKey: String?
    private var textNodes: [InteractiveTextNode] = []
    private var tableNodes: [ChatTableNode] = []
    private var imageNodes: [ASImageNode] = []
    /// The attachment each visible image node shows.
    private var imageAttachmentIds: [Int] = []
    /// The photo open in the media viewer, hidden here meanwhile.
    private var hiddenAttachmentId: Int?
    private var fileNodes: [FileAttachmentNode] = []
    private let toolBackgroundNode = ASDisplayNode()
    private let toolTitleNode = TextNode()
    private let toolTextNode = TextNode()
    /// A subagent's card: its name and task as the quote over a Telegram reply, then what it said.
    private let subagentQuoteNode = ASDisplayNode()
    private let subagentBarNode = ASDisplayNode()
    private let subagentTaskNode = TextNode()
    private let subagentMetaNode = TextNode()
    private let subagentArrowNode = ASImageNode()
    private var subagentAnswerNode: InteractiveTextNode?
    /// As in ChatMessageBubbleItemNode: the long-press source wraps the extractable container, whose content node the
    /// context menu lifts out of the list and puts back.
    let containerNode = ContextControllerSourceNode()
    let contextSourceNode = ContextExtractedContentContainingNode()
    private var contentNode: ContextExtractedContentNode {
        return self.contextSourceNode.contentNode
    }
    private var selectionNode: ChatMessageSelectionNode?

    private(set) var item: ChatMessageItem?
    private var laidOutBlocks: [LaidOutBlock] = []
    private var revealController: TextRevealController?
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
        self.subagentQuoteNode.isLayerBacked = true
        self.subagentQuoteNode.cornerRadius = 8.0
        self.subagentQuoteNode.clipsToBounds = true
        self.subagentBarNode.isLayerBacked = true
        self.subagentQuoteNode.addSubnode(self.subagentBarNode)
        self.subagentArrowNode.isLayerBacked = true
        self.subagentArrowNode.displaysAsynchronously = false
        for node in [self.subagentQuoteNode, self.subagentTaskNode, self.subagentMetaNode, self.subagentArrowNode] {
            node.isHidden = true
            self.contentNode.addSubnode(node)
        }
        self.contentNode.addSubnode(self.dateNode)
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
            guard let self, let item = self.item, item.selection == nil, !item.isStreaming else {
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

    override func didLoad() {
        super.didLoad()
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        tap.cancelsTouchesInView = false
        self.view.addGestureRecognizer(tap)
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        guard let item = self.item, item.selection == nil else {
            return
        }
        if !self.failedNode.isHidden, self.failedNode.frame.insetBy(dx: -8.0, dy: -8.0).contains(recognizer.location(in: self.view)) {
            // As ChatMessageDeliveryFailedNode's tap: the message's menu, with Resend.
            item.interaction.openContextMenu(item.message.id, self, nil)
            return
        }
        let point = recognizer.location(in: self.contentNode.view)
        for (index, id) in self.imageAttachmentIds.enumerated() where index < self.imageNodes.count {
            if self.imageNodes[index].frame.contains(point) {
                item.interaction.openImage(id)
                return
            }
        }
        // As ChatMessageTextBubbleContentNode's tap actions: a code block or inline code copies.
        for textNode in self.textNodes {
            let local = self.contentNode.view.convert(point, to: textNode.view)
            guard textNode.bounds.contains(local), let (index, attributes) = textNode.attributesAtPoint(local, orNearest: false) else {
                continue
            }
            var code: String?
            if attributes[MarkdownText.inlineCodeKey] != nil {
                code = textNode.attributeSubstring(name: MarkdownText.inlineCodeKey.rawValue, index: index)?.1
            } else if let quote = attributes[MarkdownText.blockQuoteKey] as? TextNodeBlockQuoteData, case .code = quote.kind {
                code = textNode.attributeSubstring(name: MarkdownText.blockQuoteKey.rawValue, index: index)?.1
            }
            if let code {
                let text = code.replacingOccurrences(of: "\u{00A0}", with: " ")
                UIPasteboard.general.string = text
                item.interaction.copied(text)
                return
            }
        }
    }

    /// Telegram's text selection in a message lifted into the context menu: a second long press on the text selects
    /// it, with knobs and a Copy / Share / Look Up menu, while the menu's actions step aside
    /// (ChatMessageTextBubbleContentNode.updateIsExtractedToContextPreview).
    private var textSelectionNodes: [TextSelectionNode] = []

    private func updateIsExtractedToContextPreview(_ value: Bool) {
        if value {
            guard self.textSelectionNodes.isEmpty, let item = self.item, item.message.tool == nil else {
                return
            }
            let theme = item.theme.presentationTheme
            let colors = item.message.role == .user ? theme.chat.message.outgoing : theme.chat.message.incoming
            for textNode in self.textNodes {
                let selectionNode = TextSelectionNode(theme: TextSelectionTheme(selection: colors.textSelectionColor, knob: colors.textSelectionKnobColor, isDark: theme.overallDarkAppearance), strings: item.theme.presentationStrings, textNodeOrView: .node(textNode), updateIsActive: { [weak self] value in
                    self?.contextSourceNode.updateDistractionFreeMode?(value)
                }, present: { [weak self] controller, arguments in
                    self?.item?.interaction.presentInGlobalOverlay(controller, arguments)
                }, rootView: { [weak self] in
                    return self?.item?.interaction.rootView()
                }, performAction: { [weak self] text, action in
                    self?.performTextSelectionAction(text: text, action: action)
                })
                selectionNode.enableQuote = false
                selectionNode.enableTranslate = false
                // A code block's node sits in its scroller.
                let frame = textNode.view.convert(textNode.bounds, to: self.contentNode.view)
                selectionNode.frame = frame
                selectionNode.highlightAreaNode.frame = frame
                if textNode.supernode === self.contentNode {
                    self.contentNode.insertSubnode(selectionNode.highlightAreaNode, belowSubnode: textNode)
                } else {
                    self.contentNode.insertSubnode(selectionNode.highlightAreaNode, belowSubnode: self.dateNode)
                }
                self.contentNode.addSubnode(selectionNode)
                self.textSelectionNodes.append(selectionNode)
            }
        } else {
            let nodes = self.textSelectionNodes
            self.textSelectionNodes = []
            for node in nodes {
                node.highlightAreaNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
                node.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak node] _ in
                    node?.highlightAreaNode.removeFromSupernode()
                    node?.removeFromSupernode()
                })
            }
        }
    }

    private func performTextSelectionAction(text: NSAttributedString, action: TextSelectionAction) {
        // Formulas copy as their LaTeX, kept indentation as plain spaces.
        let plain = NSMutableString(string: text.string)
        text.enumerateAttribute(MathText.latexKey, in: NSRange(location: 0, length: text.length), options: [.reverse]) { value, range, _ in
            if let latex = value as? String {
                plain.replaceCharacters(in: range, with: "$\(latex)$")
            }
        }
        let string = (plain as String).replacingOccurrences(of: "\u{00A0}", with: " ")
        switch action {
        case .copy:
            UIPasteboard.general.string = string
        case .share:
            let controller = UIActivityViewController(activityItems: [string], applicationActivities: nil)
            self.view.window?.rootViewController?.present(controller, animated: true)
        case .lookup:
            let controller = UIReferenceLibraryViewController(term: string)
            self.view.window?.rootViewController?.present(controller, animated: true)
        default:
            break
        }
        self.contextSourceNode.requestDismiss?()
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

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        super.animateInsertion(currentTimestamp, duration: duration, options: options)
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
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
        // The list is rotated, so this row's top on screen is the container height minus its maxY.
        let visualTop = containerSize.height - rect.maxY
        self.bubbleNode.updateAbsolutePosition(visualTop: visualTop, containerSize: containerSize)
    }

    func asyncLayout() -> (_ item: ChatMessageItem, _ params: ListViewItemLayoutParams, _ neighbors: ListViewItemNeighbors) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeDateLayout = TextNode.asyncLayout(self.dateNode)
        let makeToolTitleLayout = TextNode.asyncLayout(self.toolTitleNode)
        let makeToolTextLayout = TextNode.asyncLayout(self.toolTextNode)
        let makeSubagentTaskLayout = TextNode.asyncLayout(self.subagentTaskNode)
        let makeSubagentMetaLayout = TextNode.asyncLayout(self.subagentMetaNode)
        let makeSubagentAnswerLayout = InteractiveTextNode.asyncLayout(self.subagentAnswerNode)
        let existingTextNodes = self.textNodes
        let existingTableNodes = self.tableNodes
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
                // Photos fill the bubble width and the caption wraps to it, as Telegram's media bubbles; files are rows
                // above the text.
                var imageSizes: [CGSize] = []
                var files: [(name: String, size: Int64)] = []
                let imageWidth = min(maxContentWidth - mediaInset * 2.0, 260.0)
                for attachment in message.attachments {
                    switch attachment.kind {
                    case let .image(image):
                        let aspect = image.size.height / max(1.0, image.size.width)
                        imageSizes.append(CGSize(width: imageWidth, height: min(320.0, floor(imageWidth * aspect))))
                    case let .file(name, size):
                        files.append((name, size))
                    }
                }
                let maxTextWidth = imageSizes.isEmpty ? maxContentWidth - textInsets.left - textInsets.right : imageWidth + mediaInset * 2.0 - textInsets.left - textInsets.right

                var style = MarkdownStyle(fontSize: messageFontSize, textColor: theme.outgoing.primaryTextColor, linkColor: theme.outgoing.linkTextColor, accentColor: theme.outgoing.primaryTextColor)
                style.math = false
                let textNode = existingTextNodes.first
                let hasText = !message.text.isEmpty
                let (textLayout, textApply) = InteractiveTextNode.asyncLayout(textNode)(InteractiveTextNodeLayoutArguments(attributedString: MarkdownText.render(message.text, style: style), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude)))
                let (dateLayout, dateApply) = makeDateLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: messageTimeString(message.date), font: dateFont, textColor: theme.outgoing.secondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 100.0, height: 20.0)))
                let fileLayouts = files.map { FileAttachmentNode.measure(name: $0.name, size: $0.size, maxWidth: maxTextWidth) }

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

                var mediaHeight: CGFloat = 0.0
                var mediaWidth: CGFloat = 0.0
                for size in imageSizes {
                    mediaHeight += size.height + mediaInset
                    mediaWidth = max(mediaWidth, size.width + mediaInset * 2.0)
                }
                if !imageSizes.isEmpty {
                    mediaHeight += mediaInset
                }

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
                    while self.imageNodes.count < imageSizes.count {
                        let imageNode = ASImageNode()
                        imageNode.contentMode = .scaleAspectFill
                        imageNode.clipsToBounds = true
                        imageNode.cornerRadius = 14.0
                        imageNode.displaysAsynchronously = false
                        imageNode.isAccessibilityElement = true
                        imageNode.accessibilityIdentifier = "photo"
                        imageNode.accessibilityTraits = .image
                        self.imageNodes.append(imageNode)
                        self.contentNode.addSubnode(imageNode)
                    }
                    var y = mediaInset
                    var imageIndex = 0
                    self.imageAttachmentIds = []
                    for attachment in message.attachments {
                        if case let .image(image) = attachment.kind {
                            let imageNode = self.imageNodes[imageIndex]
                            imageNode.image = image
                            imageNode.isHidden = false
                            imageNode.alpha = attachment.id == self.hiddenAttachmentId ? 0.0 : 1.0
                            self.imageAttachmentIds.append(attachment.id)
                            imageNode.frame = CGRect(origin: CGPoint(x: backgroundFrame.minX + mediaInset, y: y), size: imageSizes[imageIndex])
                            y += imageSizes[imageIndex].height + mediaInset
                            imageIndex += 1
                        }
                    }
                    for index in imageIndex ..< self.imageNodes.count {
                        self.imageNodes[index].isHidden = true
                    }
                    var contentY = imageSizes.isEmpty ? textInsets.top : y + 4.0

                    while self.fileNodes.count < files.count {
                        let fileNode = FileAttachmentNode()
                        self.fileNodes.append(fileNode)
                        self.contentNode.addSubnode(fileNode)
                    }
                    for (index, file) in files.enumerated() {
                        let fileNode = self.fileNodes[index]
                        fileNode.isHidden = false
                        let size = fileLayouts[index]
                        fileNode.update(name: file.name, size: file.size, color: theme.outgoing.primaryTextColor, secondaryColor: theme.outgoing.secondaryTextColor, width: size.width)
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
                        self.contentFrame = .zero
                        self.layoutContainers(size: layout.contentSize)
                    })
                }
                let maxTextWidth = contentWidth - freeTextInset * 2.0 - leftShift
                let isThinking = message.role == .thinking
                // Reasoning is dimmer and smaller, and folds to its start once the answer is written.
                var style = MarkdownStyle(fontSize: isThinking ? 15.0 : messageFontSize, textColor: isThinking ? theme.freeSecondaryTextColor : theme.freeTextColor, linkColor: theme.linkTextColor, accentColor: item.theme.accentColor)
                style.maxWidth = maxTextWidth
                var sourceText = message.text
                if isThinking && !item.isStreaming && !item.isExpanded && sourceText.count > 240 {
                    sourceText = String(sourceText.prefix(240)) + "…"
                }
                let blocks = MarkdownText.blocks(sourceText, style: style, wrapCode: item.wrapCode)
                let tableStyle = ChatTableStyle(borderColor: theme.tableBorderColor, headerBackgroundColor: theme.tableHeaderBackgroundColor)

                var laidOut: [LaidOutBlock] = []
                var textApplies: [(InteractiveTextNode.ApplyArguments) -> InteractiveTextNode] = []
                /// Per text block: a code block that scrolls sideways.
                var textScrolls: [Bool] = []
                var tableApplies: [(ChatTableNode, () -> Void)] = []
                var textIndex = 0
                var tableIndex = 0
                var start = 0
                for block in blocks {
                    switch block {
                    case let .text(string):
                        let existing = textIndex < existingTextNodes.count ? existingTextNodes[textIndex] : nil
                        let (layout, apply) = InteractiveTextNode.asyncLayout(existing)(InteractiveTextNodeLayoutArguments(attributedString: string, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude)))
                        laidOut.append(.text(start: start, length: string.length, layout: layout))
                        textApplies.append(apply)
                        textScrolls.append(false)
                        textIndex += 1
                    case let .code(string):
                        // As wide as its longest line; the row shows it through a horizontal scroller.
                        let existing = textIndex < existingTextNodes.count ? existingTextNodes[textIndex] : nil
                        let (layout, apply) = InteractiveTextNode.asyncLayout(existing)(InteractiveTextNodeLayoutArguments(attributedString: string, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: 100_000.0, height: .greatestFiniteMagnitude)))
                        laidOut.append(.text(start: start, length: string.length, layout: layout))
                        textApplies.append(apply)
                        textScrolls.append(true)
                        textIndex += 1
                    case let .table(table):
                        let node = tableIndex < existingTableNodes.count ? existingTableNodes[tableIndex] : ChatTableNode()
                        let (size, apply) = ChatTableNode.asyncLayout(node)(table, tableStyle, maxTextWidth)
                        laidOut.append(.table(start: start, length: table.characterCount, size: size))
                        tableApplies.append((node, apply))
                        tableIndex += 1
                    }
                    start += block.characterCount
                }
                let totalLength = start

                // While streaming, the row is as tall as the content revealed so far.
                let revealed: Int? = (item.isStreaming || currentRevealCount != nil) ? (currentRevealCount ?? 0) : nil
                let textHeight = contentHeight(laidOut, revealed: revealed)
                // The end of a run: when the answer came and how long the run took, at the bottom right as Telegram
                // dates a message.
                var footerLayout: TextNodeLayout?
                var footerApply: (() -> TextNode)?
                if let turn = message.turn, !item.isStreaming, revealed == nil {
                    var text = messageTimeString(turn.finishedAt)
                    if let duration = turn.duration, duration >= 1.0 {
                        text = "Worked for \(formatDuration(duration)) · " + text
                    }
                    let (layout, apply) = makeDateLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: text, font: dateFont, textColor: theme.freeSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: 20.0)))
                    footerLayout = layout
                    footerApply = apply
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
                        if self.dateNode.isHidden {
                            self.dateNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                        }
                        self.dateNode.isHidden = false
                        let x = params.leftInset + freeTextInset + leftShift
                        self.dateNode.frame = CGRect(origin: CGPoint(x: x + maxTextWidth - footerLayout.size.width, y: textHeight + footerSpacing), size: footerLayout.size)
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

                    let applyArguments = InteractiveTextNode.ApplyArguments(animation: animation, spoilerTextColor: theme.freeTextColor, spoilerEffectColor: theme.freeTextColor, areContentAnimationsEnabled: true, spoilerExpandRect: nil)
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
                            y += blockSpacing
                        }
                        switch block {
                        case let .text(_, _, layout):
                            let node = textNodes[textCursor]
                            let scrolls = textScrolls[textCursor]
                            textCursor += 1
                            if scrolls {
                                // The scroller spans the row, so code scrolls out to the screen's edges.
                                let scroller = self.codeScroller(for: node)
                                animation.animator.updateFrame(layer: scroller.layer, frame: CGRect(x: 0.0, y: y, width: params.width, height: layout.size.height), completion: nil)
                                node.frame = CGRect(origin: CGPoint(x: x, y: 0.0), size: layout.size)
                                scroller.view.contentSize = CGSize(width: max(params.width, x + layout.size.width + freeTextInset), height: layout.size.height)
                            } else {
                                if node.supernode !== self.contentNode {
                                    self.contentNode.insertSubnode(node, belowSubnode: self.dateNode)
                                }
                                animation.animator.updateFrame(layer: node.layer, frame: CGRect(origin: CGPoint(x: x, y: y), size: layout.size), completion: nil)
                            }
                            y += layout.size.height
                        case let .table(_, _, size):
                            let node = tableApplies[tableCursor].0
                            tableCursor += 1
                            animation.animator.updateFrame(layer: node.layer, frame: CGRect(origin: CGPoint(x: x, y: y), size: size), completion: nil)
                            y += size.height
                        }
                    }
                    self.removeCodeScrollers(keeping: zip(textNodes, textScrolls).filter(\.1).map(\.0))
                    self.contentFrame = CGRect(x: x - 8.0, y: -4.0, width: maxTextWidth + 16.0, height: height + 8.0)
                    self.updateReveal(item: item, totalLength: totalLength)
                    self.layoutContainers(size: layout.contentSize)
                    self.updateSelection(item: item, size: layout.contentSize, animation: animation)
                })

            case let .tool(name):
                if let call = message.tool?.subagent {
                    let tool = message.tool!
                    let status = tool.status
                    let working = status == .preparing || status == .pending || status == .running || tool.childBusy
                    let accent = item.theme.accentColor
                    let cardWidth = contentWidth - freeTextInset * 2.0 + 8.0 - leftShift
                    let quoteInset: CGFloat = 6.0
                    let quoteWidth = cardWidth - quoteInset * 2.0
                    let quoteText = UIEdgeInsets(top: 6.0, left: 11.0, bottom: 7.0, right: 30.0)
                    let textWidth = quoteWidth - quoteText.left - quoteText.right

                    // The quote: who, and the task it works on.
                    let header = NSMutableAttributedString(string: call.name, font: Font.semibold(14.0), textColor: accent)
                    let suffix: String
                    switch call.kind {
                    case .spawn:
                        suffix = working ? "working" : ""
                    case .send:
                        suffix = "message"
                    case .stop:
                        suffix = "stopped"
                    case .answer:
                        suffix = "answered"
                    case .failed:
                        suffix = "failed"
                    }
                    if !suffix.isEmpty {
                        header.append(NSAttributedString(string: " · " + suffix, font: Font.regular(14.0), textColor: call.kind == .failed ? item.theme.list.itemDestructiveColor : theme.toolCardTextColor))
                    }
                    let (headerLayout, headerApply) = makeToolTitleLayout(TextNodeLayoutArguments(attributedString: header, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: textWidth, height: .greatestFiniteMagnitude)))
                    let quoted: String
                    switch call.kind {
                    case .spawn, .send:
                        quoted = call.text
                    case .answer, .failed, .stop:
                        quoted = call.task ?? "Subagent"
                    }
                    let quoteLines = call.kind == .spawn ? (item.isExpanded ? 12 : 3) : (call.kind == .send ? 2 : 1)
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
                            let (layout, apply) = makeSubagentMetaLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: parts.joined(separator: " · "), font: Font.regular(13.0), textColor: theme.toolCardTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)))
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
                        let hasLink = tool.childConversationId != nil && !working
                        self.subagentArrowNode.isHidden = !hasLink
                        if let arrowImage {
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
                let (titleText, summaryText, body) = toolCardContent(name: name, tool: tool, fallbackText: message.text, isExpanded: item.isExpanded, isActive: isActive, isDark: isDark, textColor: theme.toolCardTextColor, titleColor: theme.toolCardTitleColor, accentColor: item.theme.accentColor)
                // Title: the tool, then what it works on, as a terminal agent prints a call.
                let title = NSMutableAttributedString(string: titleText, font: toolTitleFont, textColor: status == .failed ? item.theme.list.itemDestructiveColor : theme.toolCardTitleColor)
                if !summaryText.isEmpty {
                    title.append(NSAttributedString(string: "  " + summaryText, font: Font.monospace(13.0), textColor: theme.toolCardTextColor))
                }
                let titleWidth = maxWidth - (isActive ? 22.0 : 0.0)
                let (titleLayout, titleApply) = makeToolTitleLayout(TextNodeLayoutArguments(attributedString: title, maximumNumberOfLines: item.isExpanded ? 6 : 1, truncationType: .end, constrainedSize: CGSize(width: titleWidth, height: .greatestFiniteMagnitude)))

                if body.length > 0, body.string.hasSuffix("\n") {
                    body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
                }
                let (textLayout, textApply) = makeToolTextLayout(TextNodeLayoutArguments(attributedString: body, maximumNumberOfLines: item.isExpanded ? 120 : 10, truncationType: .end, constrainedSize: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), lineSpacing: 0.1))

                let cardInsets = UIEdgeInsets(top: 9.0, left: 12.0, bottom: 10.0, right: 12.0)
                let bodyHeight = body.length > 0 ? textLayout.size.height + 3.0 : 0.0
                let cardSize = CGSize(
                    width: max(titleLayout.size.width + (isActive ? 22.0 : 0.0), body.length > 0 ? textLayout.size.width : 0.0) + cardInsets.left + cardInsets.right,
                    height: titleLayout.size.height + bodyHeight + cardInsets.top + cardInsets.bottom
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

                    self.toolBackgroundNode.backgroundColor = theme.toolCardBackgroundColor
                    let cardFrame = CGRect(origin: CGPoint(x: params.leftInset + freeTextInset - 4.0 + leftShift, y: 0.0), size: cardSize)
                    self.contentFrame = cardFrame
                    animation.animator.updateFrame(layer: self.toolBackgroundNode.layer, frame: cardFrame, completion: nil)

                    let _ = titleApply()
                    animation.animator.updateFrame(layer: self.toolTitleNode.layer, frame: CGRect(origin: CGPoint(x: cardFrame.minX + cardInsets.left, y: cardFrame.minY + cardInsets.top), size: titleLayout.size), completion: nil)
                    let _ = textApply()
                    animation.animator.updateFrame(layer: self.toolTextNode.layer, frame: CGRect(origin: CGPoint(x: cardFrame.minX + cardInsets.left, y: cardFrame.minY + cardInsets.top + titleLayout.size.height + 3.0), size: textLayout.size), completion: nil)
                    self.updateToolActivity(isActive: isActive, color: theme.toolCardTextColor, frame: CGRect(x: cardFrame.maxX - cardInsets.right - 14.0, y: cardFrame.minY + cardInsets.top + 1.0, width: 14.0, height: 14.0))
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
        return scroller
    }

    private func removeCodeScrollers(keeping nodes: [InteractiveTextNode]) {
        let kept = Set(nodes.map(ObjectIdentifier.init))
        for (key, scroller) in self.codeScrollers where !kept.contains(key) {
            scroller.removeFromSupernode()
            self.codeScrollers[key] = nil
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
                let controller = TextRevealController(initialRevealedCount: 0, initialLength: 0)
                controller.observeUpdate(latestLength: totalLength, at: now)
                self.revealController = controller
            }
        } else if let controller = self.revealController {
            controller.finalize(finalLength: totalLength)
        } else {
            self.applyReveal(nil)
            return
        }
        self.applyReveal(Int(self.revealController?.revealedCount ?? 0))

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
    private func applyReveal(_ revealed: Int?) {
        var textCursor = 0
        var tableCursor = 0
        for block in self.laidOutBlocks {
            switch block {
            case let .text(start, length, _):
                guard textCursor < self.textNodes.count else {
                    continue
                }
                let node = self.textNodes[textCursor]
                textCursor += 1
                if let revealed, revealed < start + length {
                    node.updateRevealCharacterCount(count: max(0, revealed - start), animated: true)
                } else if node.revealCharacterCount != nil {
                    node.updateRevealCharacterCount(count: nil, animated: false)
                }
            case let .table(start, _, _):
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
final class FileAttachmentNode: ASDisplayNode {
    private let iconNode = ASImageNode()
    private let nameNode = ImmediateTextNode()
    private let sizeNode = ImmediateTextNode()

    static func measure(name: String, size: Int64, maxWidth: CGFloat) -> CGSize {
        let nameWidth = ceil((name as NSString).size(withAttributes: [.font: fileTitleFont]).width)
        return CGSize(width: min(maxWidth, 52.0 + nameWidth), height: 44.0)
    }

    override init() {
        super.init()
        self.iconNode.displaysAsynchronously = false
        self.nameNode.maximumNumberOfLines = 1
        self.nameNode.truncationMode = .byTruncatingMiddle
        self.addSubnode(self.iconNode)
        self.addSubnode(self.nameNode)
        self.addSubnode(self.sizeNode)
    }

    func update(name: String, size: Int64, color: UIColor, secondaryColor: UIColor, width: CGFloat) {
        self.iconNode.image = generateImage(CGSize(width: 44.0, height: 44.0), rotatedContext: { imageSize, context in
            context.clear(CGRect(origin: CGPoint(), size: imageSize))
            context.setFillColor(color.withAlphaComponent(0.2).cgColor)
            context.fillEllipse(in: CGRect(origin: CGPoint(), size: imageSize))
            if let icon = UIImage(systemName: "doc.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .medium))?.withTintColor(color, renderingMode: .alwaysOriginal) {
                UIGraphicsPushContext(context)
                icon.draw(at: CGPoint(x: (imageSize.width - icon.size.width) / 2.0, y: (imageSize.height - icon.size.height) / 2.0))
                UIGraphicsPopContext()
            }
        })
        self.iconNode.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
        self.nameNode.attributedText = NSAttributedString(string: name, font: fileTitleFont, textColor: color)
        self.sizeNode.attributedText = NSAttributedString(string: ByteCountFormatter.string(fromByteCount: size, countStyle: .file), font: fileSizeFont, textColor: secondaryColor)
        let textWidth = max(10.0, width - 52.0)
        let nameSize = self.nameNode.updateLayout(CGSize(width: textWidth, height: 22.0))
        let sizeSize = self.sizeNode.updateLayout(CGSize(width: textWidth, height: 18.0))
        self.nameNode.frame = CGRect(origin: CGPoint(x: 52.0, y: 3.0), size: nameSize)
        self.sizeNode.frame = CGRect(origin: CGPoint(x: 52.0, y: 24.0), size: sizeSize)
    }
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
private func clippedLines(_ text: String, count: Int, fromStart: Bool) -> String {
    let lines = text.components(separatedBy: "\n")
    guard lines.count > count else {
        return text
    }
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
private func toolCardContent(name: String, tool: ToolCallInfo?, fallbackText: String, isExpanded: Bool, isActive: Bool, isDark: Bool, textColor: UIColor, titleColor: UIColor, accentColor: UIColor) -> (String, String, NSMutableAttributedString) {
    let body = NSMutableAttributedString()
    var output = (tool?.output ?? fallbackText).trimmingCharacters(in: .whitespacesAndNewlines)
    let codeFont = Font.monospace(12.0)
    // pi wraps a tool's error in <harness> tags for the model; the card shows the message.
    if output.hasPrefix("<harness>") {
        output = output.replacingOccurrences(of: "<harness>", with: "").replacingOccurrences(of: "</harness>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if tool?.status == .failed, !output.isEmpty {
        let errorColor = isDark ? diffRemovedDark : diffRemovedLight
        switch tool?.detail ?? .none {
        case let .read(path):
            body.append(NSAttributedString(string: clippedLines(output, count: isExpanded ? 40 : 4, fromStart: true), font: codeFont, textColor: errorColor))
            return ("Read", shortPath(tool?.summary ?? path, isExpanded: isExpanded), body)
        case let .bash(command):
            body.append(MarkdownText.code("$ " + clippedLines(command, count: isExpanded ? 40 : 3, fromStart: true), language: "bash", font: codeFont, textColor: titleColor))
            body.append(NSAttributedString(string: "\n" + clippedLines(output, count: isExpanded ? 80 : 6, fromStart: false), font: codeFont, textColor: errorColor))
            return ("Bash", "", body)
        default:
            break
        }
    }
    switch tool?.detail ?? .none {
    case let .bash(command):
        let shownCommand = clippedLines(command.trimmingCharacters(in: .whitespacesAndNewlines), count: isExpanded ? 40 : 3, fromStart: true)
        body.append(MarkdownText.code("$ " + shownCommand, language: "bash", font: codeFont, textColor: titleColor))
        if !output.isEmpty {
            body.append(NSAttributedString(string: "\n"))
            // A command says how it went at the end.
            body.append(NSAttributedString(string: clippedLines(output, count: isExpanded ? 80 : (isActive ? 4 : 6), fromStart: false), font: codeFont, textColor: textColor))
        }
        return ("Bash", "", body)
    case let .read(path):
        if !output.isEmpty {
            let lines = output.components(separatedBy: "\n").count
            body.append(MarkdownText.code(clippedLines(output, count: isExpanded ? 100 : 5, fromStart: true), language: MarkdownText.language(forPath: path), font: codeFont, textColor: textColor))
            return ("Read", shortPath(tool?.summary ?? path, isExpanded: isExpanded) + (isExpanded ? "" : "  \(lines) lines"), body)
        }
        return ("Read", shortPath(tool?.summary ?? path, isExpanded: isExpanded), body)
    case let .write(path, content):
        let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
        body.append(MarkdownText.code(clippedLines(content, count: isExpanded ? 100 : 6, fromStart: true), language: MarkdownText.language(forPath: path), font: codeFont, textColor: textColor))
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
        let shown = isExpanded ? lines.prefix(160) : lines.prefix(10)
        for (index, line) in shown.enumerated() {
            if index > 0 {
                body.append(NSAttributedString(string: "\n"))
            }
            let color = line.hasPrefix("+") ? added : (line.hasPrefix("-") ? removed : textColor)
            body.append(NSAttributedString(string: line, font: codeFont, textColor: color))
        }
        if shown.count < lines.count {
            body.append(NSAttributedString(string: "\n…", font: codeFont, textColor: textColor))
        }
        if tool?.status == .failed, !output.isEmpty {
            body.append(NSAttributedString(string: "\n" + output, font: codeFont, textColor: removed))
        }
        return ("Edit", shortPath(path, isExpanded: isExpanded) + "  +\(addedCount) −\(removedCount)", body)
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
            body.append(NSAttributedString(string: clippedLines(output, count: isExpanded ? 80 : (isActive ? 4 : 6), fromStart: fromStart), font: toolFont, textColor: textColor))
        }
        return (name == "subagent" ? "Subagent" : name, tool?.summary ?? "", body)
    }
}
