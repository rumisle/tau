// tau shim for Telegram's ItemListUI module: the types the media picker's album list uses, as in ItemListUI.
import Foundation
import UIKit
import Display
import TelegramPresentationData
import TelegramUIPreferences

public final class ItemListPresentationData: Equatable {
    public let theme: PresentationTheme
    public let fontSize: PresentationFontSize
    public let strings: PresentationStrings
    public let nameDisplayOrder: PresentationPersonNameOrder
    public let dateTimeFormat: PresentationDateTimeFormat

    public init(theme: PresentationTheme, fontSize: PresentationFontSize, strings: PresentationStrings, nameDisplayOrder: PresentationPersonNameOrder, dateTimeFormat: PresentationDateTimeFormat) {
        self.theme = theme
        self.fontSize = fontSize
        self.strings = strings
        self.nameDisplayOrder = nameDisplayOrder
        self.dateTimeFormat = dateTimeFormat
    }

    public convenience init(_ presentationData: PresentationData) {
        self.init(theme: presentationData.theme, fontSize: presentationData.listsFontSize, strings: presentationData.strings, nameDisplayOrder: presentationData.nameDisplayOrder, dateTimeFormat: presentationData.dateTimeFormat)
    }

    public static func ==(lhs: ItemListPresentationData, rhs: ItemListPresentationData) -> Bool {
        return lhs.theme === rhs.theme && lhs.strings === rhs.strings && lhs.fontSize == rhs.fontSize && lhs.nameDisplayOrder == rhs.nameDisplayOrder && lhs.dateTimeFormat == rhs.dateTimeFormat
    }
}

public protocol ListViewItemWithHeader: ListViewItem {
    var header: ListViewItemHeader? { get }
}
