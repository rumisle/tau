import UIKit
import Display
import TelegramCore
import TelegramUIPreferences
import TelegramPresentationData

/// One of Telegram-iOS's four built-in themes (TelegramPresentationData/Sources/Default*PresentationTheme.swift, copied
/// verbatim), plus the values tau's own screens read from it. Every color here comes from Telegram's theme object.
final class TauTheme {
    enum Builtin: String, CaseIterable {
        case classic
        case day
        case night
        case tintedNight

        var reference: PresentationBuiltinThemeReference {
            switch self {
            case .classic:
                return .dayClassic
            case .day:
                return .day
            case .night:
                return .night
            case .tintedNight:
                return .nightAccent
            }
        }

        var title: String {
            switch self {
            case .classic:
                return "Classic"
            case .day:
                return "Day"
            case .night:
                return "Night"
            case .tintedNight:
                return "Tinted Night"
            }
        }

        var isDark: Bool {
            return self == .night || self == .tintedNight
        }
    }

    struct ChatList {
        var backgroundColor: UIColor
        var itemSeparatorColor: UIColor
        var itemHighlightedBackgroundColor: UIColor
        var titleColor: UIColor
        var dateTextColor: UIColor
        var messageTextColor: UIColor
        var authorNameColor: UIColor
        var activityTextColor: UIColor
        var unreadBadgeBackgroundColor: UIColor
        var unreadBadgeTextColor: UIColor
        var checkmarkColor: UIColor
    }

    struct RootNavigationBar {
        var buttonColor: UIColor
        var disabledButtonColor: UIColor
        var primaryTextColor: UIColor
        var secondaryTextColor: UIColor
        var accentTextColor: UIColor
        var blurredBackgroundColor: UIColor
        var opaqueBackgroundColor: UIColor
        var separatorColor: UIColor
        var badgeBackgroundColor: UIColor
        var badgeTextColor: UIColor
    }

    /// Telegram's grouped item lists (settings).
    struct List {
        var blocksBackgroundColor: UIColor
        var plainBackgroundColor: UIColor
        var itemBlocksBackgroundColor: UIColor
        var itemHighlightedBackgroundColor: UIColor
        var itemBlocksSeparatorColor: UIColor
        var itemPrimaryTextColor: UIColor
        var itemSecondaryTextColor: UIColor
        var itemAccentColor: UIColor
        var itemDestructiveColor: UIColor
        var disclosureArrowColor: UIColor
        var sectionHeaderTextColor: UIColor
        var freeTextColor: UIColor
    }

    struct Bubble {
        /// The bubble gradient, top to bottom of the screen: a bubble's color depends on where it is, as in Telegram.
        var fillColors: [UIColor]
        var primaryTextColor: UIColor
        var secondaryTextColor: UIColor
        var linkTextColor: UIColor
        var accentTextColor: UIColor
    }

    struct Chat {
        /// The wallpaper's base color, shown before the wallpaper renders and behind transitions.
        var backgroundColor: UIColor
        var outgoing: Bubble
        var incoming: Bubble
        /// The assistant's text, which sits on the wallpaper without a bubble.
        var freeTextColor: UIColor
        var freeSecondaryTextColor: UIColor
        var linkTextColor: UIColor
        var toolCardBackgroundColor: UIColor
        var toolCardTitleColor: UIColor
        var toolCardTextColor: UIColor
        var tableBorderColor: UIColor
        var tableHeaderBackgroundColor: UIColor
        var selectionCheckColor: UIColor
        var panelControlColor: UIColor
        var inputTextColor: UIColor
        var inputPlaceholderColor: UIColor
        var actionControlFillColor: UIColor
        var actionControlForegroundColor: UIColor
        /// Date headers and other service pills on the wallpaper.
        var serviceFillColor: UIColor
        var serviceTextColor: UIColor
    }

