import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import InteractiveTextComponent
import StreamingTextReveal

/// What a message's neighbors need to know about it: who wrote it, so consecutive user bubbles merge.
private enum ChatHistoryNeighbor: Equatable {
    case user
    case assistant
    case tool
}

/// One transcript row in the inverted chat list. User messages are Telegram outgoing bubbles; the assistant writes
/// straight on the wallpaper with no bubble; tool results are compact cards. Layout constants follow Telegram-iOS
/// ChatMessageItemLayoutConstants.compact and ChatMessageBubbleItemNode.
final class ChatMessageItem: ListViewItem {
    let theme: TauTheme
    let message: ChatMessage
    let isStreaming: Bool
    /// Asks the list to lay this row out again, for example when revealed streaming text wraps to a new line.
    let requestRelayout: (Int) -> Void

    init(theme: TauTheme, message: ChatMessage, isStreaming: Bool, requestRelayout: @escaping (Int) -> Void) {
        self.theme = theme
        self.message = message
        self.isStreaming = isStreaming
        self.requestRelayout = requestRelayout
    }

    var neighborDescriptor: AnyEquatable {
        switch self.message.role {
        case .user:
            return AnyEquatable(ChatHistoryNeighbor.user)
        case .assistant:
            return AnyEquatable(ChatHistoryNeighbor.assistant)
        case .tool:
            return AnyEquatable(ChatHistoryNeighbor.tool)
        }
    }

    var approximateHeight: CGFloat {
        return 60.0
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

// Telegram ChatMessageItemLayoutConstants.compact.
private let bubbleEdgeInset: CGFloat = 3.0
private let bubbleTailInset: CGFloat = 6.0
private let bubbleMinimumSize = CGSize(width: 40.0, height: 35.0)
private let textInsets = UIEdgeInsets(top: 6.0 + UIScreenPixel, left: 11.0, bottom: 6.0 - UIScreenPixel, right: 11.0)
private let defaultSpacing: CGFloat = 4.0
private let mergedSpacing: CGFloat = 1.0
/// Margins of bubble-less assistant text.
private let freeTextInset: CGFloat = 16.0

final class ChatMessageItemNode: ListViewItemNode {
    private let backgroundNode: ASImageNode
    private let textNode: InteractiveTextNode
    private let dateNode: TextNode
    private let toolBackgroundNode: ASDisplayNode
    private let toolTitleNode: TextNode
    private let toolTextNode: TextNode

    private var item: ChatMessageItem?
    private var revealController: TextRevealController?
    private var revealLink: SharedDisplayLinkDriver.Link?

    init() {
        self.backgroundNode = ASImageNode()
        self.backgroundNode.isLayerBacked = true
        self.backgroundNode.displaysAsynchronously = false
        self.backgroundNode.displayWithoutProcessing = true

        self.textNode = InteractiveTextNode()
        self.textNode.isUserInteractionEnabled = false

        self.dateNode = TextNode()
        self.dateNode.isUserInteractionEnabled = false

        self.toolBackgroundNode = ASDisplayNode()
        self.toolBackgroundNode.isLayerBacked = true
        self.toolBackgroundNode.cornerRadius = 12.0
        self.toolTitleNode = TextNode()
        self.toolTextNode = TextNode()

        super.init(layerBacked: false, rotated: true)

        // Items of an inverted list are rotated back upright, as Telegram's chat items are.
        self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.toolBackgroundNode)
        self.addSubnode(self.toolTitleNode)
        self.addSubnode(self.toolTextNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.dateNode)
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
            // A sent message rises from the input field, as in Telegram.
            self.layer.animatePosition(from: CGPoint(x: 0.0, y: -40.0), to: CGPoint(), duration: duration, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
        }
    }

    override func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        super.animateRemoved(currentTimestamp, duration: duration)
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
    }

    func asyncLayout() -> (_ item: ChatMessageItem, _ params: ListViewItemLayoutParams, _ neighbors: ListViewItemNeighbors) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTextLayout = InteractiveTextNode.asyncLayout(self.textNode)
        let makeDateLayout = TextNode.asyncLayout(self.dateNode)
        let makeToolTitleLayout = TextNode.asyncLayout(self.toolTitleNode)
        let makeToolTextLayout = TextNode.asyncLayout(self.toolTextNode)
        let currentRevealCount = self.revealController.map { Int($0.revealedCount) }

