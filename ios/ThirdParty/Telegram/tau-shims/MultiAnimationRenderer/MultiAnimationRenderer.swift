// tau shim for Telegram's MultiAnimationRenderer module (renders many custom emoji animations in one pass).
import Foundation
import UIKit
import AnimationCache

public protocol MultiAnimationRenderer: AnyObject {
}

/// A layer the renderer draws animation frames into.
open class MultiAnimationRenderTarget: CALayer {
    override public init() {
        super.init()
    }

    override public init(layer: Any) {
        super.init(layer: layer)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
