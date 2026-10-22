import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import ActivityIndicator

/// Telegram's ChatLoadingNode (TelegramUI/Components/Chat/ChatLoadingNode), the spinner in a service-colored circle a
/// chat shows while its history is not on the phone yet. Copied without the module, whose other half (the group chats'
/// shimmering placeholder bubbles) needs Telegram's message items; the blur setting comes from the theme alone.
final class ChatLoadingNode: ASDisplayNode {
    private let backgroundNode: NavigationBackgroundNode
    private let activityIndicator: ActivityIndicator
    private let offset: CGPoint

    init(theme: PresentationTheme, chatWallpaper: TelegramWallpaper) {
        self.backgroundNode = NavigationBackgroundNode(color: selectDateFillStaticColor(theme: theme, wallpaper: chatWallpaper), enableBlur: dateFillNeedsBlur(theme: theme, wallpaper: chatWallpaper))

        let serviceColor = serviceMessageColorComponents(theme: theme, wallpaper: chatWallpaper)
        self.activityIndicator = ActivityIndicator(type: .custom(serviceColor.primaryText, 22.0, 2.0, false), speed: .regular)
        if serviceColor.primaryText != .white {
            self.offset = CGPoint(x: 0.5, y: 0.5)
        } else {
            self.offset = CGPoint()
        }

        super.init()

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.activityIndicator)
    }

    func updateLayout(size: CGSize, insets: UIEdgeInsets, transition: ContainedViewLayoutTransition) {
        let displayRect = CGRect(origin: CGPoint(x: 0.0, y: insets.top), size: CGSize(width: size.width, height: size.height - insets.top - insets.bottom))

        let backgroundSize: CGFloat = 30.0
        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(x: displayRect.minX + floor((displayRect.width - backgroundSize) / 2.0), y: displayRect.minY + floor((displayRect.height - backgroundSize) / 2.0)), size: CGSize(width: backgroundSize, height: backgroundSize)))
        self.backgroundNode.update(size: self.backgroundNode.bounds.size, cornerRadius: self.backgroundNode.bounds.height / 2.0, transition: transition)

        let activitySize = self.activityIndicator.measure(size)
        transition.updateFrame(node: self.activityIndicator, frame: CGRect(origin: CGPoint(x: displayRect.minX + floor((displayRect.width - activitySize.width) / 2.0) + self.offset.x, y: displayRect.minY + floor((displayRect.height - activitySize.height) / 2.0) + self.offset.y), size: activitySize))
    }

    var progressFrame: CGRect {
        return self.backgroundNode.frame
    }
}
