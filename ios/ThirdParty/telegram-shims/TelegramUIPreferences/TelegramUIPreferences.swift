// tau shim for Telegram's TelegramUIPreferences module: the theme and appearance settings types, as in
// TelegramUIPreferences/Sources/PresentationThemeSettings.swift, without their Postbox coding.
import Foundation
import UIKit
import TelegramCore
import Display

public enum PresentationBuiltinThemeReference: Int32 {
    case dayClassic = 0
    case night = 1
    case day = 2
    case nightAccent = 3

    public init(baseTheme: TelegramBaseTheme) {
        switch baseTheme {
        case .classic:
            self = .dayClassic
        case .day:
            self = .day
        case .night:
            self = .night
        case .tinted:
            self = .nightAccent
        }
    }

    public var baseTheme: TelegramBaseTheme {
        switch self {
        case .dayClassic:
            return .classic
        case .day:
            return .day
        case .night:
            return .night
        case .nightAccent:
            return .tinted
        }
    }
}

public struct WallpaperPresentationOptions: OptionSet {
    public var rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = 0
    }

    public static let motion = WallpaperPresentationOptions(rawValue: 1 << 0)
    public static let blur = WallpaperPresentationOptions(rawValue: 1 << 1)
}

public struct PresentationLocalTheme: Equatable {
    public let title: String
    public let resource: LocalFileMediaResource
    public let resolvedWallpaper: TelegramWallpaper?

    public init(title: String, resource: LocalFileMediaResource, resolvedWallpaper: TelegramWallpaper?) {
        self.title = title
        self.resource = resource
        self.resolvedWallpaper = resolvedWallpaper
    }

    public static func ==(lhs: PresentationLocalTheme, rhs: PresentationLocalTheme) -> Bool {
        return lhs.title == rhs.title && lhs.resource.fileId == rhs.resource.fileId && lhs.resolvedWallpaper == rhs.resolvedWallpaper
    }
}

public struct PresentationCloudTheme: Equatable {
    public let theme: TelegramTheme
    public let resolvedWallpaper: TelegramWallpaper?
    public let creatorAccountId: Int64?

    public init(theme: TelegramTheme, resolvedWallpaper: TelegramWallpaper?, creatorAccountId: Int64?) {
        self.theme = theme
        self.resolvedWallpaper = resolvedWallpaper
        self.creatorAccountId = creatorAccountId
    }
}

public enum PresentationThemeReference: Equatable {
    case builtin(PresentationBuiltinThemeReference)
    case local(PresentationLocalTheme)
    case cloud(PresentationCloudTheme)

    public var index: Int64 {
        let namespace: Int32
        let id: Int32

        func themeId(for id: Int64) -> Int32 {
            var acc: UInt32 = 0
            let low = UInt32(UInt64(bitPattern: id) & (0xffffffff as UInt64))
            let high = UInt32((UInt64(bitPattern: id) >> 32) & (0xffffffff as UInt64))
            acc = (acc &* 20261) &+ high
            acc = (acc &* 20261) &+ low
            return Int32(bitPattern: acc & UInt32(0x7fffffff))
        }

        switch self {
        case let .builtin(reference):
            namespace = 0
            id = reference.rawValue
        case let .local(theme):
            namespace = 1
            id = themeId(for: theme.resource.fileId)
        case let .cloud(theme):
            namespace = 2
            id = themeId(for: theme.theme.id)
        }
        return (Int64(namespace) << 32) | Int64(bitPattern: UInt64(UInt32(bitPattern: id)))
    }

    public var generalThemeReference: PresentationThemeReference {
        if case let .cloud(theme) = self, let settings = theme.theme.settings?.first {
            return .builtin(PresentationBuiltinThemeReference(baseTheme: settings.baseTheme))
        }
        return self
    }

    public var emoticon: String? {
        switch self {
        case .builtin(.dayClassic):
            return "🏠"
        case let .cloud(theme):
            return theme.theme.emoticon
        default:
            return nil
        }
    }
}

public func coloredThemeIndex(reference: PresentationThemeReference, accentColor: PresentationThemeAccentColor?) -> Int64 {
    if let accentColor = accentColor {
        if case .builtin = reference {
            return reference.index * 1000 &+ Int64(accentColor.index)
        } else {
            return reference.index &+ Int64(accentColor.index)
        }
    } else {
        return reference.index
    }
}

public enum PresentationFontSize: Int32, CaseIterable {
    case extraSmall = 0
    case small = 1
    case regular = 2
    case large = 3
    case extraLarge = 4
    case extraLargeX2 = 5
    case medium = 6
}

public enum PresentationPersonNameOrder: Int32 {
    case firstLast = 0
    case lastFirst = 1
}

public enum AutomaticThemeSwitchTimeBasedSetting: Equatable {
    case manual(fromSeconds: Int32, toSeconds: Int32)
    case automatic(latitude: Double, longitude: Double, localizedName: String)
}

public enum AutomaticThemeSwitchTrigger: Equatable {
    case system
    case explicitNone
    case timeBased(setting: AutomaticThemeSwitchTimeBasedSetting)
    case brightness(threshold: Double)
}

public struct AutomaticThemeSwitchSetting: Equatable {
    public var force: Bool
    public var trigger: AutomaticThemeSwitchTrigger
    public var theme: PresentationThemeReference

    public init(force: Bool, trigger: AutomaticThemeSwitchTrigger, theme: PresentationThemeReference) {
        self.force = force
        self.trigger = trigger
        self.theme = theme
    }
}

public enum PresentationThemeBaseColor: Int32, CaseIterable {
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
    case custom
    case preset
    case theme

