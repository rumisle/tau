import XCTest

/// The reading position's pure logic (Tau/Chat/ReadingPosition.swift, docs/reading-position.md).
final class ReadingPositionTests: XCTestCase {
    private func span(_ id: Int, _ order: Int, _ depth: CGFloat) -> VisibleRowSpan {
        return VisibleRowSpan(messageId: id, order: order, depth: depth)
    }

    func testFrontierStartsAtTheNewestRowOnScreen() {
        let frontier = ReadingPosition.advanced(nil, frontierOrder: nil, visible: [span(1, 10, 80), span(2, 11, 40)])
        XCTAssertEqual(frontier, SeenFrontier(messageId: 2, depth: 40))
    }

    func testFrontierMovesToANewerRow() {
        let frontier = ReadingPosition.advanced(SeenFrontier(messageId: 1, depth: 80), frontierOrder: 10, visible: [span(2, 11, 20)])
        XCTAssertEqual(frontier, SeenFrontier(messageId: 2, depth: 20))
    }

    func testFrontierGoesFurtherDownItsRow() {
        let frontier = ReadingPosition.advanced(SeenFrontier(messageId: 2, depth: 20), frontierOrder: 11, visible: [span(1, 10, 80), span(2, 11, 300)])
        XCTAssertEqual(frontier, SeenFrontier(messageId: 2, depth: 300))
    }

    func testFrontierNeverGoesBack() {
        let seen = SeenFrontier(messageId: 2, depth: 300)
        // Scrolled back up its row, and to older rows.
        XCTAssertEqual(ReadingPosition.advanced(seen, frontierOrder: 11, visible: [span(2, 11, 120)]), seen)
        XCTAssertEqual(ReadingPosition.advanced(seen, frontierOrder: 11, visible: [span(1, 10, 80)]), seen)
        // Nothing on screen.
        XCTAssertEqual(ReadingPosition.advanced(seen, frontierOrder: 11, visible: []), seen)
    }

    func testFrontierNotInTheTranscriptGivesWayToWhatIsOnScreen() {
        let frontier = ReadingPosition.advanced(SeenFrontier(messageId: 99, depth: 10), frontierOrder: nil, visible: [span(1, 3, 50)])
        XCTAssertEqual(frontier, SeenFrontier(messageId: 1, depth: 50))
    }

    // MARK: - Where a chat opens

    func testOpensAsLeftWithNothingAfterTheFrontier() {
        XCTAssertEqual(ReadingPosition.opening(frontierY: 0.0, frontierIsNewerThanView: false, hasUnseenAfter: false), .asLeft)
    }

    func testRevealsWhatFollowsAFrontierAtTheViewsBottom() {
        // Left at the end: the frontier is the view's bottom, and more came.
        XCTAssertEqual(ReadingPosition.opening(frontierY: 0.5, frontierIsNewerThanView: false, hasUnseenAfter: true), .reveal)
        // Left in the middle of a growing answer: the frontier is inside the view put back.
        XCTAssertEqual(ReadingPosition.opening(frontierY: 300.0, frontierIsNewerThanView: false, hasUnseenAfter: true), .reveal)
    }

    func testOpensAsLeftWhenScrolledBack() {
        // The frontier below the screen: what follows the view was read.
        XCTAssertEqual(ReadingPosition.opening(frontierY: -400.0, frontierIsNewerThanView: true, hasUnseenAfter: true), .asLeft)
        // Not laid out, newer than the view.
        XCTAssertEqual(ReadingPosition.opening(frontierY: nil, frontierIsNewerThanView: true, hasUnseenAfter: true), .asLeft)
        // Not laid out, older than the view: everything on screen is past it.
        XCTAssertEqual(ReadingPosition.opening(frontierY: nil, frontierIsNewerThanView: false, hasUnseenAfter: true), .reveal)
    }

    func testRevealOffsetPutsTheSeenPointUnderTheTop() {
        // A 2000 pt row seen 500 pt down, in 700 pt of screen with 50 pt of context: its bottom goes 1500 - 650 = 850
        // below the visible bottom, so the point is 650 above it.
        let offset = ReadingPosition.revealOffset(visibleHeight: 700.0, rowHeight: 2000.0, depth: 500.0, context: 50.0)
        XCTAssertEqual(offset, -850.0)
        XCTAssertEqual(offset + (2000.0 - 500.0), 650.0)
        // A short row seen whole: its bottom 650 above.
        XCTAssertEqual(ReadingPosition.revealOffset(visibleHeight: 700.0, rowHeight: 40.0, depth: 40.0, context: 50.0), 650.0)
    }
}
