import UIKit

/// One row of the chat list; mirrors the server's `Dialog` (docs/protocol.md).
struct DialogModel: Equatable {
    var id: Int
    var title: String
    /// A subagent's conversation, owned by a tool call in another one.
    var parentConversationId: Int? = nil
    /// The server it is on (TauServer.slot).
    var serverSlot: Int = 0
    /// That server's name, while there is more than one server.
    var serverName: String?

    var model: String
    var last: EntrySummary?
    var busy: Bool
    /// Assistant messages the user has not seen.
    var unreadCount: Int = 0
    /// Marked unread by hand (Telegram's Mark as Unread); opening the chat clears it.
    var markedUnread: Bool = false
    /// In Archived Chats.
    var archived: Bool = false
    /// Hidden by Hide, on every device: out of every list and search. The server keeps it, as it keeps every chat.
    var hidden: Bool = false
    /// Pinned to the top of its list: the sort key, higher first (when it was pinned).
    var pinned: Double?
    /// A message to it was refused; Telegram marks the chat with a red badge.
    var hasFailedMessage: Bool = false
    /// This device's latest message to it that is not in the transcript yet: shown as the last message, with the clock
    /// or the red badge.
    var outgoing: Outgoing?
    /// What is written in its input field and not sent: Telegram's red "Draft:" in the list.
    var draft: InputDraft?
    /// Its background subagents working now, by name: the chat shows them as Telegram shows who is typing.
    var workingSubagents: [String] = []

    /// "reader working", "2 subagents working".
    var subagentActivity: String? {
        switch self.workingSubagents.count {
        case 0:
            return nil
        case 1:
            return "\(self.workingSubagents[0]) working"
        default:
            return "\(self.workingSubagents.count) subagents working"
        }
    }

    struct Outgoing: Equatable {
        var text: String
        var date: Date
        var failed: Bool
    }

    var isUnread: Bool {
        return self.unreadCount > 0 || self.markedUnread
    }

    struct EntrySummary: Equatable {
        var id: Int
        var role: MessageRole
        var text: String
        var date: Date
    }

}

enum MessageRole: Equatable {
    case user
    case assistant
    case tool(name: String)
    /// The model's reasoning before an answer, shown dimmed.
    case thinking
    /// Not a message: what happened to the conversation (a compaction), centered as Telegram's service messages.
    case service
}

/// What a service row says.
enum ServiceContent: Equatable {
    /// A summary being made, since `since`; `waiting` once made, until a run's next step places it.
    case compacting(since: Date, waiting: Bool)
    /// The summary that now stands in for what came before it, for the model: the context's size before and after it
    /// (tokens) and what it cost, when known.
    case compacted(summary: String, reason: String, before: Int?, after: Int?, cost: Double?)
    /// A compaction that ended unused: the chat moved past it (`stale`), it failed (`error`), or there was nothing to
    /// compact (`empty`).
    case compactionUnused(state: String, error: String?)
    /// A run that ended on a model error, after the server's own retries: why, cleaned up to read.
    case failed(error: String)
}

/// The server waiting to ask the model again after an error (durable's retry backoff, `pi.live.generation`).
struct RetryState: Equatable {
    /// The attempt the next request is; 2 for the first retry.
    var attempt: Int
    /// When it asks again; nil once the request is out.
    var at: Date?
    /// The error that led to it, in a few words.
    var reason: String
}

/// When a run ended and how long it took, from its first message to its answer.
struct TurnInfo: Equatable {
    var finishedAt: Date
    /// Unknown when the run began before the loaded transcript.
    var duration: TimeInterval?
    /// Model errors the server retried past in this run.
    var retries: Int = 0
}

/// A tool call and, once it finished, its result: one card in the transcript.
struct ToolCallInfo: Equatable {
    enum Status: Equatable {
        /// The model is still writing the arguments.
        case preparing
        case pending
        case running
        case done
        case failed
        /// Cut off with its run (Stop while the model wrote it): it never ran, and will not.
        case stopped
    }

