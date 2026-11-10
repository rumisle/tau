import XCTest

/// The reading position (docs/reading-position.md): what counts as seen, where a chat opens, the status bar's turns and
/// the down button's return points. Chats are made on the dev server from the test runner (DevServerClient), their
/// answers written beforehand (the dev model's /tmp/tau-dev-answers.json) so they are long, and read in the app.
final class ReadingUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: DevServerClient!
    private var made: [Int] = []

    override func setUpWithError() throws {
        self.continueAfterFailure = true
        self.server = try DevServerClient(url: devServer)
        self.addTeardownBlock { [weak self] in
            guard let self else {
                return
            }
            for id in self.made {
                _ = try? self.server.request("conversation.mark", ["conversationId": id, "hidden": true])
            }
        }
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) {
        self.app = XCUIApplication()
        self.app.launchArguments = ["-server.url", devServer, "-wrapCode", "YES", "-uiTesting", "YES", "-theme", "dark"] + arguments
        self.app.launch()
        if arguments.contains("-openChat") {
            self.app.waitForChat()
        }
        settle()
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(uiDirectory)/\(name).png"))
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        return self.app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    /// Answers the dev model gives to these messages, beside those other tests wrote.
    private func script(_ answers: [String: String]) throws {
        let path = "/tmp/tau-dev-answers.json"
        var all = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any]) ?? [:]
        for (question, answer) in answers {
            all[question] = answer
        }
        try JSONSerialization.data(withJSONObject: all).write(to: URL(fileURLWithPath: path))
    }

    /// A long answer: `paragraphs` paragraphs, each naming its turn and its place, so a test sees which one is where.
    private func answer(_ tag: String, paragraphs: Int) -> String {
        return (1 ... paragraphs).map { "\(tag) paragraph \($0): the agent explains this part at some length, so that each paragraph fills a few lines of the screen and the answer runs well past one screen of the phone." }.joined(separator: "\n\n")
    }

    /// A chat on the dev server with these turns, each answered and done.
    private func chat(_ title: String, turns: [(question: String, answer: String)]) throws -> Int {
        try self.script(Dictionary(uniqueKeysWithValues: turns.map { ($0.question, $0.answer) }))
        let id = try self.server.create(title)
        self.made.append(id)
        for turn in turns {
            _ = try self.server.submit(id, turn.question)
            XCTAssertTrue(self.waitIdle(id), "answered: \(turn.question)")
        }
        return id
    }

    /// The server's view of the chat in the list.
    private func dialog(_ id: Int) -> [String: Any]? {
        let dialogs = (try? self.server.request("dialogs.subscribe", [:]))?["dialogs"] as? [[String: Any]] ?? []
        return dialogs.first { (($0["conversation"] as? [String: Any])?["id"] as? Int) == id }
    }

    /// Until the chat's run is over on the server.
    @discardableResult
    private func waitIdle(_ id: Int, timeout: TimeInterval = 60.0) -> Bool {
        usleep(500_000)
        return waitUntil(timeout) { (self.dialog(id)?["busy"] as? Bool) == false }
    }

    /// The chat's reading position as the app reports it (`chatReading`): its "key=value" pairs.
    private var reading: [String: String] {
        guard let snapshot = try? self.app.descendants(matching: .any)["chatReading"].firstMatch.snapshot(), let value = snapshot.value as? String else {
            return [:]
        }
        var result: [String: String] = [:]
        for pair in value.components(separatedBy: "|") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0]] = parts[1]
            }
        }
        return result
    }

    /// The bottom of the navigation bar: what "near the top of the screen" is below.
    private var screenTop: CGFloat {
        return self.app.frame.height * 0.12
    }

    private func back() {
        self.point(0.1, 0.08).tap()
        settle()
    }

    private func open(_ title: String) {
        let row = self.app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'chatTitle' AND label == %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) in the list")
        row.tap()
        self.app.waitForChat()
        settle()
    }

    private func userMessage(_ text: String) -> XCUIElement {
        return self.app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'userMessage' AND label BEGINSWITH %@", text)).firstMatch
    }

    private func type(_ text: String) {
        let field = self.app.textViews.firstMatch
        field.tap()
        field.typeText(text)
    }

    private func send() {
        self.app.descendants(matching: .any)["send"].firstMatch.tap()
    }

    // MARK: - Seen as on screen

    /// Answers that come while the chat is scrolled back, or closed, stay unread; opening it again where it was left
    /// reads nothing new: the list counts the unseen answers only.
    func testUnreadCountsUnseenAnswers() throws {
        let turns = (1 ... 3).map { (question: "Unread question \($0)", answer: self.answer("Unread turn \($0)", paragraphs: 8)) }
        let id = try self.chat("Unread counts", turns: turns)
        try self.script(["Unread later one": "The first answer that came while the chat was scrolled back.", "Unread later two": "The second, while the chat was closed."])
        self.launch(["-openChat", "\(id)"])
        // Back past the last answer, to the second turn.
        for _ in 0 ..< 4 {
            self.app.swipeDown(velocity: .slow)
        }
        settle()
        self.shot("reading-unread-0-scrolled-back")
        _ = try self.server.submit(id, "Unread later one")
        XCTAssertTrue(self.waitIdle(id))
        sleep(1)
        self.shot("reading-unread-1-arrived")
        self.back()
        _ = try self.server.submit(id, "Unread later two")
        XCTAssertTrue(self.waitIdle(id))
        sleep(2)
        XCTAssertEqual(self.dialog(id)?["unreadCount"] as? Int, 2, "the two answers not seen")
        self.open("Unread counts")
        sleep(2)
        self.shot("reading-unread-2-reopened")
        self.back()
        sleep(2)
        XCTAssertEqual(self.dialog(id)?["unreadCount"] as? Int, 2, "still unseen after opening it where it was left")
        self.shot("reading-unread-3-list")
    }

    /// Nothing is seen while the app is away: an answer that streams on while it is in the background stays unread.
    func testNotSeenWhileInactive() throws {
        let id = try self.chat("Inactive", turns: [(question: "Inactive first", answer: "A short first answer.")])
        try self.script(["Inactive long": self.answer("Inactive long", paragraphs: 30)])
        self.launch(["-openChat", "\(id)"])
        self.type("Inactive long")
        self.send()
        XCTAssertTrue(self.app.waitForBusy())
        sleep(2)
        self.shot("reading-inactive-0-streaming")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(self.waitIdle(id, timeout: 120))
        sleep(2)
        XCTAssertEqual(self.dialog(id)?["unreadCount"] as? Int, 1, "the answer finished while away: not seen")
        self.app.activate()
        settle()
        self.shot("reading-inactive-1-back")
    }

    // MARK: - Where a chat opens

    /// The reading state's integer value for `key`.
    private func readingInt(_ key: String) -> Int? {
        return self.reading[key].flatMap { Int($0.components(separatedBy: "/").first ?? $0) }
    }

    /// Near the top of the screen: below the navigation bar, within a few lines of it.
    private func assertNearTop(_ y: CGFloat?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let y else {
            return XCTFail("\(message): not on screen (\(self.reading))", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(y, self.screenTop - 10.0, "\(message): \(self.reading)", file: file, line: line)
        XCTAssertLessThanOrEqual(y, self.screenTop + 150.0, "\(message): \(self.reading)", file: file, line: line)
    }

    /// Left at the end right after sending, a long answer finished meanwhile: the chat opens with the user's message near
    /// the top and the answer below it, not at the end of the answer.
    func testOpenAfterSending() throws {
        let id = try self.chat("After sending", turns: [(question: "After sending first", answer: self.answer("After sending first", paragraphs: 4))])
        // The dev model waits four seconds before it answers (`~4`): the user leaves before the answer starts.
        try self.script(["~4 After sending long": self.answer("After sending long", paragraphs: 30)])
        self.launch(["-openChat", "\(id)"])
        self.type("~4 After sending long")
        self.send()
        XCTAssertTrue(self.userMessage("~4 After sending long").waitForExistence(timeout: 5))
        self.shot("reading-sent-0-sent")
        self.back()
        XCTAssertTrue(self.waitIdle(id, timeout: 120))
        self.open("After sending")
        self.shot("reading-sent-1-reopened")
        let message = self.userMessage("~4 After sending long")
        XCTAssertTrue(message.exists, "the user's message on screen")
        self.assertNearTop(message.exists ? message.frame.minY : nil, "the user's message near the top")
        let first = self.app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'assistantMessage' AND label BEGINSWITH 'After sending long paragraph 1:'")).firstMatch
        XCTAssertTrue(first.exists && first.frame.minY > message.frame.minY, "the answer below it")
    }

    /// Watching an answer stream past a screen, left in the middle, finished meanwhile: the chat opens with the last
    /// lines seen near the top, the rest below; nothing seen fills the screen again.
    func testOpenMidAnswer() throws {
        let id = try self.chat("Mid answer", turns: [(question: "Mid answer first", answer: "A short first answer.")])
        try self.script(["Mid answer long": self.answer("Mid answer long", paragraphs: 60)])
        self.launch(["-openChat", "\(id)"])
        self.type("Mid answer long")
        self.send()
        // Past a screen of it, followed at the end.
        XCTAssertTrue(waitUntil(30) { (self.readingInt("depth") ?? 0) > Int(self.app.frame.height) })
        self.shot("reading-mid-0-streaming")
        let seen = self.reading["frontier"]
        self.back()
        XCTAssertTrue(self.waitIdle(id, timeout: 180))
        self.open("Mid answer")
        self.shot("reading-mid-1-reopened")
        XCTAssertEqual(self.reading["revealed"], seen, "moved down to the frontier it left")
        self.assertNearTop(self.readingInt("revealY").map { CGFloat($0) }, "the last lines seen near the top")
    }

    /// Scrolled back reading older rows, something arrives: the chat opens exactly where it was left, and the down button
    /// counts what came.
    func testOpenScrolledBack() throws {
        let turns = (1 ... 3).map { (question: "Scrolled back question \($0)", answer: self.answer("Scrolled back turn \($0)", paragraphs: 8)) }
        let id = try self.chat("Scrolled back", turns: turns)
        try self.script(["Scrolled back later": "What came while the chat was closed."])
        self.launch(["-openChat", "\(id)"])
        for _ in 0 ..< 3 {
            self.app.swipeDown(velocity: .slow)
        }
        settle()
        let bottom = self.reading["bottom"]
        let offset = self.readingInt("bottomOffset")
        self.shot("reading-back-0-left")
        self.back()
        _ = try self.server.submit(id, "Scrolled back later")
        XCTAssertTrue(self.waitIdle(id))
        self.open("Scrolled back")
        self.shot("reading-back-1-reopened")
        XCTAssertEqual(self.reading["bottom"], bottom, "the same row at the bottom")
        XCTAssertEqual(Double(self.readingInt("bottomOffset") ?? 0), Double(offset ?? 0), accuracy: 3.0, "where it was")
        let down = self.app.descendants(matching: .any)["downButton"].firstMatch
        XCTAssertTrue(down.exists, "the down button")
        XCTAssertEqual(down.value as? String, "2", "counting the message and the answer that came")
    }

    /// Left at the end with nothing new since: as left.
    func testOpenAtEndUnchanged() throws {
        let id = try self.chat("Unchanged", turns: [(question: "Unchanged question", answer: self.answer("Unchanged", paragraphs: 8))])
        self.launch(["-openChat", "\(id)"])
        let bottom = self.reading["bottom"]
        let offset = self.readingInt("bottomOffset")
        self.back()
        self.open("Unchanged")
        self.shot("reading-unchanged-0-reopened")
        XCTAssertEqual(self.reading["bottom"], bottom)
        XCTAssertEqual(Double(self.readingInt("bottomOffset") ?? 0), Double(offset ?? 0), accuracy: 3.0)
        XCTAssertFalse(self.app.descendants(matching: .any)["downButton"].firstMatch.exists, "at the end")
    }

    /// The app in the background while an answer streams at the end, back once it finished: as reopening, the last
    /// lines seen near the top.
    func testBackgroundWhileStreaming() throws {
        let id = try self.chat("Background", turns: [(question: "Background first", answer: "A short first answer.")])
        try self.script(["Background long": self.answer("Background long", paragraphs: 60)])
        self.launch(["-openChat", "\(id)"])
        self.type("Background long")
        self.send()
        XCTAssertTrue(waitUntil(30) { (self.readingInt("depth") ?? 0) > Int(self.app.frame.height) })
        let seen = self.reading["frontier"]
        self.shot("reading-background-0-streaming")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(self.waitIdle(id, timeout: 180))
        self.app.activate()
        XCTAssertTrue(waitUntil(5) { self.reading["revealed"] != nil })
        // The rest of the answer shows as it would have streamed; until it has.
        self.app.waitForIdle(timeout: 120)
        var depth = ""
        _ = waitUntil(60) {
            let now = self.reading["depth"] ?? ""
            defer { depth = now }
            return now == depth
        }
        sleep(1)
        self.shot("reading-background-1-back")
        XCTAssertEqual(self.reading["revealed"], seen)
        self.assertNearTop(self.readingInt("revealY").map { CGFloat($0) }, "the last lines seen near the top")
    }

    /// Back while the answer still streams: what came meanwhile shows in full under the last lines seen, and the rest
    /// streams on below without moving them (a height animation left running from before put the view at the end).
    func testBackWhileStillStreaming() throws {
        let id = try self.chat("Still streaming", turns: [(question: "Still streaming first", answer: "A short first answer.")])
        try self.script(["Still streaming long": self.answer("Still streaming long", paragraphs: 60)])
        self.launch(["-openChat", "\(id)"])
        self.type("Still streaming long")
        self.send()
        XCTAssertTrue(waitUntil(30) { (self.readingInt("depth") ?? 0) > Int(self.app.frame.height) })
        let seen = self.reading["frontier"]
        XCUIDevice.shared.press(.home)
        // Back halfway through the answer.
        sleep(16)
        XCTAssertFalse(self.waitIdle(id, timeout: 0.5), "still streaming")
        self.app.activate()
        XCTAssertTrue(waitUntil(5) { self.reading["revealed"] != nil })
        self.app.waitForIdle(timeout: 120)
        sleep(1)
        self.shot("reading-still-0-back")
        XCTAssertEqual(self.reading["revealed"], seen)
        self.assertNearTop(self.readingInt("revealY").map { CGFloat($0) }, "the last lines seen near the top")
    }

    // MARK: - Turns

    /// A tap on the status bar, as the system takes it: scroll to top.
    private func tapStatusBar() {
        self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)).withOffset(CGVector(dx: 0.0, dy: 12.0)).tap()
        usleep(900_000)
    }

    /// The user's message at the top of the screen: its top just under the navigation bar.
    private func assertAtTop(_ text: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = self.userMessage(text)
        XCTAssertTrue(element.exists, "\(message): \(text) on screen", file: file, line: line)
        if element.exists {
            XCTAssertEqual(Double(element.frame.minY), Double(self.screenTop), accuracy: 40.0, "\(message): \(text) at the top", file: file, line: line)
        }
    }

    /// Turns, each answered past a screen.
    private func turnsChat(_ title: String, count: Int, paragraphs: Int = 14) throws -> Int {
        let turns = (1 ... count).map { (question: "\(title) question \($0)", answer: self.answer("\(title) turn \($0)", paragraphs: paragraphs)) }
        return try self.chat(title, turns: turns)
    }

    /// The status bar goes up turn by turn, the user's message at the top each time; at the first turn, the top of the
    /// chat, which it stays at.
    func testStatusBarTurns() throws {
        let id = try self.turnsChat("Turns", count: 4)
        self.launch(["-openChat", "\(id)"])
        self.shot("reading-turns-0-end")
        for turn in [4, 3, 2, 1] {
            self.tapStatusBar()
            self.shot("reading-turns-\(5 - turn)-turn\(turn)")
            self.assertAtTop("Turns question \(turn)", "tap \(5 - turn)")
        }
        self.tapStatusBar()
        self.assertAtTop("Turns question 1", "at the first turn")
    }

    // MARK: - The return stack

    private var downButton: XCUIElement {
        return self.app.descendants(matching: .any)["downButton"].firstMatch
    }

    /// Until a jump is over (the reading state says so).
    private func waitJump() {
        _ = waitUntil(5) { self.reading["jumping"] == "false" }
        settle()
    }

    /// Up turn by turn, then the down button back point by point to where each jump left from, then the end. The
    /// first jump's point, the end, shows again where it lands (the last answer's start under its question) and goes:
    /// so three jumps up from the end leave two points, and the down button retraces the jumps.
    func testDownButtonReturns() throws {
        let id = try self.turnsChat("Returns", count: 4)
        self.launch(["-openChat", "\(id)"])
        for _ in 0 ..< 3 {
            self.tapStatusBar()
            self.waitJump()
        }
        self.assertAtTop("Returns question 2", "three turns up")
        XCTAssertEqual(self.reading["stack"], "2", "a point for each jump but the first, seen again")
        self.shot("reading-returns-0-up")
        for (turn, left) in [(3, "1"), (4, "0")] {
            self.downButton.tap()
            self.waitJump()
            self.shot("reading-returns-\(5 - turn)-down")
            self.assertAtTop("Returns question \(turn)", "back where the jump left from")
            XCTAssertEqual(self.reading["stack"], left)
        }
        // No point left: to the end.
        self.downButton.tap()
        self.waitJump()
        sleep(1)
        self.shot("reading-returns-3-end")
        XCTAssertEqual(self.reading["bottom"], "Returns turn 4 paragraph")
        XCTAssertFalse(self.downButton.exists, "at the end")
    }

    /// A jump to a turn on the same screen keeps nothing: the down button goes to the end.
    func testJumpWithinScreenKeepsNothing() throws {
        let turns = (1 ... 4).map { (question: "Short question \($0)", answer: "Short answer \($0).") }
        let id = try self.chat("Short turns", turns: turns)
        self.launch(["-openChat", "\(id)"])
        // Scrolled up a little, so the down button shows.
        self.tapStatusBar()
        self.waitJump()
        self.shot("reading-short-0-up")
        XCTAssertEqual(self.reading["stack"], "0", "the turn was on the screen")
        if self.downButton.exists {
            self.downButton.tap()
            self.waitJump()
        }
        self.shot("reading-short-1-down")
        XCTAssertEqual(self.reading["bottom"], "Short answer 4.", "at the end")
    }

    /// Scrolling down by hand past a return point drops it; holding the down button goes to the end past the rest.
    func testScrollingPastAPointDropsIt() throws {
        let id = try self.turnsChat("Dropped", count: 4)
        self.launch(["-openChat", "\(id)"])
        for _ in 0 ..< 3 {
            self.tapStatusBar()
            self.waitJump()
        }
        XCTAssertEqual(self.reading["stack"], "2")
        // Down by hand until the third answer shows: the point of the jump from there goes.
        XCTAssertTrue(waitUntil(60) {
            self.app.swipeUp(velocity: .slow)
            usleep(800_000)
            return self.reading["stack"] == "1"
        }, "the point seen again dropped: \(self.reading)")
        self.shot("reading-dropped-0-scrolled")
        self.downButton.press(forDuration: 0.8)
        self.waitJump()
        sleep(1)
        self.shot("reading-dropped-1-held")
        XCTAssertEqual(self.reading["stack"], "0")
        XCTAssertEqual(self.reading["bottom"], "Dropped turn 4 paragraph", "the end")
        XCTAssertFalse(self.downButton.exists, "at the end")
    }

    /// A chat previewed from the list (held) is not read: its answers stay unread.
    func testPreviewDoesNotMarkSeen() throws {
        let id = try self.chat("Previewed", turns: [(question: "Previewed first", answer: "A first answer.")])
        try self.script(["Previewed later": "An answer that came while the chat was closed."])
        self.launch([])
        _ = try self.server.submit(id, "Previewed later")
        XCTAssertTrue(self.waitIdle(id))
        sleep(2)
        XCTAssertEqual(self.dialog(id)?["unreadCount"] as? Int, 2, "unread before")
        let row = self.app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'chatTitle' AND label == 'Previewed'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.0)
        sleep(3)
        self.shot("reading-preview-0-held")
        XCTAssertEqual(self.dialog(id)?["unreadCount"] as? Int, 2, "still unread with the preview on screen")
    }
}
