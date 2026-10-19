// tau shim for Telegram's ChatMessageBackground module: bubble backgrounds of the selected-photos preview.
import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import WallpaperBackgroundNode

public enum ChatMessageBackgroundMergeType: Equatable {
    case None
    case Extracted
}

public enum ChatMessageBackgroundType: Equatable {
    case none
    case incoming(ChatMessageBackgroundMergeType)
    case outgoing(ChatMessageBackgroundMergeType)
}

public final class ChatMessageBackground: ASDisplayNode {
    public func setType(type: ChatMessageBackgroundType, highlighted: Bool, graphics: PrincipalThemeEssentialGraphics, maskMode: Bool, hasWallpaper: Bool, transition: ContainedViewLayoutTransition, backgroundNode: WallpaperBackgroundNode?) {
    }

    public func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
    }
}

public final class ChatMessageBubbleBackdrop: ASDisplayNode {
    public func setType(type: ChatMessageBackgroundType, theme: ChatPresentationThemeData, essentialGraphics: PrincipalThemeEssentialGraphics, maskMode: Bool, backgroundNode: WallpaperBackgroundNode?) {
    }
}

public final class ChatMessageShadowNode: ASDisplayNode {
    public func setType(type: ChatMessageBackgroundType, hasWallpaper: Bool, graphics: PrincipalThemeEssentialGraphics) {
    }

    public func updateLayout(backgroundFrame: CGRect, transition: ContainedViewLayoutTransition) {
    }
}

extension ChatMessageBubbleBackdrop {
    public func updateFrame(_ frame: CGRect, transition: ContainedViewLayoutTransition) {
        transition.updateFrame(node: self, frame: frame)
    }
}
