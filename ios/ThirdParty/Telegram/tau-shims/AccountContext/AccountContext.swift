// tau shim for Telegram's AccountContext module. Telegram passes an account context to its components for custom
// emoji, reactions and premium state; tau has no Telegram account, so it always passes nil and the components fall
// back to their plain-text paths. The protocols carry only the members the copied modules read.
import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import LottieSettings
import AnimationCache
import MultiAnimationRenderer
import TextFormat

public struct EnergyUsageSettings: Equatable {
    public var loopEmoji: Bool
    public var loopStickers: Bool
    public var fullTranslucency: Bool
    public var autoplayVideo: Bool
    public var autoplayGif: Bool

    public static let `default` = EnergyUsageSettings(loopEmoji: true, loopStickers: true, fullTranslucency: true, autoplayVideo: true, autoplayGif: true)

    public init(loopEmoji: Bool, loopStickers: Bool, fullTranslucency: Bool, autoplayVideo: Bool, autoplayGif: Bool) {
        self.loopEmoji = loopEmoji
        self.loopStickers = loopStickers
        self.fullTranslucency = fullTranslucency
        self.autoplayVideo = autoplayVideo
        self.autoplayGif = autoplayGif
    }
}

public protocol SharedAccountContext: AnyObject {
    var currentPresentationData: Atomic<PresentationData> { get }
    var energyUsageSettings: EnergyUsageSettings { get }
    var presentationData: Signal<PresentationData, NoError> { get }
}

public protocol AccountContext: AnyObject {
    var sharedContext: SharedAccountContext { get }
    var animationCache: AnimationCache { get }
    var animationRenderer: MultiAnimationRenderer { get }
    var lottieRenderingSettings: LottieRenderingSettings { get }
}

// As in AccountContext/Sources/ChatController.swift.
public enum ChatTextInputStateTextAttributeType: Equatable {
    case bold
    case italic
    case monospace
    case textMention(Int64)
    case textUrl(String)
    case customEmoji(stickerPack: ItemCollectionId?, fileId: Int64, enableAnimation: Bool)
    case strikethrough
    case underline
    case spoiler
}

public struct ChatTextInputStateTextAttribute: Equatable {
    public let type: ChatTextInputStateTextAttributeType
    public let range: Range<Int>

    public init(type: ChatTextInputStateTextAttributeType, range: Range<Int>) {
        self.type = type
        self.range = range
    }
}

public struct ChatTextInputStateText: Equatable {
    public let text: String
    public let attributes: [ChatTextInputStateTextAttribute]

    public init(text: String, attributes: [ChatTextInputStateTextAttribute]) {
        self.text = text
        self.attributes = attributes
    }

    public func attributedText(files: [Int64: TelegramMediaFile] = [:]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: self.text)
        for attribute in self.attributes {
            let range = NSRange(location: attribute.range.lowerBound, length: attribute.range.count)
            switch attribute.type {
            case .bold:
                result.addAttribute(ChatTextInputAttributes.bold, value: true as NSNumber, range: range)
            case .italic:
                result.addAttribute(ChatTextInputAttributes.italic, value: true as NSNumber, range: range)
            case .monospace:
                result.addAttribute(ChatTextInputAttributes.monospace, value: true as NSNumber, range: range)
            case let .textUrl(url):
                result.addAttribute(ChatTextInputAttributes.textUrl, value: url, range: range)
            case let .customEmoji(stickerPack, fileId, enableAnimation):
                result.addAttribute(ChatTextInputAttributes.customEmoji, value: ChatTextInputTextCustomEmojiAttribute(interactivelySelectedFromPackId: stickerPack, fileId: fileId, file: files[fileId], enableAnimation: enableAnimation), range: range)
            default:
                break
            }
        }
        return result
    }
}
