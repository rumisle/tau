import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

/// One chat list row. A trimmed port of Telegram-iOS ChatListUI/Sources/Node/ChatListItem.swift: same metrics (60 pt
/// avatar, 16/15/14 pt fonts, the same height formula and frames), with the peer replaced by a dialog whose project
/// directory takes the place of a group message's author line.
final class ChatListItem: ListViewItem {
    let theme: TauTheme
    let dialog: DialogModel
    let action: (DialogModel) -> Void

    init(theme: TauTheme, dialog: DialogModel, action: @escaping (DialogModel) -> Void) {
        self.theme = theme
        self.dialog = dialog
        self.action = action
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return true
    }

    var approximateHeight: CGFloat {
        return 76.0
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action(self.dialog)
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = ChatListItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)
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
            guard let nodeValue = node() as? ChatListItemNode else {
                assertionFailure()
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params)
                Queue.mainQueue().async {
                    completion(layout, { _ in apply(animation) })
                }
            }
        }
    }
}

private let separatorHeight = 1.0 / UIScreen.main.scale
private let avatarDiameter: CGFloat = 60.0
private let titleFont = Font.semibold(16.0)
private let textFont = Font.regular(15.0)
private let dateFont = Font.regular(14.0)

final class ChatListItemNode: ListViewItemNode {
    private let highlightedBackgroundNode: ASDisplayNode
    private let avatarNode: ASImageNode
    private let titleNode: TextNode
    private let authorNode: TextNode
    private let textNode: TextNode
    private let dateNode: TextNode
    private let separatorNode: ASDisplayNode
    private let busyIndicatorNode: BusyDotsNode

    private var item: ChatListItem?

    init() {
        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isLayerBacked = true
        self.highlightedBackgroundNode.alpha = 0.0

        self.avatarNode = ASImageNode()
        self.avatarNode.isLayerBacked = true
        self.avatarNode.displaysAsynchronously = false

        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.authorNode = TextNode()
        self.authorNode.isUserInteractionEnabled = false
        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false
        self.dateNode = TextNode()
        self.dateNode.isUserInteractionEnabled = false

        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true

        self.busyIndicatorNode = BusyDotsNode()

        super.init(layerBacked: false, rotated: false, seeThrough: false)

        self.addSubnode(self.highlightedBackgroundNode)
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.authorNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.dateNode)
        self.addSubnode(self.busyIndicatorNode)
    }

    override func layoutForParams(_ params: ListViewItemLayoutParams, item: ListViewItem, neighbors: ListViewItemNeighbors) {
        guard let item = item as? ChatListItem else {
            return
        }
        let (layout, apply) = self.asyncLayout()(item, params)
        apply(.None)
        self.contentSize = layout.contentSize
        self.insets = layout.insets
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        if highlighted {
            self.highlightedBackgroundNode.layer.removeAllAnimations()
            self.highlightedBackgroundNode.alpha = 1.0
        } else if animated {
            self.highlightedBackgroundNode.alpha = 0.0
            self.highlightedBackgroundNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3)
        } else {
            self.highlightedBackgroundNode.alpha = 0.0
        }
    }

    func asyncLayout() -> (_ item: ChatListItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeAuthorLayout = TextNode.asyncLayout(self.authorNode)
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        let makeDateLayout = TextNode.asyncLayout(self.dateNode)
        let currentItem = self.item

        return { [weak self] item, params in
            let theme = item.theme.chatList
            let dialog = item.dialog

            let avatarLeftInset: CGFloat = 24.0 + avatarDiameter
            let leftInset = params.leftInset + avatarLeftInset
            let rawContentWidth = params.width - leftInset - params.rightInset - 18.0

            let dateString = dialog.last.map { chatListDateString($0.date) } ?? ""
            let (dateLayout, dateApply) = makeDateLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: dateString, font: dateFont, textColor: theme.dateTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: rawContentWidth, height: .greatestFiniteMagnitude)))

            let titleRectWidth = rawContentWidth - dateLayout.size.width - 10.0
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: dialog.title, font: titleFont, textColor: theme.titleColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(10.0, titleRectWidth), height: .greatestFiniteMagnitude)))

            // The project directory reads like the author line of a group chat.
            let (authorLayout, authorApply) = makeAuthorLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: dialog.projectName, font: textFont, textColor: theme.authorNameColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: rawContentWidth, height: .greatestFiniteMagnitude)))

            let busyIndicatorWidth: CGFloat = dialog.busy ? 24.0 : 0.0
            let textString: NSAttributedString
            if dialog.busy {
                textString = NSAttributedString(string: "working", font: textFont, textColor: theme.activityTextColor)
            } else if let last = dialog.last {
                let prefix: String
                switch last.role {
                case .user:
                    prefix = "You: "
                case .assistant:
                    prefix = ""
                case let .tool(name):
                    prefix = "\(name): "
                }
                let flat = (prefix + plainPreview(last.text)).replacingOccurrences(of: "\n", with: " ")
                textString = NSAttributedString(string: flat, font: textFont, textColor: theme.messageTextColor)
            } else {
                textString = NSAttributedString(string: "No messages yet", font: textFont, textColor: theme.messageTextColor)
            }
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: textString, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: rawContentWidth - busyIndicatorWidth, height: .greatestFiniteMagnitude)))

            // Telegram measures one line of the title font to size the row (ChatListItem.swift, "measureLayout").
            let (measureLayout, _) = TextNode.asyncLayout(nil)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: " ", font: titleFont, textColor: .black), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: titleRectWidth, height: .greatestFiniteMagnitude)))
            let measureHeight = measureLayout.size.height
            let titleSpacing: CGFloat = -1.0
            let authorSpacing: CGFloat = -3.0
            var itemHeight: CGFloat = 8.0 * 2.0 + 1.0
            itemHeight -= 21.0
            itemHeight += titleLayout.size.height
            itemHeight += measureHeight * 3.0
            itemHeight += titleSpacing
            itemHeight += authorSpacing

            let rawContentRect = CGRect(origin: CGPoint(x: 2.0, y: 8.0), size: CGSize(width: rawContentWidth, height: itemHeight - 12.0 - 9.0))
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: itemHeight), insets: UIEdgeInsets())

            let avatarImage: UIImage?
            if currentItem?.dialog.title != dialog.title || currentItem?.dialog.id != dialog.id {
                avatarImage = Avatar.image(letters: Avatar.letters(dialog.title), colorIndex: dialog.id, diameter: avatarDiameter)
            } else {
                avatarImage = nil
            }

            return (layout, { animation in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                let transition = animation.transition

                strongSelf.highlightedBackgroundNode.backgroundColor = theme.itemHighlightedBackgroundColor
                strongSelf.separatorNode.backgroundColor = theme.itemSeparatorColor
                if let avatarImage {
                    strongSelf.avatarNode.image = avatarImage
                }

                let _ = titleApply()
                let _ = authorApply()
                let _ = textApply()
                let _ = dateApply()

                let contentRect = rawContentRect.offsetBy(dx: leftInset, dy: 0.0)
                let avatarFrame = CGRect(origin: CGPoint(x: params.leftInset + 16.0, y: floor((itemHeight - avatarDiameter) / 2.0)), size: CGSize(width: avatarDiameter, height: avatarDiameter))
                transition.updateFrame(node: strongSelf.avatarNode, frame: avatarFrame)

                let titleFrame = CGRect(origin: CGPoint(x: contentRect.origin.x, y: contentRect.origin.y + UIScreenPixel), size: titleLayout.size)
                transition.updateFrame(node: strongSelf.titleNode, frame: titleFrame)

                let authorFrame = CGRect(origin: CGPoint(x: contentRect.origin.x - 1.0, y: contentRect.minY + titleLayout.size.height - 2.0), size: authorLayout.size)
                transition.updateFrame(node: strongSelf.authorNode, frame: authorFrame)

                let textFrame = CGRect(origin: CGPoint(x: contentRect.origin.x - 1.0 + busyIndicatorWidth, y: authorFrame.minY + authorLayout.size.height - 3.0), size: textLayout.size)
                transition.updateFrame(node: strongSelf.textNode, frame: textFrame)

                strongSelf.busyIndicatorNode.isHidden = !dialog.busy
                strongSelf.busyIndicatorNode.color = theme.activityTextColor
                transition.updateFrame(node: strongSelf.busyIndicatorNode, frame: CGRect(origin: CGPoint(x: contentRect.origin.x, y: textFrame.midY - 4.0), size: CGSize(width: 20.0, height: 8.0)))

                let dateFrame = CGRect(origin: CGPoint(x: contentRect.maxX - dateLayout.size.width, y: contentRect.origin.y + 2.0), size: dateLayout.size)
                transition.updateFrame(node: strongSelf.dateNode, frame: dateFrame)

                let separatorX = leftInset + rawContentRect.origin.x
                transition.updateFrame(node: strongSelf.separatorNode, frame: CGRect(origin: CGPoint(x: separatorX, y: itemHeight - separatorHeight), size: CGSize(width: params.width - separatorX, height: separatorHeight)))
                strongSelf.highlightedBackgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -separatorHeight), size: CGSize(width: params.width, height: itemHeight + separatorHeight))
            })
        }
    }
}

