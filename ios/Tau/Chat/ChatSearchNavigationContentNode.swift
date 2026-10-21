import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import SearchBarNode
import ComponentFlow
import GlassBackgroundComponent
import ActivityIndicator

private let searchBarFont = Font.regular(17.0)

/// A chat's search field in place of its title, from Telegram's ChatSearchNavigationContentNode: a glass field with
/// the loupe, or a spinner while searching, and a round glass close button beside it.
final class ChatSearchNavigationContentNode: NavigationBarContentNode {
    private var theme: PresentationTheme
    private let backgroundContainer: GlassBackgroundContainerView
    private let backgroundView: GlassBackgroundView
    private let iconView: UIImageView
    private var activityIndicator: ActivityIndicator?
    private let searchBar: SearchBarNode
    private let close: (background: GlassBackgroundView, icon: UIImageView)
    private var params: (size: CGSize, leftInset: CGFloat, rightInset: CGFloat)?

    var textUpdated: ((String) -> Void)?
    var dismiss: (() -> Void)?

    /// The spinner in place of the loupe.
    var isSearching: Bool = false {
        didSet {
            if self.isSearching != oldValue, let params = self.params {
                let _ = self.updateLayout(size: params.size, leftInset: params.leftInset, rightInset: params.rightInset, transition: .immediate)
            }
        }
    }

