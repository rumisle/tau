// tau shim for Telegram-iOS SearchBarNode (which pulls in TelegramCore). Copied modules only construct and lay it out
// for search modes tau does not enable yet, so this keeps their interface and draws an empty field.
import UIKit
// Re-exported: copied modules name ASDisplayNode through this import, which Bazel resolves transitively and SwiftPM does not.
@_exported import AsyncDisplayKit
import Display
import TelegramPresentationData

public final class SearchBarNodeTheme {
    public let background: UIColor
    public let separator: UIColor
    public let inputFill: UIColor
    public let primaryText: UIColor
    public let placeholder: UIColor
    public let inputIcon: UIColor
    public let inputClear: UIColor
    public let accent: UIColor
    public let keyboard: PresentationThemeKeyboardColor

    public init(background: UIColor, separator: UIColor, inputFill: UIColor, primaryText: UIColor, placeholder: UIColor, inputIcon: UIColor, inputClear: UIColor, accent: UIColor, keyboard: PresentationThemeKeyboardColor) {
        self.background = background
        self.separator = separator
        self.inputFill = inputFill
        self.primaryText = primaryText
        self.placeholder = placeholder
        self.inputIcon = inputIcon
        self.inputClear = inputClear
        self.accent = accent
        self.keyboard = keyboard
    }
}

public enum SearchBarStyle {
    case modern
    case legacy
    case inlineNavigation
    case glass
}

public enum SearchBarIcon {
    case loupe
    case clock
}

public final class SearchBarNode: ASDisplayNode {
    public var placeholderString: NSAttributedString?
    public var text: String = ""
    public var textUpdated: ((String, String?) -> Void)?
    public var cancel: (() -> Void)?

    public init(theme: SearchBarNodeTheme, presentationTheme: PresentationTheme, strings: PresentationStrings, fieldStyle: SearchBarStyle = .legacy, icon: SearchBarIcon = .loupe, forceSeparator: Bool = false, displayBackground: Bool = true, cancelText: String? = nil) {
        super.init()
    }

    public func updateLayout(boundingSize: CGSize, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) {
    }

    public func activate() {
    }

    public func deactivate(clear: Bool = true) {
    }
}
