// tau shim for Telegram's TelegramStringFormatting module: only the API the copied modules use.
import Foundation
import UIKit

/// As TelegramStringFormatting's: 0:42, 12:05, 1:02:03.
public func stringForDuration(_ duration: Int32, position: Int32? = nil) -> String {
    var duration = duration
    if let position {
        duration = max(0, duration - position)
    }
    let hours = duration / 3600
    let minutes = duration / 60 % 60
    let seconds = duration % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

import TelegramPresentationData

/// As in TelegramStringFormatting: "January 5, 2026 at 14:30".
public func stringForFullDate(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
}

public func stringForMonth(strings: PresentationStrings, month: Int32, ofYear year: Int32) -> String {
    let formatter = DateFormatter()
    let name = formatter.monthSymbols[Int(max(0, min(11, month)))]
    let currentYear = Calendar.current.component(.year, from: Date())
    return Int(year) + 1900 == currentYear || Int(year) == currentYear ? name : "\(name) \(year < 1000 ? year + 1900 : year)"
}

public func stringForMonth(strings: PresentationStrings, month: Int32) -> String {
    return DateFormatter().monthSymbols[Int(max(0, min(11, month)))]
}

// GalleryUI's title view names a message's author and date; tau's media viewer has no messages.
import TelegramCore
import TelegramUIPreferences

public func stringForFullAuthorName(message: EngineMessage, strings: PresentationStrings, nameDisplayOrder: PresentationPersonNameOrder, accountPeerId: EnginePeer.Id) -> [String] {
    return []
}

public struct RelativeTimestampFormatString {
    public let string: String
}

public func humanReadableStringForTimestamp(strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, timestamp: Int32) -> RelativeTimestampFormatString {
    return RelativeTimestampFormatString(string: stringForFullDate(timestamp: timestamp, strings: strings, dateTimeFormat: dateTimeFormat))
}
