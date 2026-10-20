// tau shim for Telegram-iOS AvatarNode, which draws peers' photos from the account's media. SearchBarNode shows one in
// a peer search token, which tau's searches never create.
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import TelegramPresentationData

public func avatarPlaceholderFont(size: CGFloat) -> UIFont {
    return Font.with(size: size, design: .round, weight: .bold)
}

public enum AvatarNodeClipStyle {
    case none
    case round
    case roundedRect
    case bubble
}

public final class AvatarNode: ASDisplayNode {
    public init(font: UIFont) {
        super.init()
    }

    public func setPeer(context: AccountContext, theme: PresentationTheme, peer: EnginePeer?, clipStyle: AvatarNodeClipStyle = .round, displayDimensions: CGSize) {
    }
}
