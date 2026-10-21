import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData

/// A chat's new answer as Telegram's in-app banner shows a message (ChatMessageNotificationItem): the chat's avatar,
/// its title, two lines of the answer. A tap opens the chat; banners of one chat replace each other.
final class ChatNotificationItem: NotificationItem {
    let conversationId: Int
    let title: String
    let text: String
    let theme: PresentationTheme
    private let tapAction: () -> Bool

    var groupingKey: AnyHashable? {
        return self.conversationId
    }

    init(conversationId: Int, title: String, text: String, theme: PresentationTheme, tapAction: @escaping () -> Bool) {
        self.conversationId = conversationId
        self.title = title
        self.text = text
        self.theme = theme
        self.tapAction = tapAction
    }

    func node(compact: Bool) -> NotificationItemNode {
        let node = ChatNotificationItemNode()
        node.setup(self, compact: compact)
        return node
    }

    func tapped(_ take: @escaping () -> (ASDisplayNode?, () -> Void)) {
        let _ = self.tapAction()
    }

    func canBeExpanded() -> Bool {
        return false
    }

    func expand(_ take: @escaping () -> (ASDisplayNode?, () -> Void)) {
    }
}

/// ChatMessageNotificationItemNode's layout: 74 pt (64 compact), a 54 pt avatar (40) 12 pt from the edge, a 16 pt
/// semibold title over two lines of 16 pt text (15 compact).
private final class ChatNotificationItemNode: NotificationItemNode {
    private let avatarNode = ASImageNode()
    private let titleNode = TextNode()
    private let textNode = TextNode()
    private var titleText: NSAttributedString?
    private var bodyText: NSAttributedString?
    private var compact = false
    private var item: ChatNotificationItem?

    override init() {
        super.init()
        self.avatarNode.displaysAsynchronously = false
        self.titleNode.isUserInteractionEnabled = false
        self.textNode.isUserInteractionEnabled = false
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.textNode)
    }

    func setup(_ item: ChatNotificationItem, compact: Bool) {
        self.item = item
        self.compact = compact
        let colors = item.theme.inAppNotification
        self.titleText = NSAttributedString(string: item.title, font: compact ? Font.semibold(15.0) : Font.semibold(16.0), textColor: colors.primaryTextColor)
        let flat = item.text.replacingOccurrences(of: "\n", with: " ")
        self.bodyText = NSAttributedString(string: flat, font: compact ? Font.regular(15.0) : Font.regular(16.0), textColor: colors.primaryTextColor)
        let diameter: CGFloat = compact ? 40.0 : 54.0
        self.avatarNode.image = Avatar.image(letters: Avatar.letters(item.title), colorIndex: item.conversationId, diameter: diameter)
    }

    override func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        let compact = self.compact
        let panelHeight: CGFloat = compact ? 64.0 : 74.0
        let imageSize = compact ? CGSize(width: 40.0, height: 40.0) : CGSize(width: 54.0, height: 54.0)
        let imageSpacing: CGFloat = compact ? 22.0 : 23.0
        let leftInset: CGFloat = imageSize.width + imageSpacing
        let rightInset: CGFloat = 10.0
        transition.updateFrame(node: self.avatarNode, frame: CGRect(origin: CGPoint(x: 12.0, y: (panelHeight - imageSize.height) / 2.0), size: imageSize))

        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: self.titleText, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(0.0, width - leftInset - rightInset), height: CGFloat.greatestFiniteMagnitude), alignment: .left, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: self.bodyText, backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: max(0.0, width - leftInset - rightInset), height: CGFloat.greatestFiniteMagnitude), alignment: .left, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))
        let _ = titleApply()
        let _ = textApply()
        let textSpacing: CGFloat = 1.0
        let titleFrame = CGRect(origin: CGPoint(x: leftInset, y: floor((panelHeight - textLayout.size.height - titleLayout.size.height - textSpacing) / 2.0)), size: titleLayout.size)
        transition.updateFrame(node: self.titleNode, frame: titleFrame)
        transition.updateFrame(node: self.textNode, frame: CGRect(origin: CGPoint(x: leftInset, y: titleFrame.maxY + textSpacing), size: textLayout.size))
        return panelHeight
    }
}
