// tau shim for Telegram's ChatPresentationInterfaceState module: the state the attachment menu's caption field reads.
// Telegram's is the whole chat screen's state; tau keeps the caption text and how many items are selected.
import Foundation
import UIKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import TelegramUIPreferences

public struct ChatInterfaceState: Equatable {
    public var composeInputState: ChatTextInputState
    public var forwardMessageIds: [EngineMessage.Id]?

    public init(composeInputState: ChatTextInputState = ChatTextInputState(), forwardMessageIds: [EngineMessage.Id]? = nil) {
        self.composeInputState = composeInputState
        self.forwardMessageIds = forwardMessageIds
    }

    public var effectiveInputState: ChatTextInputState {
        return self.composeInputState
    }

    public func withUpdatedComposeInputState(_ state: ChatTextInputState) -> ChatInterfaceState {
        var result = self
        result.composeInputState = state
        return result
    }

    public func withUpdatedForwardMessageIds(_ ids: [EngineMessage.Id]?) -> ChatInterfaceState {
        var result = self
        result.forwardMessageIds = ids
        return result
    }
}

public enum ChatPresentationInterfaceStateMode: Equatable {
    public enum StandardMode: Equatable {
        case `default`
        case previewing
    }

    case standard(StandardMode)
}

public enum ChatPreferredGlassType: Equatable {
    case `default`
    case clear
}

public final class ChatPresentationInterfaceState {
    public let theme: PresentationTheme
    public let strings: PresentationStrings
    public let chatLocation: ChatLocation
    public let interfaceState: ChatInterfaceState
    public let customEmojiAvailable: Bool

    public init(chatWallpaper: TelegramWallpaper, theme: PresentationTheme, preferredGlassType: ChatPreferredGlassType, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, nameDisplayOrder: PresentationPersonNameOrder, limitsConfiguration: LimitsConfiguration, fontSize: PresentationFontSize, bubbleCorners: PresentationChatBubbleCorners, accountPeerId: PeerId, mode: ChatPresentationInterfaceStateMode, chatLocation: ChatLocation, subject: Any?, greetingData: Any?, pendingUnpinnedAllMessages: Bool, activeGroupCallInfo: Any?, hasActiveGroupCall: Bool, threadData: Any?, isGeneralThreadClosed: Bool?, replyMessage: Any?, accountPeerColor: Any?, businessIntro: Any?) {
        self.theme = theme
        self.strings = strings
        self.chatLocation = chatLocation
        self.interfaceState = ChatInterfaceState()
        self.customEmojiAvailable = false
    }

    private init(theme: PresentationTheme, strings: PresentationStrings, chatLocation: ChatLocation, interfaceState: ChatInterfaceState, customEmojiAvailable: Bool) {
        self.theme = theme
        self.strings = strings
        self.chatLocation = chatLocation
        self.interfaceState = interfaceState
        self.customEmojiAvailable = customEmojiAvailable
    }

    public func updatedTheme(_ theme: PresentationTheme) -> ChatPresentationInterfaceState {
        return ChatPresentationInterfaceState(theme: theme, strings: self.strings, chatLocation: self.chatLocation, interfaceState: self.interfaceState, customEmojiAvailable: self.customEmojiAvailable)
    }

    public func updatedCustomEmojiAvailable(_ value: Bool) -> ChatPresentationInterfaceState {
        return ChatPresentationInterfaceState(theme: self.theme, strings: self.strings, chatLocation: self.chatLocation, interfaceState: self.interfaceState, customEmojiAvailable: value)
    }

    public func updatedInterfaceState(_ f: (ChatInterfaceState) -> ChatInterfaceState) -> ChatPresentationInterfaceState {
        return ChatPresentationInterfaceState(theme: self.theme, strings: self.strings, chatLocation: self.chatLocation, interfaceState: f(self.interfaceState), customEmojiAvailable: self.customEmojiAvailable)
    }
}

/// The chat's panel callbacks. The caption field calls none of them in tau.
public final class ChatPanelInterfaceInteraction {
    public init() {}
}
