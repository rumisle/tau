import UIKit
import Display
import TelegramPresentationData

/// The parts of Telegram's presentation theme tau uses. Values are Telegram-iOS's default day theme
/// (TelegramPresentationData/Sources/DefaultDayPresentationTheme.swift, the classic variant).
final class TauTheme {
    struct ChatList {
        var backgroundColor: UIColor
        var itemSeparatorColor: UIColor
        var itemHighlightedBackgroundColor: UIColor
        var titleColor: UIColor
        var dateTextColor: UIColor
        var messageTextColor: UIColor
        var authorNameColor: UIColor
        var activityTextColor: UIColor
        var unreadBadgeActiveBackgroundColor: UIColor
        var unreadBadgeActiveTextColor: UIColor
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

    struct Bubble {
        var fill: UIColor
        var highlightedFill: UIColor
        var stroke: UIColor
        var primaryTextColor: UIColor
        var secondaryTextColor: UIColor
        var linkTextColor: UIColor
    }

    struct Chat {
        var incoming: Bubble
        var outgoing: Bubble
        /// Telegram's default gradient wallpaper.
        var wallpaperColors: [UIColor]
        var serviceBackgroundColor: UIColor
        var serviceTextColor: UIColor
        /// Text of the assistant, which has no bubble: drawn straight on the wallpaper.
        var freeTextColor: UIColor
        var freeSecondaryTextColor: UIColor
        var inputPanelControlColor: UIColor
        var inputBackgroundColor: UIColor
        var inputStrokeColor: UIColor
        var inputTextColor: UIColor
        var inputPlaceholderColor: UIColor
        var actionControlFillColor: UIColor
        var actionControlForegroundColor: UIColor
    }

    let overallDarkAppearance: Bool
    let accentColor: UIColor
    let chatList: ChatList
    let navigationBar: RootNavigationBar
    let chat: Chat
    let plainBackgroundColor: UIColor
    let statusBarStyle: NavigationStatusBarStyle

    init(overallDarkAppearance: Bool, accentColor: UIColor, chatList: ChatList, navigationBar: RootNavigationBar, chat: Chat, plainBackgroundColor: UIColor, statusBarStyle: NavigationStatusBarStyle) {
        self.overallDarkAppearance = overallDarkAppearance
        self.accentColor = accentColor
        self.chatList = chatList
        self.navigationBar = navigationBar
        self.chat = chat
        self.plainBackgroundColor = plainBackgroundColor
        self.statusBarStyle = statusBarStyle
    }

    static let day: TauTheme = {
        let accent = UIColor(rgb: 0x0088ff)
        let navigationBar = RootNavigationBar(
            buttonColor: accent,
            disabledButtonColor: UIColor(rgb: 0xd0d0d0),
            primaryTextColor: UIColor(rgb: 0x000000),
            secondaryTextColor: UIColor(rgb: 0x787878),
            accentTextColor: accent,
            blurredBackgroundColor: UIColor(rgb: 0xf2f2f2, alpha: 0.9),
            opaqueBackgroundColor: UIColor(rgb: 0xf7f7f7).mixedWith(.white, alpha: 0.14),
            separatorColor: UIColor(rgb: 0xc8c7cc),
            badgeBackgroundColor: UIColor(rgb: 0xff3b30),
            badgeTextColor: UIColor(rgb: 0xffffff)
        )
        let chatList = ChatList(
            backgroundColor: UIColor(rgb: 0xffffff),
            itemSeparatorColor: UIColor(rgb: 0xc8c7cc),
            itemHighlightedBackgroundColor: UIColor(rgb: 0xe5e5ea),
            titleColor: UIColor(rgb: 0x000000),
            dateTextColor: UIColor(rgb: 0x8e8e93),
            messageTextColor: UIColor(rgb: 0x8e8e93),
            authorNameColor: UIColor(rgb: 0x000000),
            activityTextColor: accent,
            unreadBadgeActiveBackgroundColor: accent,
            unreadBadgeActiveTextColor: UIColor(rgb: 0xffffff)
        )
        let bubbleStroke = UIColor(white: 0.0, alpha: 0.2)
        let chat = Chat(
            incoming: Bubble(
                fill: UIColor(rgb: 0xffffff),
                highlightedFill: UIColor(rgb: 0xd9f4ff),
                stroke: bubbleStroke,
                primaryTextColor: UIColor(rgb: 0x000000),
                secondaryTextColor: UIColor(rgb: 0x77828c),
                linkTextColor: UIColor(rgb: 0x004bad)
            ),
            outgoing: Bubble(
                fill: UIColor(rgb: 0xe1ffc7),
                highlightedFill: UIColor(rgb: 0xbaff93),
                stroke: bubbleStroke,
                primaryTextColor: UIColor(rgb: 0x000000),
                secondaryTextColor: UIColor(rgb: 0x008c09, alpha: 0.8),
                linkTextColor: UIColor(rgb: 0x004bad)
            ),
            wallpaperColors: [UIColor(rgb: 0xdbddbb), UIColor(rgb: 0x6ba587), UIColor(rgb: 0xd5d88d), UIColor(rgb: 0x88b884)],
            serviceBackgroundColor: UIColor(rgb: 0x000000, alpha: 0.2),
            serviceTextColor: UIColor(rgb: 0xffffff),
            freeTextColor: UIColor(rgb: 0x000000),
            freeSecondaryTextColor: UIColor(rgb: 0x000000, alpha: 0.45),
            inputPanelControlColor: UIColor(rgb: 0x858e99),
            inputBackgroundColor: UIColor(white: 1.0, alpha: 0.8),
            inputStrokeColor: UIColor(rgb: 0x000000, alpha: 0.1),
            inputTextColor: UIColor(rgb: 0x000000),
            inputPlaceholderColor: UIColor(rgb: 0x000000, alpha: 0.4),
            actionControlFillColor: accent,
            actionControlForegroundColor: UIColor(rgb: 0xffffff)
        )
        return TauTheme(
            overallDarkAppearance: false,
            accentColor: accent,
            chatList: chatList,
            navigationBar: navigationBar,
            chat: chat,
            plainBackgroundColor: UIColor(rgb: 0xffffff),
            statusBarStyle: .black
        )
    }()

