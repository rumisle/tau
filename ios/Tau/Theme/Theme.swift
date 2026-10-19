import UIKit
import Display
import TelegramPresentationData

/// The parts of Telegram's presentation theme tau uses. `day` and `night` are Telegram-iOS's Day and Night themes
/// (TelegramPresentationData/Sources/DefaultDayPresentationTheme.swift with `day: true`, DefaultDarkPresentationTheme.swift)
/// on a plain background instead of a wallpaper.
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
        /// Top and bottom of the gradient, which spans the screen: a bubble's color depends on where it is.
        var fillColors: [UIColor]
        var primaryTextColor: UIColor
        var secondaryTextColor: UIColor
        var linkTextColor: UIColor
    }

    struct Chat {
        var backgroundColor: UIColor
        var outgoing: Bubble
        /// The assistant's text, which has no bubble.
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
    }

    struct TabBar {
        var textColor: UIColor
        var selectedTextColor: UIColor
        var iconColor: UIColor
    }

    let name: String
    let overallDarkAppearance: Bool
    let accentColor: UIColor
    let chatList: ChatList
    let navigationBar: RootNavigationBar
    let list: List
    let chat: Chat
    let tabBar: TabBar
    let statusBarStyle: NavigationStatusBarStyle

    init(name: String, overallDarkAppearance: Bool, accentColor: UIColor, chatList: ChatList, navigationBar: RootNavigationBar, list: List, chat: Chat, tabBar: TabBar, statusBarStyle: NavigationStatusBarStyle) {
        self.name = name
        self.overallDarkAppearance = overallDarkAppearance
        self.accentColor = accentColor
        self.chatList = chatList
        self.navigationBar = navigationBar
        self.list = list
        self.chat = chat
        self.tabBar = tabBar
        self.statusBarStyle = statusBarStyle
    }

    static let day: TauTheme = {
        let accent = UIColor(rgb: 0x0088ff)
        return TauTheme(
            name: "day",
            overallDarkAppearance: false,
            accentColor: accent,
            chatList: ChatList(
                backgroundColor: UIColor(rgb: 0xffffff),
                itemSeparatorColor: UIColor(rgb: 0xc8c7cc),
                itemHighlightedBackgroundColor: UIColor(rgb: 0xe5e5ea),
                titleColor: UIColor(rgb: 0x000000),
                dateTextColor: UIColor(rgb: 0x8e8e93),
                messageTextColor: UIColor(rgb: 0x8e8e93),
                authorNameColor: UIColor(rgb: 0x000000),
                activityTextColor: accent
            ),
            navigationBar: RootNavigationBar(
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
            ),
            list: List(
                blocksBackgroundColor: UIColor(rgb: 0xefeff4),
                itemBlocksBackgroundColor: UIColor(rgb: 0xffffff),
                itemHighlightedBackgroundColor: UIColor(rgb: 0xe5e5ea),
                itemBlocksSeparatorColor: UIColor(rgb: 0xc8c7cc),
                itemPrimaryTextColor: UIColor(rgb: 0x000000),
                itemSecondaryTextColor: UIColor(rgb: 0x8e8e93),
                itemAccentColor: accent,
                itemDestructiveColor: UIColor(rgb: 0xff3b30),
                disclosureArrowColor: UIColor(rgb: 0xbab9be),
                sectionHeaderTextColor: UIColor(rgb: 0x6d6d72),
                freeTextColor: UIColor(rgb: 0x6d6d72)
            ),
            chat: Chat(
                backgroundColor: UIColor(rgb: 0xffffff),
                outgoing: Bubble(
                    fillColors: [UIColor(rgb: 0x57b2e0), accent],
                    primaryTextColor: UIColor(rgb: 0xffffff),
                    secondaryTextColor: UIColor(rgb: 0xffffff, alpha: 0.65),
                    linkTextColor: UIColor(rgb: 0xffffff)
                ),
                freeTextColor: UIColor(rgb: 0x000000),
                freeSecondaryTextColor: UIColor(rgb: 0x8e8e93),
                linkTextColor: UIColor(rgb: 0x004bad),
                toolCardBackgroundColor: UIColor(rgb: 0xf1f1f4),
                toolCardTitleColor: UIColor(rgb: 0x000000),
                toolCardTextColor: UIColor(rgb: 0x000000, alpha: 0.6),
                tableBorderColor: UIColor(rgb: 0x000000, alpha: 0.12),
                tableHeaderBackgroundColor: UIColor(rgb: 0x000000, alpha: 0.04),
                selectionCheckColor: accent,
                panelControlColor: UIColor(rgb: 0x000000),
                inputTextColor: UIColor(rgb: 0x000000),
                inputPlaceholderColor: UIColor(rgb: 0x000000, alpha: 0.4),
                actionControlFillColor: accent,
                actionControlForegroundColor: UIColor(rgb: 0xffffff)
            ),
            tabBar: TabBar(textColor: UIColor(rgb: 0x000000, alpha: 0.8), selectedTextColor: accent, iconColor: UIColor(rgb: 0x959595)),
            statusBarStyle: .black
        )
    }()

    static let night: TauTheme = {
        let accent = UIColor(rgb: 0x3e88f7)
        return TauTheme(
            name: "night",
            overallDarkAppearance: true,
            accentColor: accent,
            chatList: ChatList(
                backgroundColor: UIColor(rgb: 0x000000),
                itemSeparatorColor: UIColor(rgb: 0x545458, alpha: 0.55),
                itemHighlightedBackgroundColor: UIColor(rgb: 0x121212),
                titleColor: UIColor(rgb: 0xffffff),
                dateTextColor: UIColor(rgb: 0x8d8e93),
                messageTextColor: UIColor(rgb: 0x8d8e93),
                authorNameColor: UIColor(rgb: 0xffffff),
                activityTextColor: UIColor(rgb: 0xffffff)
            ),
            navigationBar: RootNavigationBar(
                buttonColor: UIColor(rgb: 0xffffff),
                disabledButtonColor: UIColor(rgb: 0x525252),
                primaryTextColor: UIColor(rgb: 0xffffff),
                secondaryTextColor: UIColor(rgb: 0xffffff, alpha: 0.5),
                accentTextColor: UIColor(rgb: 0xffffff),
                blurredBackgroundColor: UIColor(rgb: 0x1d1d1d, alpha: 0.9),
                opaqueBackgroundColor: UIColor(rgb: 0x1d1d1d).mixedWith(UIColor(rgb: 0x000000), alpha: 0.1),
                separatorColor: UIColor(rgb: 0x545458, alpha: 0.55),
                badgeBackgroundColor: UIColor(rgb: 0xffffff),
                badgeTextColor: UIColor(rgb: 0x000000)
            ),
            list: List(
                blocksBackgroundColor: UIColor(rgb: 0x000000),
                itemBlocksBackgroundColor: UIColor(rgb: 0x1c1c1d),
                itemHighlightedBackgroundColor: UIColor(rgb: 0x313135),
                itemBlocksSeparatorColor: UIColor(rgb: 0x545458, alpha: 0.55),
                itemPrimaryTextColor: UIColor(rgb: 0xffffff),
                itemSecondaryTextColor: UIColor(rgb: 0x98989e),
                itemAccentColor: accent,
                itemDestructiveColor: UIColor(rgb: 0xeb5545),
                disclosureArrowColor: UIColor(rgb: 0xffffff, alpha: 0.28),
                sectionHeaderTextColor: UIColor(rgb: 0x8d8e93),
                freeTextColor: UIColor(rgb: 0x8d8e93)
            ),
            chat: Chat(
                backgroundColor: UIColor(rgb: 0x000000),
                outgoing: Bubble(
                    fillColors: [UIColor(rgb: 0x61bcf9), UIColor(rgb: 0x0088ff)],
                    primaryTextColor: UIColor(rgb: 0xffffff),
                    secondaryTextColor: UIColor(rgb: 0xffffff, alpha: 0.5),
                    linkTextColor: UIColor(rgb: 0xffffff)
                ),
                freeTextColor: UIColor(rgb: 0xffffff),
                freeSecondaryTextColor: UIColor(rgb: 0x8d8e93),
                linkTextColor: UIColor(rgb: 0x6ab4ff),
                toolCardBackgroundColor: UIColor(rgb: 0x1d1d1d),
                toolCardTitleColor: UIColor(rgb: 0xffffff),
                toolCardTextColor: UIColor(rgb: 0xffffff, alpha: 0.6),
                tableBorderColor: UIColor(rgb: 0xffffff, alpha: 0.16),
                tableHeaderBackgroundColor: UIColor(rgb: 0xffffff, alpha: 0.06),
                selectionCheckColor: accent,
                panelControlColor: UIColor(rgb: 0xffffff),
                inputTextColor: UIColor(rgb: 0xffffff),
                inputPlaceholderColor: UIColor(rgb: 0xffffff, alpha: 0.48),
                actionControlFillColor: UIColor(rgb: 0xffffff),
                actionControlForegroundColor: UIColor(rgb: 0x000000)
            ),
            tabBar: TabBar(textColor: UIColor(rgb: 0xffffff), selectedTextColor: UIColor(rgb: 0xffffff), iconColor: UIColor(rgb: 0xffffff)),
            statusBarStyle: .white
        )
    }()

    /// Mirrors `NavigationBarTheme(rootControllerTheme:...)` in TelegramPresentationData/Sources/ComponentsThemes.swift:
    /// glass bars draw their buttons in the input panel's control color.
    func navigationBarTheme(style: NavigationBar.Style = .glass, edgeEffectColor edgeEffectOverride: UIColor? = nil) -> NavigationBarTheme {
        let theme = self.navigationBar
        let buttonColor: UIColor
        let disabledButtonColor: UIColor
        var edgeEffectColor: UIColor?
        if case .glass = style {
            buttonColor = self.chat.panelControlColor
            disabledButtonColor = buttonColor.withMultipliedAlpha(0.5)
            edgeEffectColor = edgeEffectOverride ?? self.chatList.backgroundColor
        } else {
            buttonColor = theme.buttonColor
            disabledButtonColor = theme.disabledButtonColor
        }
        return NavigationBarTheme(
            overallDarkAppearance: self.overallDarkAppearance,
            buttonColor: buttonColor,
            disabledButtonColor: disabledButtonColor,
            primaryTextColor: theme.primaryTextColor,
            backgroundColor: theme.blurredBackgroundColor,
            opaqueBackgroundColor: theme.opaqueBackgroundColor,
            enableBackgroundBlur: true,
            separatorColor: theme.separatorColor,
            badgeBackgroundColor: theme.badgeBackgroundColor,
            badgeStrokeColor: .clear,
            badgeTextColor: theme.badgeTextColor,
            edgeEffectColor: edgeEffectColor,
            accentButtonColor: self.chat.actionControlFillColor,
            accentDisabledButtonColor: self.chat.panelControlColor.withMultipliedAlpha(0.5),
            accentForegroundColor: self.chat.actionControlForegroundColor,
            style: style,
            glassStyle: .default
        )
    }

    func navigationBarPresentationData(style: NavigationBar.Style = .glass, edgeEffectColor: UIColor? = nil) -> NavigationBarPresentationData {
        return NavigationBarPresentationData(
            theme: self.navigationBarTheme(style: style, edgeEffectColor: edgeEffectColor),
            strings: NavigationBarStrings(back: "Back", close: "Close")
        )
    }

    var navigationControllerTheme: NavigationControllerTheme {
        return NavigationControllerTheme(statusBar: self.statusBarStyle, navigationBar: self.navigationBarTheme(), emptyAreaColor: self.chatList.backgroundColor)
    }

    var statusBarStyleValue: StatusBarStyle {
        return self.overallDarkAppearance ? .White : .Black
    }

    /// The theme copied Telegram components read (the TelegramPresentationData shim), from the same values.
    lazy var presentationTheme: PresentationTheme = {
        let dark = self.overallDarkAppearance
        return PresentationTheme(
            overallDarkAppearance: dark,
            rootController: PresentationThemeRootController(
                tabBar: PresentationThemeRootTabBar(
                    backgroundColor: self.navigationBar.blurredBackgroundColor,
                    separatorColor: self.navigationBar.separatorColor,
                    iconColor: self.tabBar.iconColor,
                    selectedIconColor: self.tabBar.selectedTextColor,
                    textColor: self.tabBar.textColor,
                    selectedTextColor: self.tabBar.selectedTextColor,
                    badgeBackgroundColor: UIColor(rgb: 0xff3b30),
                    badgeStrokeColor: UIColor(rgb: 0xff3b30),
                    badgeTextColor: UIColor(rgb: 0xffffff)
                ),
                navigationSearchBar: PresentationThemeNavigationSearchBar(
                    backgroundColor: self.chatList.backgroundColor,
                    accentColor: self.accentColor,
                    inputFillColor: dark ? UIColor(rgb: 0x0f0f0f) : UIColor(rgb: 0x000000, alpha: 0.06),
                    inputTextColor: self.navigationBar.primaryTextColor,
                    inputPlaceholderTextColor: self.chatList.dateTextColor,
                    inputIconColor: self.chatList.dateTextColor,
                    inputClearButtonColor: self.chatList.dateTextColor
                ),
                keyboardColor: dark ? .dark : .light
            ),
            chat: PresentationThemeChat(inputPanel: PresentationThemeChatInputPanel(
                panelControlAccentColor: self.accentColor,
                panelControlColor: self.chat.panelControlColor,
                panelControlDisabledColor: self.chat.panelControlColor.withMultipliedAlpha(0.5),
                inputBackgroundColor: self.chat.backgroundColor,
                inputStrokeColor: self.list.itemBlocksSeparatorColor,
                inputPlaceholderColor: self.chat.inputPlaceholderColor,
                inputTextColor: self.chat.inputTextColor,
                inputControlColor: self.chat.panelControlColor.withMultipliedAlpha(0.5),
                actionControlFillColor: self.chat.actionControlFillColor,
                actionControlForegroundColor: self.chat.actionControlForegroundColor
            ))
        )
    }()

    let presentationStrings = PresentationStrings()
}
