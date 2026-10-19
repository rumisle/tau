// tau shim for Telegram-iOS TelegramPresentationData.
//
// The real module defines Telegram's whole theme and pulls in TelegramCore. Copied Telegram components only read a few
// colors from it, so this module has the same type and property names with just those members. The app fills it from
// its own theme (Tau/Theme/Theme.swift). Add members here, with Telegram's names, when a newly copied module needs them.
import UIKit

public enum PresentationThemeKeyboardColor {
    case light
    case dark
}

public final class PresentationThemeRootTabBar {
    public let backgroundColor: UIColor
    public let separatorColor: UIColor
    public let iconColor: UIColor
    public let selectedIconColor: UIColor
    public let textColor: UIColor
    public let selectedTextColor: UIColor
    public let badgeBackgroundColor: UIColor
    public let badgeStrokeColor: UIColor
    public let badgeTextColor: UIColor

    public init(backgroundColor: UIColor, separatorColor: UIColor, iconColor: UIColor, selectedIconColor: UIColor, textColor: UIColor, selectedTextColor: UIColor, badgeBackgroundColor: UIColor, badgeStrokeColor: UIColor, badgeTextColor: UIColor) {
        self.backgroundColor = backgroundColor
        self.separatorColor = separatorColor
        self.iconColor = iconColor
        self.selectedIconColor = selectedIconColor
        self.textColor = textColor
        self.selectedTextColor = selectedTextColor
        self.badgeBackgroundColor = badgeBackgroundColor
        self.badgeStrokeColor = badgeStrokeColor
        self.badgeTextColor = badgeTextColor
    }
}

public final class PresentationThemeNavigationSearchBar {
    public let backgroundColor: UIColor
    public let accentColor: UIColor
    public let inputFillColor: UIColor
    public let inputTextColor: UIColor
    public let inputPlaceholderTextColor: UIColor
    public let inputIconColor: UIColor
    public let inputClearButtonColor: UIColor

    public init(backgroundColor: UIColor, accentColor: UIColor, inputFillColor: UIColor, inputTextColor: UIColor, inputPlaceholderTextColor: UIColor, inputIconColor: UIColor, inputClearButtonColor: UIColor) {
        self.backgroundColor = backgroundColor
        self.accentColor = accentColor
        self.inputFillColor = inputFillColor
        self.inputTextColor = inputTextColor
        self.inputPlaceholderTextColor = inputPlaceholderTextColor
        self.inputIconColor = inputIconColor
        self.inputClearButtonColor = inputClearButtonColor
    }
}

public final class PresentationThemeRootController {
    public let tabBar: PresentationThemeRootTabBar
    public let navigationSearchBar: PresentationThemeNavigationSearchBar
    public let keyboardColor: PresentationThemeKeyboardColor

    public init(tabBar: PresentationThemeRootTabBar, navigationSearchBar: PresentationThemeNavigationSearchBar, keyboardColor: PresentationThemeKeyboardColor) {
        self.tabBar = tabBar
        self.navigationSearchBar = navigationSearchBar
        self.keyboardColor = keyboardColor
    }
}

public final class PresentationThemeChatInputPanel {
    public let panelControlAccentColor: UIColor
    public let panelControlColor: UIColor
    public let panelControlDisabledColor: UIColor
    public let inputBackgroundColor: UIColor
    public let inputStrokeColor: UIColor
    public let inputPlaceholderColor: UIColor
    public let inputTextColor: UIColor
    public let inputControlColor: UIColor
    public let actionControlFillColor: UIColor
    public let actionControlForegroundColor: UIColor

    public init(panelControlAccentColor: UIColor, panelControlColor: UIColor, panelControlDisabledColor: UIColor, inputBackgroundColor: UIColor, inputStrokeColor: UIColor, inputPlaceholderColor: UIColor, inputTextColor: UIColor, inputControlColor: UIColor, actionControlFillColor: UIColor, actionControlForegroundColor: UIColor) {
        self.panelControlAccentColor = panelControlAccentColor
        self.panelControlColor = panelControlColor
        self.panelControlDisabledColor = panelControlDisabledColor
        self.inputBackgroundColor = inputBackgroundColor
        self.inputStrokeColor = inputStrokeColor
        self.inputPlaceholderColor = inputPlaceholderColor
        self.inputTextColor = inputTextColor
        self.inputControlColor = inputControlColor
        self.actionControlFillColor = actionControlFillColor
        self.actionControlForegroundColor = actionControlForegroundColor
    }
}

public final class PresentationThemeChat {
    public let inputPanel: PresentationThemeChatInputPanel

    public init(inputPanel: PresentationThemeChatInputPanel) {
        self.inputPanel = inputPanel
    }
}

public final class PresentationTheme {
    public let overallDarkAppearance: Bool
    public let rootController: PresentationThemeRootController
    public let chat: PresentationThemeChat

    public init(overallDarkAppearance: Bool, rootController: PresentationThemeRootController, chat: PresentationThemeChat) {
        self.overallDarkAppearance = overallDarkAppearance
        self.rootController = rootController
        self.chat = chat
    }
}

/// Telegram's localized strings; only the keys copied modules read.
public final class PresentationStrings {
    public let Common_Search: String
    public let Common_Back: String
    public let Common_Close: String
    public let Common_Cancel: String

    public init(Common_Search: String = "Search", Common_Back: String = "Back", Common_Close: String = "Close", Common_Cancel: String = "Cancel") {
        self.Common_Search = Common_Search
        self.Common_Back = Common_Back
        self.Common_Close = Common_Close
        self.Common_Cancel = Common_Cancel
    }
}
