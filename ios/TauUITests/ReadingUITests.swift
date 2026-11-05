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
}
