import UIKit
import SwiftSignalKit

/// One tau server: its connection, and what it keeps for all its clients.
protocol TauServer: AnyObject {
    /// Stable among the configured servers; part of every conversation ID from it (MultiStore).
    var slot: Int { get }
    /// What the app calls it: the name given, else the computer's name.
    var name: String { get }
    var address: String { get }
    var connectionStatus: Signal<ConnectionStatus, NoError> { get }
    var status: ConnectionStatus { get }
    /// The last round trip to it, in seconds, while connected.
    var latency: Double? { get }
    /// What the server reported about itself; nil until it has.
    var serverInfo: ServerInfo? { get }
    /// The server user's home directory, where a new chat starts unless it picks a project.
    var home: String? { get }
    /// The model new conversations get, as `provider/id`.
    var defaultModel: String? { get }
    func setDefaultModel(_ model: ModelInfo)
    /// The thinking level new conversations get, fitted to their model by the server.
    var defaultThinkingLevel: String { get }
    func setDefaultThinkingLevel(_ level: String)
    /// Where the server pushes answers while no app is in the foreground (server/src/notifier.ts); nil: nowhere.
    var ntfy: NtfyTarget? { get }
    func setNtfy(_ target: NtfyTarget?)
    /// What this phone keeps of the server's chats: their transcripts by conversation, and what waits to be sent.
    func storageUsage() -> StorageUsage
    /// Drops the cached transcripts of chats that are not open; they load again when opened.
    func clearCache()
    /// Models the server has credentials for.
    func models() -> Signal<[ModelInfo], NoError>
    /// A model from the last list, if one came.
    func cachedModel(provider: String, id: String) -> ModelInfo?
    /// One directory of the server's file system, for picking where a conversation runs.
    func listDirectory(_ path: String?) -> Signal<DirectoryListing, RequestError>
}

/// What the screens need: conversations from every configured server (MultiStore), or canned data (MockStore).
protocol TauStore: ConversationStore {
    /// The configured servers, in the order the user keeps them.
    var servers: [TauServer] { get }
    /// After a server is added, removed, renamed or reordered.
    var serversSignal: Signal<[TauServer], NoError> { get }
    func server(_ slot: Int) -> TauServer?
    /// The server a conversation is on.
    func server(of id: Int) -> TauServer?
    /// A new conversation on that server, in `cwd` (nil: the server's home). A draft until its first message.
    func createConversation(server slot: Int, cwd: String?) -> Int
    /// A new chat moved to another project before its first message: the same draft on that server, else a new one
    /// there with what was written. Returns the chat's ID from now on.
    func relocateDraft(_ id: Int, to location: ProjectLocation) -> Int
    var isDemo: Bool { get }
    func addServer(address: String, token: String?, name: String?)
    func updateServer(_ slot: Int, address: String, token: String?, name: String?)
    func removeServer(_ slot: Int)
    func moveServer(from: Int, to: Int)
    func serverToken(_ slot: Int) -> String?
}

/// One server's conversations (ServerStore), or the canned ones.
protocol ConversationStore: AnyObject {
    /// Every server's status together: Telegram's chat list title.
    var connectionStatus: Signal<ConnectionStatus, NoError> { get }
    /// A conversation's run ended with an answer, live: Telegram's in-app banner shows it.
    var answers: Signal<ChatAnswer, NoError> { get }
    /// A chat's unsent input (docs: InputDrafts.swift); a chat not created yet has the New Chat draft.
    func inputDraft(_ id: Int) -> InputDraft?
    func setInputDraft(_ draft: InputDraft?, for id: Int)
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
    /// A copy of the conversation up to just before `entryId`, as a draft until its first message (as an edit's fork,
    /// without the message). Nil when there is nothing before it.
    func forkBefore(entryId: Int, in id: Int) -> Int?
    /// Its background subagents' conversations, oldest first.
    func subagents(of id: Int) -> [DialogModel]
    /// The chat is on screen: everything in it so far is read.
    func markSeen(_ id: Int)
    /// Mark as Read / Mark as Unread.
    func setUnread(_ id: Int, _ unread: Bool)
    func setArchived(_ id: Int, _ archived: Bool)
    /// Pin to the top of the list, or unpin; a new pin goes above the others.
    func setPinned(_ id: Int, _ pinned: Bool)