        return { [weak self] item, params, neighbors in
            let theme = item.theme.chat
            let message = item.message
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
                let maxTextWidth = fillWidth - bubbleEdgeInset * 2.0 - bubbleTailInset - textInsets.left - textInsets.right

                let style = MarkdownStyle(fontSize: messageFontSize, textColor: theme.outgoing.primaryTextColor, linkColor: theme.outgoing.linkTextColor, accentColor: theme.outgoing.secondaryTextColor)
                let (textLayout, textApply) = makeTextLayout(InteractiveTextNodeLayoutArguments(attributedString: MarkdownText.render(message.text, style: style), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude)))
                let (dateLayout, dateApply) = makeDateLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: messageTimeString(message.date), font: dateFont, textColor: theme.outgoing.secondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 100.0, height: 20.0)))

                // The time shares the last line when it fits, as ChatMessageDateAndStatusNode's trailing layout does.
                let dateSpacing: CGFloat = 6.0
                var textAreaSize = textLayout.size
                let trailingWidth = textLayout.trailingLineWidth + dateSpacing + dateLayout.size.width
                if trailingWidth <= maxTextWidth {
                    textAreaSize.width = max(textAreaSize.width, trailingWidth)
                } else {
                    textAreaSize.width = max(textAreaSize.width, dateLayout.size.width)
                    textAreaSize.height += dateLayout.size.height
                }

                let bubbleSize = CGSize(
                    width: max(bubbleMinimumSize.width, textAreaSize.width + textInsets.left + textInsets.right) + bubbleTailInset,
                    height: max(bubbleMinimumSize.height, textAreaSize.height + textInsets.top + textInsets.bottom)
                )
                let insets = UIEdgeInsets(top: mergedTop ? mergedSpacing : defaultSpacing, left: 0.0, bottom: mergedBottom ? mergedSpacing : defaultSpacing, right: 0.0)
                let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: bubbleSize.height), insets: insets)
                let bubbleImage = BubbleImageCache.shared.image(incoming: false, neighbors: bubbleNeighbors, color: theme.outgoing.fill)

                return (layout, { animation in
                    guard let self else {
                        return
                    }
                    self.item = item
                    self.stopReveal()
                    self.toolBackgroundNode.isHidden = true
                    self.toolTitleNode.isHidden = true
                    self.toolTextNode.isHidden = true
                    self.backgroundNode.isHidden = false
                    self.dateNode.isHidden = false
                    self.textNode.isHidden = false

                    let backgroundFrame = CGRect(origin: CGPoint(x: params.width - params.rightInset - bubbleEdgeInset - bubbleSize.width, y: 0.0), size: bubbleSize)
                    self.backgroundNode.image = bubbleImage
                    // The image draws its shape 1 pt inside its bounds (ChatMessageBackground.updateLayout).
                    animation.animator.updateFrame(layer: self.backgroundNode.layer, frame: backgroundFrame.insetBy(dx: -1.0, dy: -1.0), completion: nil)

                    let _ = textApply(InteractiveTextNode.ApplyArguments(animation: animation, spoilerTextColor: theme.outgoing.primaryTextColor, spoilerEffectColor: theme.outgoing.primaryTextColor, areContentAnimationsEnabled: true, spoilerExpandRect: nil))
                    let textFrame = CGRect(origin: CGPoint(x: backgroundFrame.minX + textInsets.left, y: textInsets.top), size: textLayout.size)
                    animation.animator.updateFrame(layer: self.textNode.layer, frame: textFrame, completion: nil)

                    let _ = dateApply()
                    let dateFrame = CGRect(origin: CGPoint(x: backgroundFrame.maxX - bubbleTailInset - textInsets.right - dateLayout.size.width, y: backgroundFrame.maxY - textInsets.bottom - dateLayout.size.height + 1.0), size: dateLayout.size)
                    animation.animator.updateFrame(layer: self.dateNode.layer, frame: dateFrame, completion: nil)
                })

            case .assistant:
                let mergedTop = above == .assistant || above == .tool
                let maxTextWidth = contentWidth - freeTextInset * 2.0
                let style = MarkdownStyle(fontSize: messageFontSize, textColor: theme.freeTextColor, linkColor: theme.incoming.linkTextColor, accentColor: item.theme.accentColor)
                let (textLayout, textApply) = makeTextLayout(InteractiveTextNodeLayoutArguments(attributedString: MarkdownText.render(message.text, style: style), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude)))

                // While streaming, the row is as tall as the text revealed so far.
                var textSize = textLayout.size
                if item.isStreaming || currentRevealCount != nil {
                    let revealed = currentRevealCount ?? 0
                    textSize.height = textLayout.sizeForCharacterCount(characterCount: revealed).height
                }
                let insets = UIEdgeInsets(top: mergedTop ? 6.0 : 10.0, left: 0.0, bottom: 6.0, right: 0.0)
                let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: max(1.0, textSize.height)), insets: insets)

                return (layout, { animation in
                    guard let self else {
                        return
                    }
                    self.item = item
                    self.backgroundNode.isHidden = true
                    self.dateNode.isHidden = true
                    self.toolBackgroundNode.isHidden = true
                    self.toolTitleNode.isHidden = true
                    self.toolTextNode.isHidden = true

                    let _ = textApply(InteractiveTextNode.ApplyArguments(animation: animation, spoilerTextColor: theme.freeTextColor, spoilerEffectColor: theme.freeTextColor, areContentAnimationsEnabled: true, spoilerExpandRect: nil))
                    let textFrame = CGRect(origin: CGPoint(x: params.leftInset + freeTextInset, y: 0.0), size: textLayout.size)
                    animation.animator.updateFrame(layer: self.textNode.layer, frame: textFrame, completion: nil)

                    self.updateReveal(item: item, textLength: textLayout.attributedString?.length ?? 0)
                })

            case let .tool(name):
                let maxWidth = contentWidth - freeTextInset * 2.0 - 24.0
                let (titleLayout, titleApply) = makeToolTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: name, font: toolTitleFont, textColor: theme.serviceTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: maxWidth, height: 40.0)))
                let (textLayout, textApply) = makeToolTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: message.text, font: toolFont, textColor: theme.serviceTextColor), maximumNumberOfLines: 6, truncationType: .end, constrainedSize: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), lineSpacing: 0.1))

                let cardInsets = UIEdgeInsets(top: 8.0, left: 12.0, bottom: 9.0, right: 12.0)
                let cardSize = CGSize(
                    width: max(titleLayout.size.width, textLayout.size.width) + cardInsets.left + cardInsets.right,
                    height: titleLayout.size.height + 2.0 + textLayout.size.height + cardInsets.top + cardInsets.bottom
                )
                let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: cardSize.height), insets: UIEdgeInsets(top: 6.0, left: 0.0, bottom: 6.0, right: 0.0))

                return (layout, { animation in
                    guard let self else {
                        return
                    }
                    self.item = item
                    self.stopReveal()
                    self.backgroundNode.isHidden = true
                    self.dateNode.isHidden = true
                    self.textNode.isHidden = true
                    self.toolBackgroundNode.isHidden = false
                    self.toolTitleNode.isHidden = false
                    self.toolTextNode.isHidden = false

                    self.toolBackgroundNode.backgroundColor = theme.serviceBackgroundColor
                    let cardFrame = CGRect(origin: CGPoint(x: params.leftInset + freeTextInset - 4.0, y: 0.0), size: cardSize)
                    animation.animator.updateFrame(layer: self.toolBackgroundNode.layer, frame: cardFrame, completion: nil)

                    let _ = titleApply()
                    self.toolTitleNode.frame = CGRect(origin: CGPoint(x: cardFrame.minX + cardInsets.left, y: cardFrame.minY + cardInsets.top), size: titleLayout.size)
                    let _ = textApply()
                    self.toolTextNode.frame = CGRect(origin: CGPoint(x: cardFrame.minX + cardInsets.left, y: self.toolTitleNode.frame.maxY + 2.0), size: textLayout.size)
                })
            }
        }
    }

    // MARK: - Streaming reveal (after ChatMessageTextBubbleContentNode.updateTextRevealAnimation)

    private func updateReveal(item: ChatMessageItem, textLength: Int) {
        self.textNode.isHidden = false
        let now = CACurrentMediaTime()
        if item.isStreaming {
            if let controller = self.revealController {
                controller.observeUpdate(latestLength: textLength, at: now)
            } else {
                let controller = TextRevealController(initialRevealedCount: 0, initialLength: 0)
                controller.observeUpdate(latestLength: textLength, at: now)
                self.revealController = controller
                self.textNode.updateRevealCharacterCount(count: 0, animated: false)
            }
        } else if let controller = self.revealController {
            controller.finalize(finalLength: textLength)
        } else {
            return
        }

        guard self.revealLink == nil else {
            return
        }
        self.revealLink = SharedDisplayLinkDriver.shared.add { [weak self] _ in
            guard let self, let controller = self.revealController, let item = self.item else {
                self?.revealLink = nil
                return
            }
            let (count, isComplete) = controller.tick(now: CACurrentMediaTime())
            if isComplete {
                self.revealController = nil
                self.revealLink = nil
                self.textNode.updateRevealCharacterCount(count: nil, animated: false)
                item.requestRelayout(item.message.id)
                return
            }
            if let previous = self.textNode.revealCharacterCount, previous != count {
                var heightChanged = true
                if let layout = self.textNode.cachedLayout {
                    heightChanged = layout.sizeForCharacterCount(characterCount: previous).height != layout.sizeForCharacterCount(characterCount: count).height
                }
                self.textNode.updateRevealCharacterCount(count: count, animated: true)
                if heightChanged {
                    item.requestRelayout(item.message.id)
                }
            }
        }
    }

    private func stopReveal() {
        self.revealController = nil
        self.revealLink = nil
        if self.textNode.revealCharacterCount != nil {
            self.textNode.updateRevealCharacterCount(count: nil, animated: false)
        }
    }
}

func messageTimeString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