    struct TabBar {
        var textColor: UIColor
        var selectedTextColor: UIColor
        var iconColor: UIColor
    }

    let builtin: Builtin
    let presentationTheme: PresentationTheme
    let presentationStrings: PresentationStrings
    let presentationData: PresentationData
    let wallpaper: TelegramWallpaper
    let overallDarkAppearance: Bool
    let accentColor: UIColor
    let chatList: ChatList
    let navigationBar: RootNavigationBar
    let list: List
    let chat: Chat
    let tabBar: TabBar
    let statusBarStyle: NavigationStatusBarStyle

    var name: String {
        return self.builtin.rawValue
    }

    private static var cache: [Builtin: TauTheme] = [:]

    static func builtin(_ builtin: Builtin) -> TauTheme {
        if let theme = TauTheme.cache[builtin] {
            return theme
        }
        let theme = TauTheme(builtin: builtin)
        TauTheme.cache[builtin] = theme
        return theme
    }

    private init(builtin: Builtin) {
        let theme = makeDefaultPresentationTheme(reference: builtin.reference, serviceBackgroundColor: nil)
        let base = defaultPresentationData()
        self.builtin = builtin
        self.presentationTheme = theme
        self.presentationStrings = base.strings
        self.wallpaper = theme.chat.defaultWallpaper
        self.presentationData = base.withUpdated(theme: theme).withUpdated(chatWallpaper: theme.chat.defaultWallpaper)
        self.overallDarkAppearance = theme.overallDarkAppearance
        self.accentColor = theme.list.itemAccentColor

        let chatListTheme = theme.chatList
        self.chatList = ChatList(
            backgroundColor: chatListTheme.backgroundColor,
            itemSeparatorColor: chatListTheme.itemSeparatorColor,
            itemHighlightedBackgroundColor: chatListTheme.itemHighlightedBackgroundColor,
            titleColor: chatListTheme.titleColor,
            dateTextColor: chatListTheme.dateTextColor,
            messageTextColor: chatListTheme.messageTextColor,
            authorNameColor: chatListTheme.authorNameColor,
            activityTextColor: theme.list.itemAccentColor,
            unreadBadgeBackgroundColor: chatListTheme.unreadBadgeActiveBackgroundColor,
            unreadBadgeTextColor: chatListTheme.unreadBadgeActiveTextColor,
            checkmarkColor: chatListTheme.checkmarkColor
        )

        let bar = theme.rootController.navigationBar
        self.navigationBar = RootNavigationBar(
            buttonColor: bar.buttonColor,
            disabledButtonColor: bar.disabledButtonColor,
            primaryTextColor: bar.primaryTextColor,
            secondaryTextColor: bar.secondaryTextColor,
            accentTextColor: bar.accentTextColor,
            blurredBackgroundColor: bar.blurredBackgroundColor,
            opaqueBackgroundColor: bar.opaqueBackgroundColor,
            separatorColor: bar.separatorColor,
            badgeBackgroundColor: bar.badgeBackgroundColor,
            badgeTextColor: bar.badgeTextColor
        )

        let list = theme.list
        self.list = List(
            blocksBackgroundColor: list.blocksBackgroundColor,
            plainBackgroundColor: list.plainBackgroundColor,
            itemBlocksBackgroundColor: list.itemBlocksBackgroundColor,
            itemHighlightedBackgroundColor: list.itemHighlightedBackgroundColor,
            itemBlocksSeparatorColor: list.itemBlocksSeparatorColor,
            itemPrimaryTextColor: list.itemPrimaryTextColor,
            itemSecondaryTextColor: list.itemSecondaryTextColor,
            itemAccentColor: list.itemAccentColor,
            itemDestructiveColor: list.itemDestructiveColor,
            disclosureArrowColor: list.disclosureArrowColor,
            sectionHeaderTextColor: list.sectionHeaderTextColor,
            freeTextColor: list.freeTextColor
        )

        let message = theme.chat.message
        func bubble(_ colors: PresentationThemePartedColors) -> Bubble {
            let fill = colors.bubble.withWallpaper.fill
            return Bubble(
                fillColors: fill.count >= 2 ? fill : [fill.first ?? .white, fill.first ?? .white],
                primaryTextColor: colors.primaryTextColor,
                secondaryTextColor: colors.secondaryTextColor,
                linkTextColor: colors.linkTextColor,
                accentTextColor: colors.accentTextColor
            )
        }
        let incoming = bubble(message.incoming)
        let input = theme.chat.inputPanel
        let service = theme.chat.serviceMessage.components.withDefaultWallpaper
        let dark = theme.overallDarkAppearance
        self.chat = Chat(
            backgroundColor: TauTheme.baseColor(of: theme.chat.defaultWallpaper) ?? list.plainBackgroundColor,
            outgoing: bubble(message.outgoing),
            incoming: incoming,
            freeTextColor: message.incoming.primaryTextColor,
            freeSecondaryTextColor: message.incoming.secondaryTextColor,
            linkTextColor: message.incoming.linkTextColor,
            toolCardBackgroundColor: message.incoming.bubble.withWallpaper.fill.first ?? list.itemBlocksBackgroundColor,
            toolCardTitleColor: message.incoming.primaryTextColor,
            toolCardTextColor: message.incoming.secondaryTextColor,
            tableBorderColor: message.incoming.primaryTextColor.withMultipliedAlpha(dark ? 0.16 : 0.12),
            tableHeaderBackgroundColor: message.incoming.primaryTextColor.withMultipliedAlpha(dark ? 0.06 : 0.04),
            selectionCheckColor: message.selectionControlColors.fillColor,
            panelControlColor: input.panelControlColor,
            inputTextColor: input.inputTextColor,
            inputPlaceholderColor: input.inputPlaceholderColor,
            actionControlFillColor: input.actionControlFillColor,
            actionControlForegroundColor: input.actionControlForegroundColor,
            serviceFillColor: service.fill,
            serviceTextColor: service.primaryText
        )

        let tabBar = theme.rootController.tabBar
        self.tabBar = TabBar(textColor: tabBar.textColor, selectedTextColor: tabBar.selectedTextColor, iconColor: tabBar.iconColor)
        self.statusBarStyle = theme.rootController.statusBarStyle == .white ? .white : .black
    }

