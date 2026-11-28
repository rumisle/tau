import XCTest

/// The streaming reveal's pacing (Telegram's TextRevealController, as tau patches it; docs/streaming.md).
final class TextRevealTests: XCTestCase {
    /// Ticks at 60 frames a second from `from` to `to`; the largest step a frame made.
    @discardableResult
    private func run(_ controller: TextRevealController, from: Double, to: Double) -> Int {
        var largest = 0
        var now = from
        var shown = controller.currentGlyphCount
        while now < to {
            now += 1.0 / 60.0
            let count = controller.tick(now: now).revealedGlyphCount
            largest = max(largest, count - shown)
            shown = count
        }
        return largest
    }

    func testFirstParagraphShowsWithinAMoment() {
        let controller = TextRevealController(initialRevealedCount: 0, initialLength: 0)
        controller.observeUpdate(latestLength: 430, at: 0.0)
        self.run(controller, from: 0.0, to: 1.5)
        XCTAssertEqual(controller.currentGlyphCount, 430)
    }

    /// Claude's summarized thinking: a paragraph at once, seconds apart.
    func testParagraphsSecondsApartShowWithinAMoment() {
        let controller = TextRevealController(initialRevealedCount: 0, initialLength: 0)
        var length = 0
        for index in 0 ..< 5 {
            let at = Double(index) * 6.0
            length += 300
            controller.observeUpdate(latestLength: length, at: at)
            self.run(controller, from: at, to: at + 1.5)
            XCTAssertEqual(controller.currentGlyphCount, length, "paragraph \(index + 1)")
            self.run(controller, from: at + 1.5, to: at + 6.0)
        }
    }

    /// Tokens tens of milliseconds apart still come in smoothly, a character or two a frame, close behind.
    func testTokensStaySmooth() {
        let controller = TextRevealController(initialRevealedCount: 0, initialLength: 0)
        var length = 0
        var largest = 0
        var lag = 0
        for index in 0 ..< 200 {
            let at = Double(index) * 0.05
            length += 4
            controller.observeUpdate(latestLength: length, at: at)
            largest = max(largest, self.run(controller, from: at, to: at + 0.05))
            if index > 20 {
                lag = max(lag, length - controller.currentGlyphCount)
            }
        }
        XCTAssertLessThanOrEqual(largest, 3)
        XCTAssertLessThan(lag, 20)
    }
}
