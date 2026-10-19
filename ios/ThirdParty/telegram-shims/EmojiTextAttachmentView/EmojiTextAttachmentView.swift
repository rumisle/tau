// tau shim for Telegram's EmojiTextAttachmentView module: the custom emoji layer that text nodes embed. Custom emoji
// need a Telegram account to load, which tau never has, so the layer stays empty.
import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext
import AnimationCache
import MultiAnimationRenderer
import TextFormat

public final class InlineStickerItemLayer: MultiAnimationRenderTarget {
    public struct Key: Hashable {
        public var id: Int64
        public var index: Int

        public init(id: Int64, index: Int) {
            self.id = id
            self.index = index
        }
    }

    public enum Context {
        case account(AccountContext)
    }

    public private(set) var file: TelegramMediaFile?
    public var dynamicColor: UIColor?
    public var isVisibleForAnimations: Bool = false
    public var enableAnimation: Bool = true

    public init(context: AccountContext, userLocation: MediaResourceUserLocation, attemptSynchronousLoad: Bool, emoji: ChatTextInputTextCustomEmojiAttribute, file: TelegramMediaFile?, cache: AnimationCache, renderer: MultiAnimationRenderer, unique: Bool = false, placeholderColor: UIColor, pointSize: CGSize, dynamicColor: UIColor? = nil, loopCount: Int? = nil) {
        self.file = file
        self.dynamicColor = dynamicColor
        super.init()
    }

    override public init(layer: Any) {
        super.init(layer: layer)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func reloadAnimation() {
    }
}
