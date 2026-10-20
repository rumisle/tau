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
import Display
import AsyncDisplayKit

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
    var mainWindow: Window1? { get }
    var applicationBindings: TelegramApplicationBindings { get }
    var presentationData: Signal<PresentationData, NoError> { get }
}

public protocol AccountContext: AnyObject {
    var sharedContext: SharedAccountContext { get }
    var account: Account { get }
    var currentLimitsConfiguration: Atomic<LimitsConfiguration> { get }
    var currentAppConfiguration: Atomic<AppConfiguration> { get }
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

// As in AccountContext/Sources/AttachmentMainButtonState.swift.
public struct AttachmentMainButtonState {
    public enum Background {
        case color(UIColor)
        case premium
        
        public var colorValue: UIColor? {
            if case let .color(color) = self {
                return color
            }
            return nil
        }
    }
    
    public enum Progress: Equatable {
        case none
        case side
        case center
    }
    
    public enum Font: Equatable {
        case regular
        case bold
    }
    
    public enum Position: String, Equatable {
        case top
        case bottom
        case left
        case right
    }
    
    public let text: String?
    public let badge: String?
    public let font: Font
    public let background: Background
    public let textColor: UIColor
    public let isVisible: Bool
    public let progress: Progress
    public let isEnabled: Bool
    public let hasShimmer: Bool
    public let iconName: String?
    public let iconCustomEmojiId: Int64?
    public let smallSpacing: Bool
    public let position: Position?
    public let hidesPanelBackground: Bool
    /// The button is an alternative to the tabs' content (e.g. "Edit Current Photo" while replacing a
    /// message's media), so it is laid out above the tab row instead of replacing it.
    public let keepsTabRow: Bool
    
    public init(
        text: String?,
        badge: String? = nil,
        font: Font,
        background: Background,
        textColor: UIColor,
        isVisible: Bool,
        progress: Progress,
        isEnabled: Bool,
        hasShimmer: Bool,
        iconName: String? = nil,
        iconCustomEmojiId: Int64? = nil,
        smallSpacing: Bool = false,
        position: Position? = nil,
        hidesPanelBackground: Bool = false,
        keepsTabRow: Bool = false
    ) {
        self.text = text
        self.badge = badge
        self.font = font
        self.background = background
        self.textColor = textColor
        self.isVisible = isVisible
        self.progress = progress
        self.isEnabled = isEnabled
        self.hasShimmer = hasShimmer
        self.iconName = iconName
        self.iconCustomEmojiId = iconCustomEmojiId
        self.smallSpacing = smallSpacing
        self.position = position
        self.hidesPanelBackground = hidesPanelBackground
        self.keepsTabRow = keepsTabRow
    }
    
    public static var initial: AttachmentMainButtonState {
        return AttachmentMainButtonState(text: nil, font: .bold, background: .color(.clear), textColor: .clear, isVisible: false, progress: .none, isEnabled: false, hasShimmer: false)
    }
}

// MARK: Chats, as in AccountContext/Sources/AccountContext.swift

public enum ChatLocation: Equatable {
    case peer(id: EnginePeer.Id)
    case customChatContents

    public var peerId: EnginePeer.Id? {
        if case let .peer(id) = self {
            return id
        }
        return nil
    }
}

public enum AttachmentTextInputPanelSendMode {
    case generic
    case silent
    case schedule
    case whenOnline
}

public struct ChatSendMessageActionSheetControllerSendParameters {
    public struct Effect {
        public let id: Int64

        public init(id: Int64) {
            self.id = id
        }
    }

    public var effect: Effect?
    public var textIsAboveMedia: Bool

    public init(effect: Effect?, textIsAboveMedia: Bool) {
        self.effect = effect
        self.textIsAboveMedia = textIsAboveMedia
    }
}

public enum ChatSendMessageActionSheetControllerSendMode {
    case generic
    case silently
    case whenOnline
}

public protocol ChatSendMessageActionSheetController: ViewController {
    typealias SendMode = ChatSendMessageActionSheetControllerSendMode
    typealias SendParameters = ChatSendMessageActionSheetControllerSendParameters
}

/// The text of a message being written, as in AccountContext's ChatTextInputState, without its rich-text model.
public struct ChatTextInputState: Equatable {
    public var inputText: NSAttributedString
    public var selectionRange: Range<Int>

    public init(inputText: NSAttributedString = NSAttributedString(), selectionRange: Range<Int>? = nil) {
        self.inputText = inputText
        self.selectionRange = selectionRange ?? (inputText.length ..< inputText.length)
    }

    public static func ==(lhs: ChatTextInputState, rhs: ChatTextInputState) -> Bool {
        return lhs.inputText.isEqual(to: rhs.inputText) && lhs.selectionRange == rhs.selectionRange
    }
}

public protocol MediaPickerScreen: ViewController {
    func dismissAnimated()
}

public enum PeerType: Equatable {
    case user(isBot: Bool)
    case group
    case channel
    case community
}

public final class TelegramApplicationBindings {
    public let openSettings: () -> Void

    public init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
    }
}

// As in AccountContext/Sources/UniversalVideoNode.swift; tau's media viewer shows images only, so no video decorates it.
public protocol UniversalVideoDecoration: AnyObject {
    var backgroundNode: ASDisplayNode? { get }
    var contentContainerNode: ASDisplayNode { get }
    var foregroundNode: ASDisplayNode? { get }
}

// As in AccountContext/Sources/ChatController.swift: the chat under a media viewer, which recedes while it shows.
public protocol ChatController: ViewController {
    func updatePushedTransition(_ fraction: CGFloat, transition: ContainedViewLayoutTransition)
}
