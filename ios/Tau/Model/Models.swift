import UIKit

/// One row of the chat list; mirrors the server's `Dialog` (docs/protocol.md).
struct DialogModel: Equatable {
    var id: Int
    var title: String
    /// A subagent's conversation, owned by a tool call in another one.
    var parentConversationId: Int? = nil
    /// The conversation's working directory on the server.
    var cwd: String
    var model: String
    var last: EntrySummary?
    var busy: Bool
    /// Assistant messages the user has not seen.
    var unreadCount: Int = 0
    /// Marked unread by hand (Telegram's Mark as Unread); opening the chat clears it.
    var markedUnread: Bool = false
    /// In Archived Chats.
    var archived: Bool = false
    /// A message to it was refused; Telegram marks the chat with a red badge.
    var hasFailedMessage: Bool = false
    /// This device's latest message to it that is not in the transcript yet: shown as the last message, with the clock
    /// or the red badge.
    var outgoing: Outgoing?
    /// What is written in its input field and not sent: Telegram's red "Draft:" in the list.
    var draft: InputDraft?

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

    var projectName: String {
        return (self.cwd as NSString).lastPathComponent
    }
}

enum MessageRole: Equatable {
    case user
    case assistant
    case tool(name: String)
    /// The model's reasoning before an answer, shown dimmed and folded.
    case thinking
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
    /// What the card shows for the coding tools.
    var detail: ToolDetail = .none
}

/// The coding tools' calls, as their cards show them.
enum ToolDetail: Equatable {
    case none
    case bash(command: String)
    case read(path: String)
    case write(path: String, content: String)
    /// The edit's diff: the result's numbered diff once it ran, the replacements before.
    case edit(path: String, diff: String)
}

/// Something sent with a message: a photo or a file. Images are sent to the model as image content blocks.
struct MessageAttachment: Equatable {
    enum Kind {
        case image(UIImage)
        case file(name: String, size: Int64)
    }

    let id: Int
    let kind: Kind

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
struct ConversationState: Equatable {
    var messages: [ChatMessage]
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
}

/// Where the user left a chat: the message at the bottom of the screen and how far it was scrolled past, as Telegram's
/// ChatInterfaceHistoryScrollState. Nil means the end of the conversation.
struct ChatScrollState: Equatable {
    var messageId: Int
    /// Distance from the bottom of the visible area to the bottom of that message.
    var offset: CGFloat
}