    var callId: String
    var name: String
    /// One line saying what the call does: the command, the file, the subagent's task.
    var summary: String
    var status: Status
    /// The end of the output, while running or once done.
    var output: String?
    /// A subagent's conversation, which the card opens.
    var childConversationId: Int?
    /// Whether that subagent is working now: a background subagent works on after its call has returned.
    var childBusy: Bool = false
    /// What the card shows for the coding tools.
    var detail: ToolDetail = .none
    /// When it began: the end of the answer that made the call. Nil while that answer is written.
    var startedAt: Date?
    /// How long it took, once done (the result's own measure).
    var duration: TimeInterval?
    /// A background subagent's call or answer, which has a card of its own.
    var subagent: SubagentCall?
    /// Images the result gave the model, as the read tool returns an image file: the card shows them.
    var images: [MessageAttachment] = []
    /// What `send_file` sent the user (server/src/send-file.ts): shown in the chat as photos and files, with no card.
    var sentFiles: [MessageAttachment] = []
    /// A code mode script's calls, in the order it made them (docs/codemode.md): lines of its card.
    var nested: [NestedToolCall] = []
}

/// A call a code mode script made. Its result went to the script, not the transcript: the card keeps a line of it.
struct NestedToolCall: Equatable {
    enum Status: Equatable {
        case running
        case done
        case failed
        /// Still running when the script ended.
        case cancelled
    }

    var name: String
    /// What it works on, as a card's title says it: the command, the file.
    var summary: String
    var status: Status
    var duration: TimeInterval?
    /// A failed call's error, cut.
    var error: String?
    /// While it runs, the end of its output so far.
    var output: String?
}

/// One step of a background subagent, as its card shows it: the subagent, as the quote Telegram puts over a reply, and
/// what happened.
struct SubagentCall: Equatable {
    enum Kind: Equatable {
        case spawn
        case send
        case stop
        /// Its answer, posted back to the conversation that started it.
        case answer
        case failed
    }

    var kind: Kind
    var name: String
    /// The task, the message sent, or the answer.
    var text: String
    /// The task it was started with, which an answer's quote repeats.
    var task: String?
    /// Another model than the parent's, as `provider/id`.
    var model: String?
    var thinking: String?
    var fork: Bool = false
    /// A spawn or message: when it went out. An answer: how long the subagent took, from then.
    var startedAt: Date?
    var duration: TimeInterval?
}

/// The coding tools' calls, as their cards show them.
enum ToolDetail: Equatable {
    case none
    case bash(command: String)
    case read(path: String)
    case write(path: String, content: String)
    /// The edit's diff: the result's numbered diff once it ran, the replacements before.
    case edit(path: String, diff: String)
    /// A code mode script, and once it failed, its error (the output it wrote before is the call's output).
    case code(script: String, error: String?)
}

/// A file of a message, the user's or what the agent sent (docs/files.md): on the server once it has its ID, fetched
/// from `/files/<id>` when opened.
struct FileAttachment: Equatable {
    var name: String
    var size: Int64
    var mimeType: String
    /// The server's ID for it.
    var serverId: String?
    /// The device's copy while it is on its way (the outbox's): opened from there.
    var localURL: URL?
    /// What the transfer of it is known by while it uploads (Server/FileTransfer.swift).
    var transferKey: String?
    /// An image's pixels, as the server read them from its header: the agent's images show as photos.
    var pixelSize: CGSize?

    var isImage: Bool {
        return ["image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif"].contains(self.mimeType)
    }
}

/// Something sent with a message: a photo or a file. Photos go to the model as image blocks too; files only by path.
struct MessageAttachment: Equatable {
    enum Kind {
        case image(UIImage)
        /// On the server, fetched when shown (Server/MediaLoader.swift).
        case remote(RemoteImage)
        case file(FileAttachment)
    }

    let id: Int
    let kind: Kind

    /// A photo, here or on the server; not a file.
    var isPhoto: Bool {
        switch self.kind {
        case .image, .remote:
            return true
        case .file:
            return false
        }
    }

    static func == (lhs: MessageAttachment, rhs: MessageAttachment) -> Bool {
        return lhs.id == rhs.id
    }
}

/// A transcript entry as the chat shows it. The server's entries are richer (`pi.user`, `pi.assistant`,
/// `pi.tool-result`, ...); the client flattens them into these.
struct ChatMessage: Equatable {
    var id: Int
    var role: MessageRole
    var text: String
    var date: Date
    var attachments: [MessageAttachment] = []
    var tool: ToolCallInfo?
    /// Still being written by the model (`pi.live`).
    var isStreaming: Bool = false
    /// A user message's status, as Telegram's clock, checks and red badge (docs/sending.md).
    var delivery: Delivery = .delivered
    /// The outgoing message a sending or failed row shows: its request ID, for Resend and Delete.
    var outgoingId: String?
    /// The entry this row comes from, for forking at it.
    var entryId: Int?
    /// On the last answer of a run: when it ended, and how long it took.
    var turn: TurnInfo?
    /// Not a message: the agent is working and has nothing to show yet (ChatWaitingNode).
    var isWaiting: Bool = false
    /// On the waiting row: the server retrying after a model error.
    var retry: RetryState?
    var service: ServiceContent?

