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

        /// The chat's plain background. Text sits on it without a bubble, so each is a quiet color the theme's own text
        /// reads well on: a cool light gray under Classic's white bubbles, white for Day; for the dark themes not pure
        /// black, whose contrast with white text smears on OLED (halation), but a near-black a step below the bubbles,
        /// neutral for Night and the blue-gray of Telegram's night palette for Tinted Night.
        var plainBackground: UInt32 {
            switch self {
            case .classic:
                return 0xE5EAEE
            case .day:
                return 0xFFFFFF
            case .night:
                return 0x0D0D0F
            case .tintedNight:
                return 0x0E1621
            }
        }

        /// Text on it: dark themes soften pure white a little, which also lowers halation.
        var freeTextColor: UIColor? {
            switch self {
            case .night:
                return UIColor(rgb: 0xE9EAEC)
            case .tintedNight:
                return UIColor(rgb: 0xE6EBF0)
            case .classic, .day:
                return nil
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

    /// Telegram's accent colors (PresentationThemeBaseColor, without presets and custom colors), which tint a built-in
    /// theme through `customizePresentationTheme`, as Telegram's Appearance > color row does. Each theme keeps its own.
    enum Accent: String, CaseIterable {
        case blue
        case cyan
        case green
        case pink
        case orange
        case purple
        case red
        case yellow
        case gray
        case black
        case white

        /// tau's: Telegram's pink.
        static let standard: Accent = .pink

        var baseColor: PresentationThemeBaseColor {
            switch self {
            case .blue:
                return .blue
            case .cyan:
                return .cyan
            case .green:
                return .green
            case .pink:
                return .pink
            case .orange:
                return .orange
            case .purple:
                return .purple
            case .red:
                return .red
            case .yellow:
                return .yellow
            case .gray:
                return .gray
            case .black:
                return .black
            case .white:
                return .white
            }
        }

        /// Telegram's values (PresentationThemeBaseColor.color).
        var rgb: UInt32 {
            switch self {
            case .blue:
                return 0x0088ff
            case .cyan:
                return 0x00c2ed
            case .green:
                return 0x29b327
            case .pink:
                return 0xeb6ca4
            case .orange:
                return 0xf08200
            case .purple:
                return 0x9472ee
            case .red:
                return 0xd33213
            case .yellow:
                return 0xedb400
            case .gray:
                return 0x6d839e
            case .black:
                return 0x000000
            case .white:
                return 0xffffff
            }
        }

        /// As `PresentationThemeAccentColor.colorFor(baseTheme:)`: Night's blue is its own.
        func rgb(for builtin: Builtin) -> UInt32 {
            if builtin == .night && self == .blue {
                return 0x3e88f7
            }
            return self.rgb
        }

        /// The colors Telegram offers each theme (ThemePickerController): black only for Day, white only for Night,
        /// and no gray for Night.
        static func available(for builtin: Builtin) -> [Accent] {
            return Accent.allCases.filter { accent in
                switch accent {
                case .black:
                    return builtin == .day
                case .white:
                    return builtin == .night
                case .gray:
                    return builtin != .night
                default:
                    return true
                }
            }
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
    let accent: Accent
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
        return "\(self.builtin.rawValue)-\(self.accent.rawValue)"
    }

    private static var cache: [String: TauTheme] = [:]

    static func builtin(_ builtin: Builtin, accent: Accent = .standard) -> TauTheme {
        let accent = Accent.available(for: builtin).contains(accent) ? accent : .standard
        let key = "\(builtin.rawValue)|\(accent.rawValue)"
        if let theme = TauTheme.cache[key] {
            return theme
        }
        let theme = TauTheme(builtin: builtin, accent: accent)
        TauTheme.cache[key] = theme
        return theme
    }

    /// The chat's plain background: the theme's own, except Tinted Night's, which Telegram derives from the accent, as
    /// its other backgrounds (customizeDefaultDarkTintedPresentationTheme's `additionalBackgroundColor`), a step darker as
    /// tau's default one is.
    private static func plainBackground(_ builtin: Builtin, accent: Accent) -> UInt32 {
        guard builtin == .tintedNight, accent != .blue else {
            return builtin.plainBackground
        }
        let hsb = UIColor(rgb: accent.rgb).hsb
        let accentColor = UIColor(hue: hsb.0, saturation: hsb.1, brightness: max(hsb.2, 0.18), alpha: 1.0)
        return accentColor.withMultiplied(hue: 1.024, saturation: 0.573, brightness: 0.18 * 0.72).rgb
    }

    private init(builtin: Builtin, accent: Accent) {
        let base = defaultPresentationData()
        let plain = makeDefaultPresentationTheme(reference: builtin.reference, serviceBackgroundColor: nil)
        // As Telegram makes a built-in theme with an accent (makePresentationTheme(mediaBox:themeReference:accentColor:)):
        // editing, so the accent also colors the outgoing bubbles. Blue is the themes' own accent: unchanged.
        let theme = accent == .blue ? plain : customizePresentationTheme(plain, editing: true, accentColor: UIColor(rgb: accent.rgb(for: builtin)), outgoingAccentColor: nil, backgroundColors: [], bubbleColors: [], animateBubbleColors: false, baseColor: accent.baseColor)
        self.builtin = builtin
        self.accent = accent
        self.presentationTheme = theme
        self.presentationStrings = base.strings
        let plainBackground = TauTheme.plainBackground(builtin, accent: accent)
        let wallpaper = TelegramWallpaper.color(plainBackground)
        self.wallpaper = wallpaper
        self.presentationData = base.withUpdated(theme: theme).withUpdated(chatWallpaper: wallpaper)
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
        let chatBackgroundColor = UIColor(rgb: plainBackground)
        // Pills and cards: Telegram's color for a plain wallpaper (the background, darker, see-through) on a light
        // one; a lift of white on a dark one, where darker would vanish.
        let serviceFill = dark ? UIColor(white: 1.0, alpha: 0.08) : serviceColor(with: chatBackgroundColor)
        // Cards are incoming bubbles, except on a plain wallpaper of the bubble's own color (Day), where they take a
        // code block's tint instead.
        var toolCardBackgroundColor = message.incoming.bubble.withWallpaper.fill.first ?? list.itemBlocksBackgroundColor
        if toolCardBackgroundColor.argb == chatBackgroundColor.argb {
            toolCardBackgroundColor = dark ? UIColor(white: 1.0, alpha: 0.08) : UIColor(white: 0.0, alpha: 0.05)
        }
        self.chat = Chat(
            backgroundColor: chatBackgroundColor,
            outgoing: bubble(message.outgoing),
            incoming: incoming,
            freeTextColor: builtin.freeTextColor ?? message.incoming.primaryTextColor,
            freeSecondaryTextColor: message.incoming.secondaryTextColor,
            linkTextColor: message.incoming.linkTextColor,
            toolCardBackgroundColor: toolCardBackgroundColor,
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
            serviceFillColor: serviceFill,
            serviceTextColor: dark ? UIColor(white: 1.0, alpha: 0.92) : service.primaryText
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
