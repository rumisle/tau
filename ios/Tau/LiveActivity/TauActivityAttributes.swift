import Foundation
import ActivityKit

/// tau's Live Activity (docs/live-activity.md): the chats of one server the user is waiting on. Shared by the app,
/// which starts and updates it, the server, which updates it while tau is away (and starts one for a notification's
/// reply), and the widget extension, which draws it.
struct TauActivityAttributes: ActivityAttributes {
    /// The server whose chats it shows (`hello.serverId`): the one that pushes its updates.
    var serverId: String = ""

    struct Chat: Codable, Hashable {
        enum State: String, Codable, Hashable {
            case working
            case done
            case failed
        }

        /// The chat's global ID, for the link that opens it.
        var id: Int
        /// Its server's ID (`hello.serverId`) and its ID there, for the link.
        var serverId: String
        var localId: Int
        var title: String
        var state: State
        /// When its run began.
        var since: Date
        var finishedAt: Date?
        /// Whole minutes since `since` as of this update: the activity's views cannot count them themselves without
        /// showing seconds, so the app (later the server) updates them each minute.
        var minutes: Int = 0
        /// While working: the step, in a few words. Done: the answer's first line. Failed: the error.
        var detail: String?
    }

    struct ContentState: Codable, Hashable {
        /// The newest first, three at most.
        var chats: [Chat]
        /// Beyond those.
        var more: Int
        /// The app's accent color as 0xRRGGBB (Settings > Appearance); absent from an older app, which means tau's.
        var accent: UInt32?
    }
}

extension TauActivityAttributes.Chat {
    /// The chat's link (TauLink), as notifications open a chat.
    var url: URL? {
        return URL(string: "tau://\(self.serverId.prefix(8).lowercased())/\(self.localId)")
    }
}