/// Message text without Markdown syntax, for one-line previews.
func plainPreview(_ text: String) -> String {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    guard let parsed = try? AttributedString(markdown: text, options: options) else {
        return text
    }
    return String(parsed.characters)
}

/// Telegram's chat list date: time today, weekday this week, date otherwise.
func chatListDateString(_ date: Date) -> String {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        formatter.dateFormat = "EEE"
    } else {
        formatter.dateFormat = "dd.MM.yy"
    }
    return formatter.string(from: date)
}

/// Three pulsing dots, like Telegram's typing indicator in the chat list.
final class BusyDotsNode: ASDisplayNode {
    private let dots: [CALayer] = (0 ..< 3).map { _ in CALayer() }

    var color: UIColor = .black {
        didSet {
            for dot in self.dots {
                dot.backgroundColor = self.color.cgColor
            }
        }
    }

    override init() {
        super.init()
        for (index, dot) in self.dots.enumerated() {
            dot.cornerRadius = 2.5
            self.layer.addSublayer(dot)
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.3, 1.0, 0.3]
            animation.keyTimes = [0.0, 0.5, 1.0]
            animation.duration = 1.0
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            dot.add(animation, forKey: "pulse")
        }
    }

    override func layout() {
        super.layout()
        for (index, dot) in self.dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * 7.0, y: (self.bounds.height - 5.0) / 2.0, width: 5.0, height: 5.0)
        }
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        // Layers drop animations when they leave the window; restart them.
        for (index, dot) in self.dots.enumerated() where dot.animation(forKey: "pulse") == nil {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.3, 1.0, 0.3]
            animation.keyTimes = [0.0, 0.5, 1.0]
            animation.duration = 1.0
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            dot.add(animation, forKey: "pulse")
        }
    }
}
