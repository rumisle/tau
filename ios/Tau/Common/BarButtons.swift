import UIKit
import AsyncDisplayKit
import Display
import ContextUI
import SwiftSignalKit
import TelegramPresentationData

/// A view as a context menu's anchor: the menu grows from it, as Telegram's bar buttons and send button have it.
final class ViewContextReferenceSource: ContextReferenceContentSource {
    let keepInPlace: Bool = false
    private weak var view: UIView?

    init(view: UIView) {
        self.view = view
    }

    var shouldBeDismissed: Signal<Bool, NoError> {
        return .single(false)
    }

    var forceDisplayBelowKeyboard: Bool {
        return false
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        guard let view = self.view else {
            return nil
        }
        return ContextControllerReferenceViewInfo(referenceView: view, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}

/// A bar button that acts on a tap and opens a menu when held, as Telegram's MoreButtonNode: a ContextControllerSourceNode
/// under a HighlightableButtonNode. Held, the menu comes with the gesture, so the finger slides to an item and lifting it
/// there chooses it. Its glyph is an image (New Chat's compose) or, with `more`, Telegram's animated ⋯.
final class BarActionButtonNode: ASDisplayNode {
    private let buttonNode = HighlightableButtonNode()
    private let containerNode = ContextControllerSourceNode()
    /// The menu's anchor.
    let referenceNode = ContextReferenceContentNode()
    private let iconNode = ASImageNode()
    private let image: (UIColor) -> UIImage?
    private let width: CGFloat

    var tapped: (() -> Void)?
    /// The menu: from a hold, with its gesture; nil for none, and the hold does nothing.
    var contextAction: ((ContextGesture) -> Void)? {
        didSet {
            self.containerNode.isGestureEnabled = self.contextAction != nil
        }
    }

    init(image: @escaping (UIColor) -> UIImage?, width: CGFloat = 44.0, accessibilityLabel: String) {
        self.image = image
        self.width = width
        super.init()
        self.containerNode.animateScale = false
        self.containerNode.isGestureEnabled = false
        self.iconNode.displaysAsynchronously = false
        self.iconNode.isUserInteractionEnabled = false
        self.addSubnode(self.buttonNode)
        self.buttonNode.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.referenceNode)
        self.referenceNode.addSubnode(self.iconNode)
        self.buttonNode.accessibilityLabel = accessibilityLabel
        self.buttonNode.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
        self.containerNode.activated = { [weak self] gesture, _ in
            self?.contextAction?(gesture)
        }
    }

    @objc private func buttonPressed() {
        self.tapped?()
    }

    func update(color: UIColor) {
        self.iconNode.image = self.image(color)
        self.setNeedsLayout()
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: self.width, height: 44.0)
    }

    override func layout() {
        super.layout()
        let bounds = CGRect(origin: CGPoint(), size: CGSize(width: self.width, height: 44.0))
        self.buttonNode.frame = bounds
        self.containerNode.frame = bounds
        self.referenceNode.frame = bounds
        if let image = self.iconNode.image {
            self.iconNode.frame = CGRect(origin: CGPoint(x: floor((bounds.width - image.size.width) / 2.0), y: floor((bounds.height - image.size.height) / 2.0)), size: image.size)
        }
    }
}

/// Telegram's compose glyph, centered in its button.
func composeIcon(_ color: UIColor) -> UIImage? {
    return generateTintedImage(image: UIImage(bundleImageName: "Chat List/ComposeIcon"), color: color)
}

/// "today at 20:38", "yesterday at 20:38", "Oct 21 at 20:38": when a photo was sent, as Telegram's media viewer says it
/// (humanReadableStringForTimestamp, lowercase as its strings are).
func humanReadableDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = messageTimeString(date)
    if calendar.isDateInToday(date) {
        return "today at \(time)"
    }
    if calendar.isDateInYesterday(date) {
        return "yesterday at \(time)"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
    formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
    return "\(formatter.string(from: date)) at \(time)"
}