    /// Mirrors `NavigationBarTheme(rootControllerTheme:...)` in TelegramPresentationData/Sources/ComponentsThemes.swift.
    /// `edgeEffectColor` tints the blurred fade a glass bar draws over scrolled content; default the list background.
    func navigationBarTheme(style: NavigationBar.Style = .legacy, hideBackground: Bool = false, edgeEffectColor edgeEffectOverride: UIColor? = nil) -> NavigationBarTheme {
        let theme = self.navigationBar
        let buttonColor: UIColor
        let disabledButtonColor: UIColor
        var edgeEffectColor: UIColor?
        if case .glass = style {
            buttonColor = self.chat.inputPanelControlColor
            disabledButtonColor = buttonColor.withMultipliedAlpha(0.5)
            edgeEffectColor = hideBackground ? .clear : (edgeEffectOverride ?? self.plainBackgroundColor)
        } else {
            buttonColor = theme.buttonColor
            disabledButtonColor = theme.disabledButtonColor
        }
        return NavigationBarTheme(
            overallDarkAppearance: self.overallDarkAppearance,
            buttonColor: buttonColor,
            disabledButtonColor: disabledButtonColor,
            primaryTextColor: theme.primaryTextColor,
            backgroundColor: hideBackground ? .clear : theme.blurredBackgroundColor,
            opaqueBackgroundColor: hideBackground ? .clear : theme.opaqueBackgroundColor,
            enableBackgroundBlur: true,
            separatorColor: hideBackground ? .clear : theme.separatorColor,
            badgeBackgroundColor: theme.badgeBackgroundColor,
            badgeStrokeColor: .clear,
            badgeTextColor: theme.badgeTextColor,
            edgeEffectColor: edgeEffectColor,
            accentButtonColor: self.accentColor,
            accentDisabledButtonColor: self.chat.inputPanelControlColor.withMultipliedAlpha(0.5),
            accentForegroundColor: .white,
            style: style,
            glassStyle: .default
        )
    }

    func navigationBarPresentationData(style: NavigationBar.Style = .legacy, hideBackground: Bool = false, edgeEffectColor: UIColor? = nil) -> NavigationBarPresentationData {
        return NavigationBarPresentationData(
            theme: self.navigationBarTheme(style: style, hideBackground: hideBackground, edgeEffectColor: edgeEffectColor),
            strings: NavigationBarStrings(back: "Back", close: "Close")
        )
    }

    /// The theme copied Telegram components read (the TelegramPresentationData shim), from the same values.
    lazy var presentationTheme: PresentationTheme = {
        let dark = self.overallDarkAppearance
        return PresentationTheme(
            overallDarkAppearance: dark,
            rootController: PresentationThemeRootController(
                tabBar: PresentationThemeRootTabBar(
                    backgroundColor: self.navigationBar.blurredBackgroundColor,
                    separatorColor: UIColor(rgb: 0xb2b2b2),
                    iconColor: UIColor(rgb: 0x959595),
                    selectedIconColor: self.accentColor,
                    textColor: dark ? UIColor(white: 1.0, alpha: 0.8) : UIColor(rgb: 0x000000, alpha: 0.8),
                    selectedTextColor: self.accentColor,
                    badgeBackgroundColor: UIColor(rgb: 0xff3b30),
                    badgeStrokeColor: UIColor(rgb: 0xff3b30),
                    badgeTextColor: UIColor(rgb: 0xffffff)
                ),
                navigationSearchBar: PresentationThemeNavigationSearchBar(
                    backgroundColor: self.plainBackgroundColor,
                    accentColor: self.accentColor,
                    inputFillColor: UIColor(rgb: 0x000000, alpha: 0.06),
                    inputTextColor: self.navigationBar.primaryTextColor,
                    inputPlaceholderTextColor: UIColor(rgb: 0x8e8e93),
                    inputIconColor: UIColor(rgb: 0x8e8e93),
                    inputClearButtonColor: UIColor(rgb: 0x7b7b81)
                ),
                keyboardColor: dark ? .dark : .light
            ),
            chat: PresentationThemeChat(inputPanel: PresentationThemeChatInputPanel(
                panelControlAccentColor: self.accentColor,
                panelControlColor: self.chat.inputPanelControlColor,
                panelControlDisabledColor: self.chat.inputPanelControlColor.withMultipliedAlpha(0.5),
                inputBackgroundColor: self.chat.inputBackgroundColor,
                inputStrokeColor: self.chat.inputStrokeColor,
                inputPlaceholderColor: self.chat.inputPlaceholderColor,
                inputTextColor: self.chat.inputTextColor,
                inputControlColor: self.chat.inputPanelControlColor,
                actionControlFillColor: self.chat.actionControlFillColor,
                actionControlForegroundColor: self.chat.actionControlForegroundColor
            ))
        )
    }()

    let presentationStrings = PresentationStrings()

    var navigationControllerTheme: NavigationControllerTheme {
        return NavigationControllerTheme(statusBar: self.statusBarStyle, navigationBar: self.navigationBarTheme(), emptyAreaColor: self.chatList.backgroundColor)
    }
}