    public var color: UIColor {
        let value: UInt32
        switch self {
        case .blue:
            value = 0x0088ff
        case .cyan:
            value = 0x00c2ed
        case .green:
            value = 0x29b327
        case .pink:
            value = 0xeb6ca4
        case .orange:
            value = 0xf08200
        case .purple:
            value = 0x9472ee
        case .red:
            value = 0xd33213
        case .yellow:
            value = 0xedb400
        case .gray:
            value = 0x6d839e
        case .black:
            value = 0x000000
        case .white:
            value = 0xffffff
        case .custom, .preset, .theme:
            return .clear
        }
        return UIColor(rgb: value)
    }
}

public struct PresentationThemeAccentColor: Equatable {
    public var index: Int32
    public var baseColor: PresentationThemeBaseColor
    public var accentColor: UInt32?
    public var bubbleColors: [UInt32]
    public var wallpaper: TelegramWallpaper?
    public var themeIndex: Int64?

    public init(baseColor: PresentationThemeBaseColor) {
        if baseColor != .preset && baseColor != .custom {
            self.index = baseColor.rawValue + 10
        } else {
            self.index = -1
        }
        self.baseColor = baseColor
        self.accentColor = nil
        self.bubbleColors = []
        self.wallpaper = nil
    }

    public init(index: Int32, baseColor: PresentationThemeBaseColor, accentColor: UInt32? = nil, bubbleColors: [UInt32] = [], wallpaper: TelegramWallpaper? = nil) {
        self.index = index
        self.baseColor = baseColor
        self.accentColor = accentColor
        self.bubbleColors = bubbleColors
        self.wallpaper = wallpaper
    }

    public var color: UIColor {
        if let value = self.accentColor {
            return UIColor(rgb: UInt32(bitPattern: Int32(bitPattern: value)))
        }
        return self.baseColor.color
    }

    public func colorFor(baseTheme: TelegramBaseTheme) -> UIColor {
        if let value = self.accentColor {
            return UIColor(rgb: value)
        } else if baseTheme == .night && self.baseColor == .blue {
            return UIColor(rgb: 0x3e88f7)
        } else {
            return self.baseColor.color
        }
    }

    public var customBubbleColors: [UInt32] {
        return self.bubbleColors
    }

    public var plainBubbleColors: [UInt32] {
        return self.bubbleColors
    }

    public static func ==(lhs: PresentationThemeAccentColor, rhs: PresentationThemeAccentColor) -> Bool {
        return lhs.index == rhs.index && lhs.baseColor == rhs.baseColor && lhs.accentColor == rhs.accentColor && lhs.bubbleColors == rhs.bubbleColors
    }
}

public struct PresentationChatBubbleSettings: Equatable {
    public var mainRadius: Int32
    public var auxiliaryRadius: Int32
    public var mergeBubbleCorners: Bool

    public static var `default`: PresentationChatBubbleSettings = PresentationChatBubbleSettings(mainRadius: 16, auxiliaryRadius: 8, mergeBubbleCorners: true)

    public init(mainRadius: Int32, auxiliaryRadius: Int32, mergeBubbleCorners: Bool) {
        self.mainRadius = mainRadius
        self.auxiliaryRadius = auxiliaryRadius
        self.mergeBubbleCorners = mergeBubbleCorners
    }
}

public struct PresentationThemeSettings: Equatable {
    public var theme: PresentationThemeReference
    public var themePreferredBaseTheme: [Int64: TelegramBaseTheme]
    public var themeSpecificAccentColors: [Int64: PresentationThemeAccentColor]
    public var themeSpecificChatWallpapers: [Int64: TelegramWallpaper]
    public var useSystemFont: Bool
    public var fontSize: PresentationFontSize
    public var listsFontSize: PresentationFontSize
    public var chatBubbleSettings: PresentationChatBubbleSettings
    public var automaticThemeSwitchSetting: AutomaticThemeSwitchSetting
    public var largeEmoji: Bool
    public var reduceMotion: Bool

    public static var defaultSettings: PresentationThemeSettings {
        return PresentationThemeSettings(theme: .builtin(.dayClassic), themePreferredBaseTheme: [:], themeSpecificAccentColors: [:], themeSpecificChatWallpapers: [:], useSystemFont: true, fontSize: .regular, listsFontSize: .regular, chatBubbleSettings: .default, automaticThemeSwitchSetting: AutomaticThemeSwitchSetting(force: false, trigger: .system, theme: .builtin(.night)), largeEmoji: true, reduceMotion: false)
    }

    public init(theme: PresentationThemeReference, themePreferredBaseTheme: [Int64: TelegramBaseTheme], themeSpecificAccentColors: [Int64: PresentationThemeAccentColor], themeSpecificChatWallpapers: [Int64: TelegramWallpaper], useSystemFont: Bool, fontSize: PresentationFontSize, listsFontSize: PresentationFontSize, chatBubbleSettings: PresentationChatBubbleSettings, automaticThemeSwitchSetting: AutomaticThemeSwitchSetting, largeEmoji: Bool, reduceMotion: Bool) {
        self.theme = theme
        self.themePreferredBaseTheme = themePreferredBaseTheme
        self.themeSpecificAccentColors = themeSpecificAccentColors
        self.themeSpecificChatWallpapers = themeSpecificChatWallpapers
        self.useSystemFont = useSystemFont
        self.fontSize = fontSize
        self.listsFontSize = listsFontSize
        self.chatBubbleSettings = chatBubbleSettings
        self.automaticThemeSwitchSetting = automaticThemeSwitchSetting
        self.largeEmoji = largeEmoji
        self.reduceMotion = reduceMotion
    }
}
