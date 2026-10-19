import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import Contacts
import Display
import TelegramUIPreferences
import AppBundle
import PresentationStrings

public struct PresentationDateTimeFormat: Equatable {
    public let timeFormat: PresentationTimeFormat
    public let dateFormat: PresentationDateFormat
    public let dateSeparator: String
    public let dateSuffix: String
    public let requiresFullYear: Bool
    public let decimalSeparator: String
    public let groupingSeparator: String
    
    public init() {
        self.timeFormat = .regular
        self.dateFormat = .monthFirst
        self.dateSeparator = "."
        self.dateSuffix = ""
        self.requiresFullYear = false
        self.decimalSeparator = "."
        self.groupingSeparator = "."
    }
    
    public init(timeFormat: PresentationTimeFormat, dateFormat: PresentationDateFormat, dateSeparator: String, dateSuffix: String, requiresFullYear: Bool, decimalSeparator: String, groupingSeparator: String) {
        self.timeFormat = timeFormat
        self.dateFormat = dateFormat
        self.dateSeparator = dateSeparator
        self.dateSuffix = dateSuffix
        self.requiresFullYear = requiresFullYear
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
    }
}

public struct PresentationAppIcon: Equatable {
    public let name: String
    public let imageName: String
    public let isDefault: Bool
    public let isPremium: Bool
    
    public init(name: String, imageName: String, isDefault: Bool = false, isPremium: Bool = false) {
        self.name = name
        self.imageName = imageName
        self.isDefault = isDefault
        self.isPremium = isPremium
    }
}

public enum PresentationTimeFormat {
    case regular
    case military
}

public enum PresentationDateFormat {
    case monthFirst
    case dayFirst
}

public struct PresentationChatBubbleCorners: Equatable, Hashable {
    public var mainRadius: CGFloat
    public var auxiliaryRadius: CGFloat
    public var mergeBubbleCorners: Bool
    public var hasTails: Bool
    
    public init(mainRadius: CGFloat, auxiliaryRadius: CGFloat, mergeBubbleCorners: Bool, hasTails: Bool = true) {
        self.mainRadius = mainRadius
        self.auxiliaryRadius = auxiliaryRadius
        self.mergeBubbleCorners = mergeBubbleCorners
        self.hasTails = hasTails
    }
}

public final class PresentationData: Equatable {
    public let strings: PresentationStrings
    public let theme: PresentationTheme
    public let autoNightModeTriggered: Bool
    public let chatWallpaper: TelegramWallpaper
    public let chatFontSize: PresentationFontSize
    public let chatBubbleCorners: PresentationChatBubbleCorners
    public let listsFontSize: PresentationFontSize
    public let dateTimeFormat: PresentationDateTimeFormat
    public let nameDisplayOrder: PresentationPersonNameOrder
    public let nameSortOrder: PresentationPersonNameOrder
    public let reduceMotion: Bool
    public let largeEmoji: Bool
    
    public init(strings: PresentationStrings, theme: PresentationTheme, autoNightModeTriggered: Bool, chatWallpaper: TelegramWallpaper, chatFontSize: PresentationFontSize, chatBubbleCorners: PresentationChatBubbleCorners, listsFontSize: PresentationFontSize, dateTimeFormat: PresentationDateTimeFormat, nameDisplayOrder: PresentationPersonNameOrder, nameSortOrder: PresentationPersonNameOrder, reduceMotion: Bool, largeEmoji: Bool) {
        self.strings = strings
        self.theme = theme
        self.autoNightModeTriggered = autoNightModeTriggered
        self.chatWallpaper = chatWallpaper
        self.chatFontSize = chatFontSize
        self.chatBubbleCorners = chatBubbleCorners
        self.listsFontSize = listsFontSize
        self.dateTimeFormat = dateTimeFormat
        self.nameDisplayOrder = nameDisplayOrder
        self.nameSortOrder = nameSortOrder
        self.reduceMotion = reduceMotion
        self.largeEmoji = largeEmoji
    }
    
    public func withUpdated(theme: PresentationTheme) -> PresentationData {
        return PresentationData(strings: self.strings, theme: theme, autoNightModeTriggered: self.autoNightModeTriggered, chatWallpaper: self.chatWallpaper, chatFontSize: self.chatFontSize, chatBubbleCorners: self.chatBubbleCorners, listsFontSize: self.listsFontSize, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, nameSortOrder: self.nameSortOrder, reduceMotion: self.reduceMotion, largeEmoji: self.largeEmoji)
    }
    
    public func withUpdated(chatWallpaper: TelegramWallpaper) -> PresentationData {
        return PresentationData(strings: self.strings, theme: self.theme, autoNightModeTriggered: self.autoNightModeTriggered, chatWallpaper: chatWallpaper, chatFontSize: self.chatFontSize, chatBubbleCorners: self.chatBubbleCorners, listsFontSize: self.listsFontSize, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, nameSortOrder: self.nameSortOrder, reduceMotion: self.reduceMotion, largeEmoji: self.largeEmoji)
    }
    
