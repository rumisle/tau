import Foundation
import ActivityKit

/// tau's one Live Activity (docs/live-activity.md): the chats the user is waiting on. Shared by the app, which starts
/// and updates it, and the widget extension, which draws it.
struct TauActivityAttributes: ActivityAttributes {
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
    /// tau://chat?server=&id=, as notifications open a chat.
    var url: URL? {
        return URL(string: "tau://chat?server=\(self.serverId)&id=\(self.localId)")
    }
}