    /// Sends a message (docs/sending.md). While the agent works, a steer reaches it after its current step and a
    /// follow-up once its run ends; idle, both start a run.
    func send(_ text: String, attachments: [MessageAttachment], to id: Int, mode: SendMode)
    /// Rewrites a user message: the conversation continues from a fork just before it. Returns the conversation the
    /// chat should show from now on.
    func edit(messageId: Int, text: String, in id: Int, completion: @escaping (Int) -> Void)
    /// Stops the agent. Queued messages come back to the input field, as pi's Escape returns them to the editor.
    func stop(_ id: Int)
    /// Stops the agent, as `stop`, and sends a new message at once.
    func stopAndSend(_ text: String, attachments: [MessageAttachment], in id: Int)
    /// Stops the agent and sends this queued message at once; the others come back to the input field.
    func sendNow(_ queued: QueuedMessage, in id: Int)
    /// Takes a queued message back before the agent gets it; `restore` puts its text in the input field (Edit).
    func withdraw(_ queued: QueuedMessage, in id: Int, restore: Bool)
    /// Queues a message again as a steer or a follow-up.
    func move(_ queued: QueuedMessage, in id: Int, to mode: SendMode)
    /// A refused message, sent again as a new one.
    func resend(_ outgoingId: String, in id: Int)
    /// Drops a refused message.
    func discard(_ outgoingId: String, in id: Int)
    /// What the chat must act on: withdrawn text for the input field, and notices.
    func chatEvents(_ id: Int) -> Signal<ChatEvent, NoError>
    func loadOlder(_ id: Int)

    /// The conversation's model and thinking level (`pi.agent`).
    func agent(_ id: Int) -> AgentSettings
    func configure(_ id: Int, model: ModelInfo?, thinkingLevel: String?)
    /// Summarizes the context to free room; the transcript stays.
    func compact(_ id: Int)
    /// A name the user gave; the server's automatic naming never replaces it.
    func rename(_ id: Int, title: String)
    /// Starts a new context: the model forgets the conversation so far; the transcript stays.
    func resetContext(_ id: Int)
    /// What the conversation has spent, and how full its context is.
    func usage(_ id: Int) -> ConversationUsage

    func scrollState(_ id: Int) -> ChatScrollState?
    func setScrollState(_ state: ChatScrollState?, for id: Int)
    func mintAttachmentId() -> Int
}

enum SendMode: Equatable {
    case steer
    case followUp
}

enum ChatEvent: Equatable {
    /// A withdrawn message's text, for the input field.
    case restoreInput(String)
    case notice(String)
}

extension ConversationStore {
    func send(_ text: String, to id: Int) {
        self.send(text, attachments: [], to: id, mode: .steer)
    }

    func send(_ text: String, attachments: [MessageAttachment], to id: Int) {
        self.send(text, attachments: attachments, to: id, mode: .steer)
    }
}

struct ModelInfo: Equatable {
    var provider: String
    var id: String
    var name: String
    var reasoning: Bool
    /// The thinking levels it has, `off` first (pi-ai's getSupportedThinkingLevels).
    var thinkingLevels: [String] = ["off"]
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

/// Bytes on this phone for one server.
struct StorageUsage: Equatable {
    /// Cached transcripts, by conversation ID, largest first.
    var chats: [(id: Int, bytes: Int64)] = []
    /// Messages and photos not sent yet.
    var unsentBytes: Int64 = 0
    var draftBytes: Int64 = 0

    var cacheBytes: Int64 {
        return self.chats.reduce(0) { $0 + $1.bytes }
    }

    static func == (lhs: StorageUsage, rhs: StorageUsage) -> Bool {
        return lhs.chats.map(\.id) == rhs.chats.map(\.id) && lhs.chats.map(\.bytes) == rhs.chats.map(\.bytes) && lhs.unsentBytes == rhs.unsentBytes && lhs.draftBytes == rhs.draftBytes
    }
}

/// A new answer of a chat, for its banner.
struct ChatAnswer: Equatable {
    var conversationId: Int
    var title: String
    var text: String
}

/// An ntfy server and a topic only this user's phone subscribes to.
struct NtfyTarget: Equatable {
    var server: String
    var topic: String
}

struct ServerInfo: Equatable {
    /// The database's ID (`hello`): what a push names its server by.
    var serverId: String = ""
    var address: String
    var hostname: String
    var piRevision: String
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
