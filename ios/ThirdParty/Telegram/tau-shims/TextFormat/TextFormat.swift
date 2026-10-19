// tau shim for Telegram's TextFormat module (message entities and chat input formatting): the attribute names the
// copied modules use. tau renders Markdown itself.
import Foundation
import UIKit
import TelegramCore

public struct ChatTextInputAttributes {
    public static let bold = NSAttributedString.Key(rawValue: "Attribute__Bold")
    public static let italic = NSAttributedString.Key(rawValue: "Attribute__Italic")
    public static let monospace = NSAttributedString.Key(rawValue: "Attribute__Monospace")
    public static let strikethrough = NSAttributedString.Key(rawValue: "Attribute__Strikethrough")
    public static let underline = NSAttributedString.Key(rawValue: "Attribute__Underline")
    public static let textMention = NSAttributedString.Key(rawValue: "Attribute__TextMention")
    public static let textUrl = NSAttributedString.Key(rawValue: "Attribute__TextUrl")
    public static let date = NSAttributedString.Key(rawValue: "Attribute__Date")
    public static let spoiler = NSAttributedString.Key(rawValue: "Attribute__Spoiler")
    public static let customEmoji = NSAttributedString.Key(rawValue: "Attribute__CustomEmoji")
    public static let block = NSAttributedString.Key(rawValue: "Attribute__Blockquote")
    public static let collapsedBlock = NSAttributedString.Key(rawValue: "Attribute__CollapsedBlockquote")
}

public final class ChatTextInputTextCustomEmojiAttribute: NSObject {
    public enum Custom {
        case nameColors([UInt32])
        case stars(tinted: Bool)
        case ton(tinted: Bool)
        case animation(name: String)
        case verification
        case dice
    }

    public let interactivelySelectedFromPackId: ItemCollectionId?
    public let fileId: Int64
    public let file: TelegramMediaFile?
    public let custom: Custom?
    public let enableAnimation: Bool

    public init(interactivelySelectedFromPackId: ItemCollectionId?, fileId: Int64, file: TelegramMediaFile?, custom: Custom? = nil, enableAnimation: Bool = true) {
        self.interactivelySelectedFromPackId = interactivelySelectedFromPackId
        self.fileId = fileId
        self.file = file
        self.custom = custom
        self.enableAnimation = enableAnimation
    }
}

public let originalTextAttributeKey = NSAttributedString.Key(rawValue: "Attribute__OriginalText")

public final class OriginalTextAttribute: NSObject {
    public let id: Int
    public let string: String

    public init(id: Int, string: String) {
        self.id = id
        self.string = string
    }
}
