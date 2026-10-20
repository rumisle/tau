// tau shim for Telegram's EmojiStatusComponent module (premium emoji statuses), used by the reaction preview.
import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramCore
import AccountContext
import AnimationCache
import MultiAnimationRenderer

public final class EmojiStatusComponent: Component {
    public enum AnimationContent: Equatable {
        case file(file: TelegramMediaFile)
        case customEmoji(fileId: Int64)
    }

    public enum LoopMode: Equatable {
        case forever
        case count(Int)
    }

    public enum Content: Equatable {
        case none
        case premium(color: UIColor)
        case animation(content: AnimationContent, size: CGSize, placeholderColor: UIColor, themeColor: UIColor?, loopMode: LoopMode)
    }

    public let content: Content

    public init(context: AccountContext, animationCache: AnimationCache, animationRenderer: MultiAnimationRenderer, content: Content, particleColor: UIColor? = nil, isVisibleForAnimations: Bool, useSharedAnimation: Bool = false, action: (() -> Void)?, emojiFileUpdated: ((TelegramMediaFile?) -> Void)? = nil) {
        self.content = content
    }

    public static func ==(lhs: EmojiStatusComponent, rhs: EmojiStatusComponent) -> Bool {
        return lhs.content == rhs.content
    }

    public final class View: UIView {
    }

    public func makeView() -> View {
        return View()
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return availableSize
    }
}