    /// The single color a wallpaper is closest to: its color, or its gradient's first color.
    static func baseColor(of wallpaper: TelegramWallpaper) -> UIColor? {
        switch wallpaper {
        case let .color(color):
            return UIColor(rgb: color)
        case let .gradient(gradient):
            return gradient.colors.first.flatMap { UIColor(rgb: $0) }
        case let .file(file):
            return file.settings.colors.first.flatMap { UIColor(rgb: $0) }
        default:
            return nil
        }
    }

    func navigationBarTheme(style: NavigationBar.Style = .glass, edgeEffectColor: UIColor? = nil) -> NavigationBarTheme {
        return NavigationBarTheme(rootControllerTheme: self.presentationTheme, edgeEffectColor: edgeEffectColor, style: style)
    }

    func navigationBarPresentationData(style: NavigationBar.Style = .glass, edgeEffectColor: UIColor? = nil) -> NavigationBarPresentationData {
        return NavigationBarPresentationData(
            theme: self.navigationBarTheme(style: style, edgeEffectColor: edgeEffectColor),
            strings: NavigationBarStrings(presentationStrings: self.presentationStrings)
        )
    }

    var navigationControllerTheme: NavigationControllerTheme {
        return NavigationControllerTheme(statusBar: self.statusBarStyle, navigationBar: self.navigationBarTheme(), emptyAreaColor: self.chatList.backgroundColor)
    }

    var statusBarStyleValue: StatusBarStyle {
        return self.overallDarkAppearance ? .White : .Black
    }
}
