// tau shim for Telegram-iOS LottieComponent. The real one renders Lottie animations through rlottie, a C++ library that
// is a separate git submodule. This keeps LottieComponent's interface and renders nothing; copied modules that offer a
// static icon alternative (the tab bar's `.bundleIcon`) are used that way. Replace with the real module to get
// animated icons.
import UIKit
import Display
import ComponentFlow
import LottieSettings

public final class LottieComponent: Component {
    public typealias EnvironmentType = Empty

    open class Content: Equatable {
        public init() {
        }

        public static func ==(lhs: Content, rhs: Content) -> Bool {
            if lhs === rhs {
                return true
            }
            return lhs.isEqual(to: rhs)
        }

        open func isEqual(to other: Content) -> Bool {
            return false
        }
    }

    public final class AppBundleContent: Content {
        public let name: String
        public let frameRange: Range<Double>

        public init(name: String, frameRange: Range<Double> = 0.0 ..< 1.0) {
            self.name = name
            self.frameRange = frameRange
        }

        override public func isEqual(to other: Content) -> Bool {
            guard let other = other as? AppBundleContent else {
                return false
            }
            return self.name == other.name && self.frameRange == other.frameRange
        }
    }

    public enum StartingPosition: Equatable {
        case begin
        case end
        case fraction(Double)
    }

    public let content: Content
    public let color: UIColor?
    public let placeholderColor: UIColor?
    public let startingPosition: StartingPosition
    public let size: CGSize?
    public let renderingScale: CGFloat?
    public let loop: Bool
    public let playOnce: ActionSlot<Void>?
    public let lottieSettings: LottieRenderingSettings

    public init(
        content: Content,
        color: UIColor? = nil,
        placeholderColor: UIColor? = nil,
        startingPosition: StartingPosition = .end,
        size: CGSize? = nil,
        renderingScale: CGFloat? = nil,
        loop: Bool = false,
        playOnce: ActionSlot<Void>? = nil,
        lottieSettings: LottieRenderingSettings
    ) {
        self.content = content
        self.color = color
        self.placeholderColor = placeholderColor
        self.startingPosition = startingPosition
        self.size = size
        self.renderingScale = renderingScale
        self.loop = loop
        self.playOnce = playOnce
        self.lottieSettings = lottieSettings
    }

    public static func ==(lhs: LottieComponent, rhs: LottieComponent) -> Bool {
        return lhs.content == rhs.content && lhs.color == rhs.color && lhs.size == rhs.size && lhs.startingPosition == rhs.startingPosition && lhs.loop == rhs.loop
    }

    public final class View: UIImageView {
        public func playOnce(delay: Double = 0.0, force: Bool = false, completion: (() -> Void)? = nil) {
            completion?()
        }

        func update(component: LottieComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            return component.size ?? availableSize
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}
