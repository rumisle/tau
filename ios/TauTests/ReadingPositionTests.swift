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
}