    init(theme: PresentationTheme, strings: PresentationStrings) {
        self.theme = theme
        self.backgroundContainer = GlassBackgroundContainerView()
        self.backgroundView = GlassBackgroundView()
        self.backgroundContainer.contentView.addSubview(self.backgroundView)
        self.iconView = UIImageView()
        self.backgroundView.contentView.addSubview(self.iconView)
        self.close = (GlassBackgroundView(), UIImageView())
        self.close.background.contentView.addSubview(self.close.icon)
        self.searchBar = SearchBarNode(
            theme: SearchBarNodeTheme(
                background: .clear,
                separator: .clear,
                inputFill: .clear,
                primaryText: theme.chat.inputPanel.panelControlColor,
                placeholder: theme.chat.inputPanel.inputPlaceholderColor,
                inputIcon: theme.chat.inputPanel.inputControlColor,
                inputClear: theme.chat.inputPanel.panelControlColor,
                accent: theme.chat.inputPanel.panelControlAccentColor,
                keyboard: theme.rootController.keyboardColor
            ),
            presentationTheme: theme,
            strings: strings,
            fieldStyle: .inlineNavigation,
            forceSeparator: false,
            displayBackground: false,
            cancelText: nil
        )
        self.searchBar.placeholderString = NSAttributedString(string: strings.Conversation_SearchPlaceholder, font: searchBarFont, textColor: theme.chat.inputPanel.inputPlaceholderColor)
        super.init()

        self.view.addSubview(self.backgroundContainer)
        self.backgroundView.contentView.addSubview(self.searchBar.view)
        self.backgroundContainer.contentView.addSubview(self.close.background)
        self.close.background.contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.onCloseTapGesture(_:))))
        self.close.background.isAccessibilityElement = true
        self.close.background.accessibilityLabel = strings.Common_Close
        self.close.background.accessibilityIdentifier = "closeSearch"

        self.searchBar.cancel = { [weak self] in
            self?.searchBar.deactivate(clear: false)
            self?.dismiss?()
        }
        self.searchBar.textUpdated = { [weak self] query, _ in
            self?.textUpdated?(query)
        }
    }

    override var nominalHeight: CGFloat {
        return 60.0
    }

    @objc private func onCloseTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.searchBar.cancel?()
        }
    }

    override func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) -> CGSize {
        self.params = (size, leftInset, rightInset)
        let transition = ComponentTransition(transition)
        let backgroundFrame = CGRect(origin: CGPoint(x: leftInset + 16.0, y: 6.0), size: CGSize(width: size.width - 16.0 * 2.0 - leftInset - rightInset - 44.0 - 8.0, height: 44.0))
        let closeFrame = CGRect(origin: CGPoint(x: size.width - 16.0 - rightInset - 44.0, y: backgroundFrame.minY), size: CGSize(width: 44.0, height: 44.0))

        transition.setFrame(view: self.backgroundContainer, frame: CGRect(origin: CGPoint(), size: size))
        self.backgroundContainer.update(size: size, isDark: self.theme.overallDarkAppearance, transition: transition)
        transition.setFrame(view: self.backgroundView, frame: backgroundFrame)
        self.backgroundView.update(size: backgroundFrame.size, cornerRadius: backgroundFrame.height * 0.5, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: true, transition: transition)

        if self.iconView.image == nil {
            self.iconView.image = UIImage(bundleImageName: "Navigation/Search")?.withRenderingMode(.alwaysTemplate)
        }
        transition.setTintColor(view: self.iconView, color: self.theme.rootController.navigationSearchBar.inputIconColor)
        if let image = self.iconView.image {
            let iconFraction: CGFloat = 0.8
            let imageSize = CGSize(width: image.size.width * iconFraction, height: image.size.height * iconFraction)
            let iconFrame = CGRect(origin: CGPoint(x: 12.0, y: floor((backgroundFrame.height - imageSize.height) * 0.5)), size: imageSize)
            transition.setPosition(view: self.iconView, position: iconFrame.center)
            transition.setBounds(view: self.iconView, bounds: CGRect(origin: CGPoint(), size: iconFrame.size))
        }

        if self.isSearching {
            let activityIndicator: ActivityIndicator
            if let current = self.activityIndicator {
                activityIndicator = current
            } else {
                activityIndicator = ActivityIndicator(type: .custom(self.theme.chat.inputPanel.inputControlColor, 14.0, 14.0, false))
                self.activityIndicator = activityIndicator
                self.backgroundView.contentView.addSubview(activityIndicator.view)
            }
            let indicatorSize = activityIndicator.measure(CGSize(width: 32.0, height: 32.0))
            let indicatorFrame = CGRect(origin: CGPoint(x: 15.0, y: floorToScreenPixels((backgroundFrame.height - indicatorSize.height) * 0.5)), size: indicatorSize)
            transition.setPosition(view: activityIndicator.view, position: indicatorFrame.center)
            transition.setBounds(view: activityIndicator.view, bounds: CGRect(origin: CGPoint(), size: indicatorFrame.size))
        } else if let activityIndicator = self.activityIndicator {
            self.activityIndicator = nil
            activityIndicator.view.removeFromSuperview()
        }
        self.iconView.isHidden = self.isSearching

        let searchBarFrame = CGRect(origin: CGPoint(x: 36.0, y: 0.0), size: CGSize(width: backgroundFrame.width - 36.0 - 4.0, height: 44.0))
        transition.setFrame(view: self.searchBar.view, frame: searchBarFrame)
        self.searchBar.updateLayout(boundingSize: searchBarFrame.size, leftInset: 0.0, rightInset: 0.0, transition: transition.containedViewLayoutTransition)

        if self.close.icon.image == nil {
            self.close.icon.image = generateImage(CGSize(width: 40.0, height: 40.0), contextGenerator: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                context.setLineWidth(2.0)
                context.setLineCap(.round)
                context.setStrokeColor(UIColor.white.cgColor)
                context.beginPath()
                context.move(to: CGPoint(x: 12.0, y: 12.0))
                context.addLine(to: CGPoint(x: size.width - 12.0, y: size.height - 12.0))
                context.move(to: CGPoint(x: size.width - 12.0, y: 12.0))
                context.addLine(to: CGPoint(x: 12.0, y: size.height - 12.0))
                context.strokePath()
            })?.withRenderingMode(.alwaysTemplate)
        }
        if let image = self.close.icon.image {
            self.close.icon.frame = image.size.centered(in: CGRect(origin: CGPoint(), size: closeFrame.size))
        }
        self.close.icon.tintColor = self.theme.chat.inputPanel.panelControlColor
        transition.setFrame(view: self.close.background, frame: closeFrame)
        self.close.background.update(size: closeFrame.size, cornerRadius: closeFrame.height * 0.5, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: true, transition: transition)
        return size
    }

    func activate() {
        self.searchBar.activate()
    }

    func deactivate() {
        self.searchBar.deactivate(clear: false)
    }

    var text: String {
        return self.searchBar.text
    }
}
