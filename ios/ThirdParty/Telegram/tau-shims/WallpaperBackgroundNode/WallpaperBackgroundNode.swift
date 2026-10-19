// tau shim for Telegram's WallpaperBackgroundNode module: the media picker's preview of selected photos as message
// bubbles sits on one. tau's is a plain node.
import Foundation
import UIKit
import AsyncDisplayKit
import Display
import AccountContext
import TelegramCore
import TelegramPresentationData

public protocol WallpaperBackgroundNode: ASDisplayNode {
    func update(wallpaper: TelegramWallpaper, animated: Bool)
    func updateBubbleTheme(bubbleTheme: PresentationTheme, bubbleCorners: PresentationChatBubbleCorners)
    func updateLayout(size: CGSize, displayMode: WallpaperDisplayMode, transition: ContainedViewLayoutTransition)
}

public enum WallpaperDisplayMode {
    case aspectFill
    case aspectFit
    case halfAspectFill
}

private final class PlainWallpaperBackgroundNode: ASDisplayNode, WallpaperBackgroundNode {
    func update(wallpaper: TelegramWallpaper, animated: Bool) {
    }

    func updateBubbleTheme(bubbleTheme: PresentationTheme, bubbleCorners: PresentationChatBubbleCorners) {
    }

    func updateLayout(size: CGSize, displayMode: WallpaperDisplayMode, transition: ContainedViewLayoutTransition) {
    }
}

public func createWallpaperBackgroundNode(context: AccountContext, forChatDisplay: Bool, useSharedAnimationPhase: Bool = false) -> WallpaperBackgroundNode {
    return PlainWallpaperBackgroundNode()
}