    public func withUpdate(listsFontSize: PresentationFontSize) -> PresentationData {
        return PresentationData(strings: self.strings, theme: self.theme, autoNightModeTriggered: self.autoNightModeTriggered, chatWallpaper: self.chatWallpaper, chatFontSize: self.chatFontSize, chatBubbleCorners: self.chatBubbleCorners, listsFontSize: listsFontSize, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, nameSortOrder: self.nameSortOrder, reduceMotion: self.reduceMotion, largeEmoji: self.largeEmoji)
    }
    
    public static func ==(lhs: PresentationData, rhs: PresentationData) -> Bool {
        return lhs.strings === rhs.strings && lhs.theme === rhs.theme && lhs.autoNightModeTriggered == rhs.autoNightModeTriggered && lhs.chatWallpaper == rhs.chatWallpaper && lhs.chatFontSize == rhs.chatFontSize && lhs.chatBubbleCorners == rhs.chatBubbleCorners && lhs.listsFontSize == rhs.listsFontSize && lhs.dateTimeFormat == rhs.dateTimeFormat && lhs.reduceMotion == rhs.reduceMotion && lhs.largeEmoji == rhs.largeEmoji
    }
}

private func currentDateTimeFormat() -> PresentationDateTimeFormat {
    let locale = Locale.current
    let dateFormatter = DateFormatter()
    dateFormatter.locale = locale
    dateFormatter.dateStyle = .none
    dateFormatter.timeStyle = .medium
    dateFormatter.timeZone = TimeZone.current
    let dateString = dateFormatter.string(from: Date())
    
    let timeFormat: PresentationTimeFormat
    if dateString.contains(dateFormatter.amSymbol) || dateString.contains(dateFormatter.pmSymbol) {
        timeFormat = .regular
    } else {
        timeFormat = .military
    }
    
    let dateFormat: PresentationDateFormat
    var dateSeparator = "/"
    var dateSuffix = ""
    var requiresFullYear = false
    if let dateString = DateFormatter.dateFormat(fromTemplate: "MdY", options: 0, locale: locale) {
        for separator in [". ", ".", "/", "-", "/"] {
            if dateString.contains(separator) {
                if separator == ". " {
                    dateSuffix = "."
                    dateSeparator = "."
                    requiresFullYear = true
                } else {
                    dateSeparator = separator
                }
                break
            }
        }
        if dateString.contains("M\(dateSeparator)d") {
            dateFormat = .monthFirst
        } else {
            dateFormat = .dayFirst
        }
    } else {
        dateFormat = .dayFirst
    }

    let decimalSeparator = locale.decimalSeparator ?? "."
    let groupingSeparator = locale.groupingSeparator ?? ""
    return PresentationDateTimeFormat(timeFormat: timeFormat, dateFormat: dateFormat, dateSeparator: dateSeparator, dateSuffix: dateSuffix, requiresFullYear: requiresFullYear, decimalSeparator: decimalSeparator, groupingSeparator: groupingSeparator)
}

private func currentPersonNameSortOrder() -> PresentationPersonNameOrder {
    switch CNContactsUserDefaults.shared().sortOrder {
        case .givenName:
            return .firstLast
        default:
            return .lastFirst
    }
}

public func averageColor(from image: UIImage) -> UIColor {
    let context = DrawingContext(size: CGSize(width: 1.0, height: 1.0), scale: 1.0, clear: false)!
    context.withFlippedContext({ context in
        if let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
        }
    })
    return context.colorAt(CGPoint())
}

public func serviceColor(from image: Signal<UIImage?, NoError>) -> Signal<UIColor, NoError> {
    return image
    |> mapToSignal { image -> Signal<UIColor, NoError> in
        if let image = image {
            return .single(serviceColor(with: averageColor(from: image)))
        }
        return .complete()
    }
}

public func serviceColor(for wallpaper: (TelegramWallpaper, UIImage?)) -> UIColor {
    switch wallpaper.0 {
        case .builtin:
            return UIColor(rgb: 0x748391, alpha: 0.45)
        case let .color(color):
            return serviceColor(with: UIColor(argb: color))
        case let .gradient(gradient):
            if gradient.colors.count == 2 {
                let mixedColor = UIColor(argb: gradient.colors[0]).mixedWith(UIColor(argb: gradient.colors[1]), alpha: 0.5)
                return serviceColor(with: mixedColor)
            } else {
                return UIColor(rgb: 0x000000, alpha: 0.3)
            }
        case .image:
            if let image = wallpaper.1 {
                return serviceColor(with: averageColor(from: image))
            } else {
                return UIColor(rgb: 0x000000, alpha: 0.3)
            }
        case let .file(file):
            if wallpaper.0.isPattern {
                if file.settings.colors.count >= 1 && file.settings.colors.count <= 2 {
                    var mixedColor = UIColor(argb: file.settings.colors[0])
                    if file.settings.colors.count >= 2 {
                        mixedColor = mixedColor.mixedWith(UIColor(argb: file.settings.colors[1]), alpha: 0.5)
                    }
                    return serviceColor(with: mixedColor)
                } else {
                    return UIColor(rgb: 0x000000, alpha: 0.3)
                }
            } else if let image = wallpaper.1 {
                return serviceColor(with: averageColor(from: image))
            } else {
                return UIColor(rgb: 0x000000, alpha: 0.3)
            }
        case .emoticon:
            return UIColor(rgb: 0x000000, alpha: 0.3)
    }
}

