// tau shim for Telegram's AnimatedStickerComponent: the bundled animations it plays (the attachment menu's tab icons)
// go through LottieComponent, Telegram's other Lottie player, which tau copies.
import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramCore
import LottieComponent
import LottieSettings

public final class AnimatedStickerComponent: Component {
    public struct Animation: Equatable {
        public enum Source: Equatable {
            case bundle(name: String)
            case file(media: TelegramMediaFile)
        }

        public var source: Source
        public var scale: CGFloat
        public var loop: Bool

        public init(source: Source, scale: CGFloat = 2.0, loop: Bool) {
            self.source = source
            self.scale = scale
            self.loop = loop
        }
    }

    public let animation: Animation
    public let tintColor: UIColor?
    public let isAnimating: Bool
    public let size: CGSize

    public init(account: Account, animation: Animation, tintColor: UIColor? = nil, isAnimating: Bool = true, size: CGSize, lottieSettings: LottieRenderingSettings = .noAccountFallback) {
        self.animation = animation
        self.tintColor = tintColor
        self.isAnimating = isAnimating
        self.size = size
    }

    public static func ==(lhs: AnimatedStickerComponent, rhs: AnimatedStickerComponent) -> Bool {
        return lhs.animation == rhs.animation && lhs.tintColor == rhs.tintColor && lhs.isAnimating == rhs.isAnimating && lhs.size == rhs.size
    }

    public final class View: UIView {
        private let lottie = ComponentView<Empty>()
        private var component: AnimatedStickerComponent?

        func update(component: AnimatedStickerComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            let previous = self.component
            self.component = component
            guard case let .bundle(name) = component.animation.source else {
                return availableSize
            }
            let size = self.lottie.update(
                transition: .immediate,
                component: AnyComponent(LottieComponent(content: LottieComponent.AppBundleContent(name: name), color: component.tintColor, size: component.size, lottieSettings: .noAccountFallback)),
                environment: {},
                containerSize: component.size
            )
            if let view = self.lottie.view as? LottieComponent.View {
                if view.superview == nil {
                    self.addSubview(view)
                }
                view.frame = CGRect(origin: CGPoint(x: floor((availableSize.width - size.width) / 2.0), y: floor((availableSize.height - size.height) / 2.0)), size: size)
                // Plays once each time the tab becomes selected, as Telegram's tab icons do.
                if component.isAnimating && previous?.isAnimating != true {
                    view.playOnce()
                }
            }
            return availableSize
        }
    }

    public func makeView() -> View {
        return View()
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}
