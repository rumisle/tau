import CoreGraphics

/// The newest point the user has seen in a chat (docs/reading-position.md): a row, and how far down it, in points from
/// its top, as a long answer may be seen half way. It only moves forward.
struct SeenFrontier: Equatable {
    var messageId: Int
    var depth: CGFloat
}

/// What is on screen of a row, for the frontier: its place in the transcript (larger is newer) and how far down it the
/// visible area reaches, in points from its top.
struct VisibleRowSpan: Equatable {
    var messageId: Int
    var order: Int
    var depth: CGFloat
}

/// The pure part of the reading position: what advances the frontier. ChatControllerNode measures the rows and applies
/// the answers.
enum ReadingPosition {
    /// The frontier once `visible` has been on screen: the newest visible row, as far down as it is seen, if that is past
    /// the frontier; `frontierOrder` is the frontier row's place now, nil when it is not in the transcript (older than
    /// what is loaded, or gone), when any row on screen is past it.
    static func advanced(_ frontier: SeenFrontier?, frontierOrder: Int?, visible: [VisibleRowSpan]) -> SeenFrontier? {
        guard let newest = visible.max(by: { $0.order < $1.order }) else {
            return frontier
        }
        guard let frontier, let frontierOrder else {
            return SeenFrontier(messageId: newest.messageId, depth: newest.depth)
        }
        if newest.order > frontierOrder {
            return SeenFrontier(messageId: newest.messageId, depth: newest.depth)
        }
        if newest.order == frontierOrder, newest.depth > frontier.depth + 0.5 {
            return SeenFrontier(messageId: frontier.messageId, depth: newest.depth)
        }
        return frontier
    }
}
