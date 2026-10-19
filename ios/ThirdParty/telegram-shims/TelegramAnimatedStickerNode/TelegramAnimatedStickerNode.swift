// tau shim for Telegram's TelegramAnimatedStickerNode module.
import Foundation
import UIKit
import LottieSettings
import AnimatedStickerNode

public final class DefaultAnimatedStickerNodeImpl: AnimatedStickerNode {
    public init(lottieSettings: LottieRenderingSettings = .noAccountFallback) {
        super.init()
    }
}
