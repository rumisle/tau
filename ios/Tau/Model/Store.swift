import UIKit
import SwiftSignalKit

/// What the screens need from conversations. MockStore serves canned data (UI tests, screenshots); ServerStore syncs
/// with a tau server (docs/protocol.md).
protocol TauStore: AnyObject {
    var connectionStatus: Signal<ConnectionStatus, NoError> { get }
    /// Shown in Settings: where the store gets its data.
    var serverDescription: String { get }
    /// The model new conversations get, as `provider/id`.
    var defaultModel: String? { get }
    /// Stops syncing, before the app switches to another store.
    func close()

    func dialogsSignal() -> Signal<[DialogModel], NoError>
    func dialog(_ id: Int) -> DialogModel?
    func conversationSignal(_ id: Int) -> Signal<ConversationState, NoError>

    /// A new conversation in `cwd` (nil: the server's default). It stays a draft, out of the chat list, until the first
    /// message.
    func createConversation(cwd: String?) -> Int
    func discardIfDraft(_ id: Int)
    func deleteConversation(_ id: Int)
    /// Forks the conversation at its last entry; `completion` gets the copy's id.
    func duplicateConversation(_ id: Int, completion: @escaping (Int) -> Void)
    /// The chat is on screen: everything in it so far is read.
    func markSeen(_ id: Int)
    /// Mark as Read / Mark as Unread.
    func setUnread(_ id: Int, _ unread: Bool)
    func setArchived(_ id: Int, _ archived: Bool)
    /// The model new conversations get, for every client of the server.
    func setDefaultModel(_ model: ModelInfo)

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
    /// What the conversation has spent, and how full its context is.
    func usage(_ id: Int) -> ConversationUsage

    /// One directory of the server's file system, for picking where a conversation runs.
    func listDirectory(_ path: String?) -> Signal<DirectoryListing, RequestError>

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
    /// Tokens the model takes in at most.
    var contextWindow: Int? = nil
}

/// Tokens and dollars, as pi-ai's `Usage`.
struct TokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        return TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cost: lhs.cost + rhs.cost)
    }
}

/// A conversation's spend (`pi.usage`) and how full its context is.
struct ConversationUsage: Equatable {
    /// Spend by `provider/modelId`, most expensive first.
    var models: [(model: String, usage: TokenUsage)]
    /// Tokens the model saw in the latest response of the current context, as pi's footer shows; nil before the
    /// first response of a context.
    var contextTokens: Int?
    var contextWindow: Int?

    var total: TokenUsage {
        return self.models.reduce(TokenUsage()) { $0 + $1.usage }
    }

    static func == (lhs: ConversationUsage, rhs: ConversationUsage) -> Bool {
        return lhs.models.map(\.model) == rhs.models.map(\.model) && lhs.models.map(\.usage) == rhs.models.map(\.usage) && lhs.contextTokens == rhs.contextTokens && lhs.contextWindow == rhs.contextWindow
    }
}

struct DirectoryListing: Equatable {
    struct Entry: Equatable {
        var name: String
        var isDirectory: Bool
        /// A git repository root.
        var isRepository: Bool
    }

    var path: String
    var parent: String?
    var entries: [Entry]
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
