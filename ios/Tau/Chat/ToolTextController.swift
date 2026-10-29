import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import EdgeEffect
import ComponentFlow
import ComponentDisplayAdapters

/// A tool card's whole text, from its Show All: the command and all of its output, a whole file, a whole diff, a
/// script with every call and all it wrote. A screen of its own, pushed as tau's others are (the bar, the theme, the
/// swipe back), so the chat's list never lays out a cell as tall as a long output. The text is the card's, in its
/// monospaced font and highlighting, uncut, in a read-only text view (TextKit 2) that scrolls and selects; the bar's
/// button shares it (Copy among the share sheet's actions).
final class ToolTextController: ViewController {
    private let context: AppContext
    private var theme: TauTheme
    private let message: ChatMessage
    private let shareButton: BarActionButtonNode
    private var themeDisposable: Disposable?

    private var textNode: ToolTextNode {
        return self.displayNode as! ToolTextNode
    }

    init(context: AppContext, message: ChatMessage) {
        self.context = context
        self.theme = context.theme
        self.message = message
        self.shareButton = BarActionButtonNode(image: { color in
            generateTintedImage(image: UIImage(bundleImageName: "Chat List/NavigationShare"), color: color)
        }, accessibilityLabel: "Share")
        super.init(navigationBarPresentationData: context.theme.navigationBarPresentationData())
        self.statusBar.statusBarStyle = self.theme.statusBarStyleValue
        self.title = ToolTextController.title(message)
        self.shareButton.update(color: self.theme.navigationBar.primaryTextColor)
        self.shareButton.tapped = { [weak self] in
            self?.share()
        }
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(customDisplayNode: self.shareButton)
        self.themeDisposable = (context.themeContext.theme |> deliverOnMainQueue).start(next: { [weak self] theme in
            guard let self, theme !== self.theme else {
                return
            }
            self.theme = theme
            self.statusBar.statusBarStyle = theme.statusBarStyleValue
            self.navigationBar?.updatePresentationData(theme.navigationBarPresentationData(), transition: .immediate)
            self.shareButton.update(color: theme.navigationBar.primaryTextColor)
            if self.isNodeLoaded {
                self.textNode.update(theme: theme, text: self.text(theme: theme))
            }
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.themeDisposable?.dispose()
    }

    /// The card's title: the tool.
    private static func title(_ message: ChatMessage) -> String {
        guard let tool = message.tool else {
            return "Output"
        }
        switch tool.detail {
        case .bash:
            return "Bash"
        case .read:
            return "Read"
        case .write:
            return "Write"
        case .edit:
            return "Edit"
        case .code:
            return "Code"
        default:
            return tool.name == "subagent" ? "Subagent" : tool.name
        }
    }

    /// The card's text, expanded and uncut, in the screen's colors: what it works on first (a file's path), then the
    /// rest as the card has it.
    private func text(theme: TauTheme) -> NSAttributedString {
        let isDark = theme.overallDarkAppearance
        let (_, summary, body) = toolCardContent(name: self.message.tool?.name ?? "", tool: self.message.tool, fallbackText: self.message.text, isExpanded: true, isActive: false, isDark: isDark, textColor: theme.list.itemPrimaryTextColor, titleColor: theme.list.itemPrimaryTextColor, accentColor: theme.accentColor, maxWidth: .greatestFiniteMagnitude, limit: Int.max)
        let text = NSMutableAttributedString()
        if !summary.isEmpty {
            text.append(NSAttributedString(string: summary + "\n\n", font: Font.semibold(13.0), textColor: theme.list.itemSecondaryTextColor))
        }
        text.append(body)
        // A screen to read: the card's fonts, larger (its 12 pt monospaced as 14).
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? UIFont {
                text.addAttribute(.font, value: font.withSize(round(font.pointSize * 7.0 / 6.0)), range: range)
            }
        }
        return text
    }

    private func share() {
        let text = self.textNode.plainText
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = self.shareButton.view
        self.present(activity, animated: true)
    }

    override func loadDisplayNode() {
        self.displayNode = ToolTextNode(theme: self.theme, text: self.text(theme: self.theme))
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.textNode.update(layout: layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
}

private final class ToolTextNode: ASDisplayNode {
    private var theme: TauTheme
    private var text: NSAttributedString
    private var textView: UITextView?
    /// The text fading out under the bar, as the chat's rows fade under its input panel (ChatControllerNode's edge
    /// effect): the bar's own blur alone left lines legible behind the clock and the back button.
    private let topEdgeEffectView = EdgeEffectView()
    private var validLayout: (ContainerViewLayout, CGFloat)?

    var plainText: String {
        return MarkdownText.copiedText(self.text)
    }

    init(theme: TauTheme, text: NSAttributedString) {
        self.theme = theme
        self.text = text
        super.init()
        self.backgroundColor = theme.list.plainBackgroundColor
    }

    override func didLoad() {
        super.didLoad()
        // TextKit 2: a long output lays out as it scrolls into view, not all at once.
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0.0
        textView.dataDetectorTypes = []
        textView.accessibilityIdentifier = "toolText"
        self.textView = textView
        self.view.addSubview(textView)
        self.topEdgeEffectView.isUserInteractionEnabled = false
        self.view.addSubview(self.topEdgeEffectView)
        self.apply()
        if let (layout, navigationHeight) = self.validLayout {
            self.update(layout: layout, navigationHeight: navigationHeight, transition: .immediate)
        }
    }

    func update(theme: TauTheme, text: NSAttributedString) {
        self.theme = theme
        self.text = text
        self.backgroundColor = theme.list.plainBackgroundColor
        self.apply()
        if let (layout, navigationHeight) = self.validLayout {
            self.update(layout: layout, navigationHeight: navigationHeight, transition: .immediate)
        }
    }

    private func apply() {
        guard let textView = self.textView else {
            return
        }
        textView.attributedText = self.text
        textView.tintColor = self.theme.accentColor
        textView.indicatorStyle = self.theme.overallDarkAppearance ? .white : .black
    }

    func update(layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationHeight)
        guard let textView = self.textView else {
            return
        }
        let wasLaidOut = textView.frame.width > 0.0
        transition.updateFrame(view: textView, frame: CGRect(origin: CGPoint(), size: layout.size))
        let edgeFrame = CGRect(x: 0.0, y: 0.0, width: layout.size.width, height: navigationHeight + 12.0)
        transition.updateFrame(view: self.topEdgeEffectView, frame: edgeFrame)
        self.topEdgeEffectView.update(content: self.theme.list.plainBackgroundColor, blur: true, alpha: 0.85, rect: edgeFrame, edge: .top, edgeSize: min(edgeFrame.height, 48.0), transition: ComponentTransition(transition))
        // Telegram's insets: under the bar, clear of the home indicator, 16 pt from the sides (and the safe area).
        let insets = UIEdgeInsets(top: navigationHeight + 12.0, left: layout.safeInsets.left + 16.0, bottom: max(layout.intrinsicInsets.bottom, 16.0) + 12.0, right: layout.safeInsets.right + 16.0)
        textView.textContainerInset = insets
        textView.verticalScrollIndicatorInsets = UIEdgeInsets(top: navigationHeight, left: 0.0, bottom: layout.intrinsicInsets.bottom, right: 0.0)
        if !wasLaidOut {
            textView.contentOffset = CGPoint()
        }
    }
}
