import UIKit
import SwiftSignalKit

/// What the screens need from conversations. MockStore serves canned data (UI tests, screenshots); ServerStore syncs
/// with a tau server (docs/protocol.md).
protocol TauStore: AnyObject {
    var connectionStatus: Signal<ConnectionStatus, NoError> { get }
    /// Shown in Settings: where the store gets its data.
    var serverDescription: String { get }

    func dialogsSignal() -> Signal<[DialogModel], NoError>
    func dialog(_ id: Int) -> DialogModel?
    func conversationSignal(_ id: Int) -> Signal<ConversationState, NoError>

    /// A new conversation in `cwd` (nil: the server's default). It stays a draft, out of the chat list, until the first
    /// message.
    func createConversation(cwd: String?) -> Int
    func discardIfDraft(_ id: Int)
    func deleteConversation(_ id: Int)
    func duplicateConversation(_ id: Int) -> Int?

    func send(_ text: String, attachments: [MessageAttachment], to id: Int)
    /// Rewrites a user message: the conversation continues from a fork just before it. Returns the conversation the
    /// chat should show from now on.
    func edit(messageId: Int, text: String, in id: Int, completion: @escaping (Int) -> Void)
    func abort(_ id: Int)
    func loadOlder(_ id: Int)

    /// Models the server has credentials for.
    func models() -> Signal<[ModelInfo], NoError>
    /// The conversation's model and thinking level (`pi.agent`).
    func agent(_ id: Int) -> AgentSettings
    func configure(_ id: Int, model: ModelInfo?, thinkingLevel: String?)
    /// Summarizes the context to free room; the transcript stays.
    func compact(_ id: Int)
    /// Starts a new context: the model forgets the conversation so far; the transcript stays.
    func resetContext(_ id: Int)

    func scrollState(_ id: Int) -> ChatScrollState?
    func setScrollState(_ state: ChatScrollState?, for id: Int)
    func mintAttachmentId() -> Int
}

extension TauStore {
    func send(_ text: String, to id: Int) {
        self.send(text, attachments: [], to: id)
    }
}

struct ModelInfo: Equatable {
    var provider: String
    var id: String
    var name: String
    var reasoning: Bool
}

struct AgentSettings: Equatable {
    var provider: String?
    var modelId: String?
    var thinkingLevel: String?
}

/// Scroll positions survive restarts, as Telegram keeps each chat's position.
final class ScrollStateStorage {
    private let key: String
    private var states: [String: [String: Double]]

    init(namespace: String) {
        self.key = "scroll.\(namespace)"
        self.states = UserDefaults.standard.dictionary(forKey: self.key) as? [String: [String: Double]] ?? [:]
    }

    func get(_ id: Int) -> ChatScrollState? {
        guard let value = self.states["\(id)"], let messageId = value["m"], let offset = value["o"] else {
            return nil
        }
        return ChatScrollState(messageId: Int(messageId), offset: CGFloat(offset))
    }

    func set(_ state: ChatScrollState?, for id: Int) {
        if let state {
            self.states["\(id)"] = ["m": Double(state.messageId), "o": Double(state.offset)]
        } else {
            self.states.removeValue(forKey: "\(id)")
        }
        UserDefaults.standard.set(self.states, forKey: self.key)
    }
}