    enum Delivery: Equatable {
        /// Not acknowledged by the server: the clock.
        case sending
        /// In the transcript: the model has it. Two checks.
        case delivered
        /// Refused by the server; Resend or Delete.
        case failed(reason: String)
    }
}

/// A message waiting for the agent's next step (steer) or the end of its run (follow-up), or a queued new context:
/// what the input panel's queue shows. It is not in the transcript yet; the server's inbox (`pi.inbox`) holds it, or it
/// is still on its way there.
struct QueuedMessage: Equatable {
    enum Mode: Equatable {
        case steer
        case followUp
        case newContext
    }

    /// Stable across the switch from on its way to queued.
    let id: String
    var mode: Mode
    var text: String
    var imageCount: Int
    /// On its way to the server: the clock; queued: one check.
    var isSending: Bool
    /// The outgoing message this device sent; nil when another device sent it.
    var outgoingId: String?
    var submissionId: Int?
}

/// What a chat screen renders: committed entries plus the answer still streaming (`pi.live.generation`).
/// Equatable by the synthesized ==, so no property can be left out of it; only the rows compare their own way
/// (`Transcript`).
struct ConversationState: Equatable {
    /// The rows with their stable prefix.
    var transcript: Transcript
    /// The partial assistant message while the model streams; replaced by an entry when it finishes.
    var streaming: ChatMessage?
    var busy: Bool
    /// Waiting to reach the model, in the order they will.
    var queued: [QueuedMessage] = []
    /// More history exists before the first message.
    var hasOlder: Bool = false
    /// False until the transcript is known (cached or synced), so a chat can wait before showing it.
    var isLoaded: Bool = true
    /// The model and thinking level, which the title shows.
    var agent: AgentSettings?
    /// The conversation's title, so a rename reaches an open chat.
    var title: String?
    /// While it works: when the run began, for the title's timer.
    var runStartedAt: Date?
    /// The newest compaction that failed, until one succeeds: its task and why.
    var compactionFailure: CompactionFailure?
    /// While the server retries after a model error.
    var retry: RetryState?
    /// The run waits for a compaction (past the blocking threshold): the title says compacting, not working.
    var compactionBlocksRun = false

    init(messages: [ChatMessage], streaming: ChatMessage?, busy: Bool, queued: [QueuedMessage] = [], hasOlder: Bool = false, isLoaded: Bool = true) {
        self.transcript = Transcript(messages: messages)
        self.streaming = streaming
        self.busy = busy
        self.queued = queued
        self.hasOlder = hasOlder
        self.isLoaded = isLoaded
    }

    var messages: [ChatMessage] {
        get {
            return self.transcript.messages
        }
        // In place: a row changed through it does not copy the others.
        _modify {
            yield &self.transcript.messages
        }
    }

    /// The first `count` messages are the same in every state with this token: the chat compares and lays out only
    /// what comes after them.
    var stablePrefix: StablePrefix? {
        get {
            return self.transcript.stablePrefix
        }
        _modify {
            yield &self.transcript.stablePrefix
        }
    }
}

/// A state's rows: two with one stable prefix are compared after it only.
struct Transcript: Equatable {
    var messages: [ChatMessage]
    var stablePrefix: StablePrefix?

    static func == (lhs: Transcript, rhs: Transcript) -> Bool {
        guard lhs.stablePrefix == rhs.stablePrefix, lhs.messages.count == rhs.messages.count else {
            return false
        }
        let start = min(lhs.stablePrefix?.count ?? 0, lhs.messages.count)
        return lhs.messages[start...] == rhs.messages[start...]
    }
}

struct StablePrefix: Equatable {
    var token: Int
    var count: Int
}

struct CompactionFailure: Equatable {
    var taskId: Int
    var error: String
}

/// Where the user left a chat: the message at the bottom of the screen and how far it was scrolled past, as Telegram's
/// ChatInterfaceHistoryScrollState. Nil means the end of the conversation.
struct ChatScrollState: Equatable {
    var messageId: Int
    /// Distance from the bottom of the visible area to the bottom of that message.
    var offset: CGFloat
}
