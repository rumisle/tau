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

/// The pure part of the reading position: what advances the frontier, where a chat opens, which turn the status bar
/// goes to. ChatControllerNode measures the rows and applies the answers.
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

    /// How a chat opens after its saved view is put back.
    enum Opening: Equatable {
        /// As left: what follows the view is seen, or there is nothing after the frontier.
        case asLeft
        /// What follows is unseen: down so the frontier's point is near the top, a line or two of context above it.
        case reveal
    }

    /// Whether a chat opens as left or moves down to unseen content: the frontier's point `frontierY`, in points up
    /// from the visible area's bottom edge (the list is inverted; negative is below the screen, nil when its row is not
    /// laid out), and whether anything comes after it.
    static func opening(frontierY: CGFloat?, frontierIsNewerThanView: Bool, hasUnseenAfter: Bool, tolerance: CGFloat = 8.0) -> Opening {
        guard hasUnseenAfter else {
            return .asLeft
        }
        if let frontierY {
            // Below the screen: the user had read further down than they left the view.
            return frontierY < -tolerance ? .asLeft : .reveal
        }
        // Not laid out: below the view (read further), or above it (everything on screen is past it).
        return frontierIsNewerThanView ? .asLeft : .reveal
    }

    /// The offset of the frontier row's bottom above the visible area's bottom (ListView's `.top(offset)` in the inverted
    /// list) that puts its seen point `context` points under the visible area's top.
    static func revealOffset(visibleHeight: CGFloat, rowHeight: CGFloat, depth: CGFloat, context: CGFloat) -> CGFloat {
        return (visibleHeight - context) - (rowHeight - min(depth, rowHeight))
    }

    /// A row as the status bar's turn navigation sees it: its place in the transcript, whether a turn starts at it (the
    /// user's message), and the distance of its top below the visible area's top (negative: above it).
    struct TurnRow: Equatable {
        var order: Int
        var startsTurn: Bool
        var topBelowScreenTop: CGFloat?
    }

    /// The turn start the status bar goes to: the start of the turn above the one at the top of the screen. `topOrder` is
    /// the place of the row at the top of the screen; `rows` are the transcript's, in any order. Nil: no turn above (the
    /// top of the chat).
    static func previousTurnStart(rows: [TurnRow], topOrder: Int, tolerance: CGFloat = 4.0) -> Int? {
        let starts = rows.filter { $0.startsTurn && $0.order <= topOrder }.sorted { $0.order > $1.order }
        for start in starts {
            // A turn already at the top of the screen (the last jump's) is where the user is: the one before it.
            if start.order == topOrder, let top = start.topBelowScreenTop, top >= -tolerance {
                continue
            }
            return start.order
        }
        return nil
    }
}