public func serviceColor(with color: UIColor) -> UIColor {
    var hue:  CGFloat = 0.0
    var saturation: CGFloat = 0.0
    var brightness: CGFloat = 0.0
    var alpha: CGFloat = 0.0
    if color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
        if saturation > 0.0 {
            saturation = min(1.0, saturation + 0.05 + 0.1 * (1.0 - saturation))
        }
        brightness = max(0.0, brightness * 0.65)
        alpha = 0.4
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
    return color
}

private func resolveFontSize(settings: PresentationThemeSettings) -> (chat: PresentationFontSize, lists: PresentationFontSize) {
    let fontSize: PresentationFontSize
    let listsFontSize: PresentationFontSize
    if settings.useSystemFont {
        let pointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        fontSize = PresentationFontSize(systemFontSize: pointSize)
        listsFontSize = fontSize
    } else {
        fontSize = settings.fontSize
        listsFontSize = settings.listsFontSize
    }
    return (fontSize, listsFontSize)
}

public func defaultPresentationData() -> PresentationData {
    let dateTimeFormat = currentDateTimeFormat()
    let nameDisplayOrder: PresentationPersonNameOrder = .firstLast
    let nameSortOrder = currentPersonNameSortOrder()
    
    let themeSettings = PresentationThemeSettings.defaultSettings
    
    let (chatFontSize, listsFontSize) = resolveFontSize(settings: themeSettings)
    
    let chatBubbleCorners = PresentationChatBubbleCorners(mainRadius: CGFloat(themeSettings.chatBubbleSettings.mainRadius), auxiliaryRadius: CGFloat(themeSettings.chatBubbleSettings.auxiliaryRadius), mergeBubbleCorners: themeSettings.chatBubbleSettings.mergeBubbleCorners)
    
    return PresentationData(strings: defaultPresentationStrings, theme: defaultPresentationTheme, autoNightModeTriggered: false, chatWallpaper: defaultPresentationTheme.chat.defaultWallpaper, chatFontSize: chatFontSize, chatBubbleCorners: chatBubbleCorners, listsFontSize: listsFontSize, dateTimeFormat: dateTimeFormat, nameDisplayOrder: nameDisplayOrder, nameSortOrder: nameSortOrder, reduceMotion: themeSettings.reduceMotion, largeEmoji: themeSettings.largeEmoji)
}

public extension PresentationData {
    func withFontSizes(chatFontSize: PresentationFontSize, listsFontSize: PresentationFontSize) -> PresentationData {
        return PresentationData(strings: self.strings, theme: self.theme, autoNightModeTriggered: self.autoNightModeTriggered, chatWallpaper: self.chatWallpaper, chatFontSize: chatFontSize, chatBubbleCorners: self.chatBubbleCorners, listsFontSize: listsFontSize, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, nameSortOrder: self.nameSortOrder, reduceMotion: self.reduceMotion, largeEmoji: self.largeEmoji)
    }
    
    func withChatBubbleCorners(_ chatBubbleCorners: PresentationChatBubbleCorners) -> PresentationData {
        return PresentationData(strings: self.strings, theme: self.theme, autoNightModeTriggered: self.autoNightModeTriggered, chatWallpaper: self.chatWallpaper, chatFontSize: self.chatFontSize, chatBubbleCorners: chatBubbleCorners, listsFontSize: self.listsFontSize, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, nameSortOrder: self.nameSortOrder, reduceMotion: self.reduceMotion, largeEmoji: self.largeEmoji)
    }
    
    func withStrings(_ strings: PresentationStrings) -> PresentationData {
        return PresentationData(strings: strings, theme: self.theme, autoNightModeTriggered: self.autoNightModeTriggered, chatWallpaper: self.chatWallpaper, chatFontSize: self.chatFontSize, chatBubbleCorners: chatBubbleCorners, listsFontSize: self.listsFontSize, dateTimeFormat: self.dateTimeFormat, nameDisplayOrder: self.nameDisplayOrder, nameSortOrder: self.nameSortOrder, reduceMotion: self.reduceMotion, largeEmoji: self.largeEmoji)
    }
}
