// tau shim for Telegram's ReactionSelectionNode module: the reaction bar above a context menu. tau never passes
// reaction items, so the context menu never creates one; these declarations keep its reaction code compiling.
import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AnimationCache
import MultiAnimationRenderer
import EntityKeyboard

public final class ReactionItem {
    public struct Reaction: Equatable {
        public var rawValue: MessageReaction.Reaction

        public init(rawValue: MessageReaction.Reaction) {
            self.rawValue = rawValue
        }
    }

    public let reaction: ReactionItem.Reaction
    public let isCustom: Bool

    public init(reaction: ReactionItem.Reaction, isCustom: Bool) {
        self.reaction = reaction
        self.isCustom = isCustom
    }
}

public enum ReactionContextItem: Equatable {
    case staticEmoji(String)
    case reaction(item: ReactionItem, icon: EmojiPagerContentComponent.Item.Icon)
    case premium

    public static func ==(lhs: ReactionContextItem, rhs: ReactionContextItem) -> Bool {
        switch (lhs, rhs) {
        case let (.staticEmoji(l), .staticEmoji(r)):
            return l == r
        case let (.reaction(l, lIcon), .reaction(r, rIcon)):
            return l.reaction == r.reaction && lIcon == rIcon
        case (.premium, .premium):
            return true
        default:
            return false
        }
    }

    public var reaction: ReactionItem.Reaction? {
        if case let .reaction(item, _) = self {
            return item.reaction
        }
        return nil
    }
}

public final class ReactionContextNode: ASDisplayNode {
    public enum Style {
        case legacy
        case glass(isTinted: Bool)
    }

    public var reactionSelected: ((UpdateMessageReaction, Bool) -> Void)?
    public var premiumReactionsSelected: ((TelegramMediaFile?) -> Void)?
    public var displayTail: Bool = true
    public var contentHeight: CGFloat { 0.0 }
    public private(set) var isExpanded: Bool = false
    public private(set) var canBeExpanded: Bool = false
    public private(set) var visibleExtensionDistance: CGFloat = 0.0
    public let alwaysAllowPremiumReactions: Bool

    public init(context: AccountContext, animationCache: AnimationCache, presentationData: PresentationData, style: Style = .legacy, items: [ReactionContextItem], selectedItems: Set<AnyHashable>, title: String? = nil, reactionsLocked: Bool, alwaysAllowPremiumReactions: Bool, allPresetReactionsAreAvailable: Bool, getEmojiContent: ((AnimationCache, MultiAnimationRenderer) -> Signal<EmojiPagerContentComponent, NoError>)?, isExpandedUpdated: @escaping (ContainedViewLayoutTransition) -> Void, requestLayout: @escaping (ContainedViewLayoutTransition) -> Void, requestUpdateOverlayWantsToBeBelowKeyboard: @escaping (ContainedViewLayoutTransition) -> Void) {
        self.alwaysAllowPremiumReactions = alwaysAllowPremiumReactions
        super.init()
    }

    public func updateLayout(size: CGSize, insets: UIEdgeInsets, anchorRect: CGRect, centerAligned: Bool = false, isCoveredByInput: Bool, isAnimatingOut: Bool, forceUpdate: Bool = false, transition: ContainedViewLayoutTransition) {
    }

    public func updateIsIntersectingContent(isIntersectingContent: Bool, transition: ContainedViewLayoutTransition) {
    }

    public func updateExtension(distance: CGFloat) {
    }

    public func wantsDisplayBelowKeyboard() -> Bool {
        return false
    }

    public func animateIn(from sourceAnchorRect: CGRect) {
    }

    public func animateOut(to targetAnchorRect: CGRect?, animatingOutToReaction: Bool) {
    }

    public func willAnimateOutToReaction(value: MessageReaction.Reaction) {
    }

    public func animateOutToReaction(value: MessageReaction.Reaction, targetView: UIView, hideNode: Bool, forceSwitchToInlineImmediately: Bool = false, animateTargetContainer: UIView?, addStandaloneReactionAnimation: ((StandaloneReactionAnimation) -> Void)?, onHit: (() -> Void)?, completion: @escaping () -> Void) {
        completion()
    }

    public func hasSpaceInTheBottom(insets: UIEdgeInsets, height: CGFloat) -> Bool {
        return true
    }

    public func expand() {
    }

    public func highlightGestureMoved(location: CGPoint, hover: Bool) {
    }

    public func highlightGestureFinished(performAction: Bool) {
    }

    public func cancelReactionAnimation() {
    }
}

public final class StandaloneReactionAnimation: ASDisplayNode {
    public init(genericReactionEffect: String?, useDirectRendering: Bool = false) {
        super.init()
    }
}
