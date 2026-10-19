import Foundation

/// One row of the chat list; mirrors the server's `Dialog` (docs/protocol.md).
struct DialogModel: Equatable {
    var id: Int
    var title: String
    /// The conversation's working directory on the server.
    var cwd: String
    var model: String
    var last: EntrySummary?
    var busy: Bool

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
}

/// A transcript entry as the chat shows it. The server's entries are richer (`pi.user`, `pi.assistant`,
/// `pi.tool-result`, ...); the client flattens them into these.
struct ChatMessage: Equatable {
    var id: Int
    var role: MessageRole
    var text: String
    var date: Date
}

/// What a chat screen renders: committed entries plus the answer still streaming (`pi.live.generation`).
struct ConversationState: Equatable {
    var messages: [ChatMessage]
    /// The partial assistant message while the model streams; replaced by an entry when it finishes.
    var streaming: ChatMessage?
    var busy: Bool
}
