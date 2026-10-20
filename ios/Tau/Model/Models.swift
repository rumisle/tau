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
    /// A sent message the server has not put in the transcript yet.
    var isPending: Bool = false
    /// The entry this row comes from, for forking at it.
    var entryId: Int?
}

/// What a chat screen renders: committed entries plus the answer still streaming (`pi.live.generation`).
struct ConversationState: Equatable {
    var messages: [ChatMessage]
    /// The partial assistant message while the model streams; replaced by an entry when it finishes.
    var streaming: ChatMessage?
    var busy: Bool
    /// More history exists before the first message.
    var hasOlder: Bool = false
    /// False until the transcript is known (cached or synced), so a chat can wait before showing it.
    var isLoaded: Bool = true
}

/// Where the user left a chat: the message at the bottom of the screen and how far it was scrolled past, as Telegram's
/// ChatInterfaceHistoryScrollState. Nil means the end of the conversation.
struct ChatScrollState: Equatable {
    var messageId: Int
    /// Distance from the bottom of the visible area to the bottom of that message.
    var offset: CGFloat
}
