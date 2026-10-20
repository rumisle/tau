import XCTest

/// The sending state machine (docs/sending.md) against the dev server: `ios/scripts/devserver.sh start` runs the
/// dev/echo model on port 7979, whose `$ <command>` messages run bash, so `$ sleep N` keeps the agent working for N
/// seconds. `ios/scripts/sending-tests.sh [test ...]` runs these and stops and starts the server when a test asks;
/// screenshots go to /tmp/tau-ui.
final class SendingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: "/tmp/tau-ui", withIntermediateDirectories: true)
    }

    private func launch(_ arguments: [String]) {
        self.app = XCUIApplication()
        self.app.launchArguments = ["-server.url", "ws://127.0.0.1:7979", "-wrapCode", "YES", "-theme", "dark"] + arguments
        self.app.launch()
        sleep(2)
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/tau-ui/\(name).png"))
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        return self.app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func type(_ text: String) {
        self.app.typeText(text)
    }

    private func send() {
        self.app.buttons["send"].firstMatch.tap()
    }

    private func focusInput() {
        self.point(0.5, 0.955).tap()
        sleep(1)
    }

    /// A new chat with the agent working for `seconds`.
    private func startWorking(_ seconds: Int) {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("$ sleep \(seconds)")
        self.send()
        sleep(2)
    }

    /// The accessory panel sits above the text view inside the field's glass; XCUITest misplaces the labels in there,
    /// so taps go by the text view's frame.
    private func tapAccessory() {
        let field = self.app.textViews.firstMatch.frame
        self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0)).withOffset(CGVector(dx: field.minX + 60.0, dy: field.minY - 26.0)).tap()
    }

    private func tapAccessoryClose() {
        let field = self.app.textViews.firstMatch.frame
        self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0)).withOffset(CGVector(dx: field.maxX - 22.0, dy: field.minY - 26.0)).tap()
    }

    /// Ask ios/scripts/sending-tests.sh to stop, start or wipe the dev server, and wait until it has.
    private func server(_ action: String) {
        let done = "/tmp/tau-ui/server-\(action)ed"
        try? FileManager.default.removeItem(atPath: done)
        FileManager.default.createFile(atPath: "/tmp/tau-ui/server-\(action)", contents: nil)
        for _ in 0 ..< 60 where !FileManager.default.fileExists(atPath: done) {
            usleep(250_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "the runner did not \(action) the server")
    }

    private var accessoryText: String {
        return self.app.staticTexts["accessoryText"].firstMatch.label
    }

    /// Steer while the agent works: the panel shows it with a check; it lands after the tool, and the answer follows.
    func testSteerLifecycle() {
        self.startWorking(6)
        self.shot("steer-0-running")
        self.type("first steer")
        self.send()
        usleep(800_000)
        self.shot("steer-1-queued")
        XCTAssertEqual(self.app.staticTexts["accessoryTitle"].firstMatch.label, "Steer")
        XCTAssertEqual(self.accessoryText, "first steer")
        sleep(9)
        self.shot("steer-2-delivered")
    }

    /// Long press Send: Send as Follow-up; two queued messages split the panel's line; the menu lists both.
    func testFollowUpAndQueueMenu() {
        self.startWorking(20)
        self.type("steer it")
        self.send()
        usleep(500_000)
        self.type("after that")
        self.app.buttons["send"].firstMatch.press(forDuration: 0.6)
        usleep(700_000)
        self.shot("follow-0-send-menu")
        self.app.descendants(matching: .any)["Send as Follow-up"].firstMatch.tap()
        usleep(800_000)
        self.shot("follow-1-two-queued")
        self.tapAccessory()
        usleep(800_000)
        self.shot("follow-2-queue-menu")
        // The second one's actions.
        self.app.descendants(matching: .any)["after that"].firstMatch.tap()
        usleep(700_000)
        self.shot("follow-3-actions")
        self.point(0.5, 0.2).tap()
        sleep(26)
        self.shot("follow-4-done")
    }

    /// The panel's close button withdraws the message: it never reaches the agent.
    func testWithdraw() {
        self.startWorking(14)
        self.type("never mind")
        self.send()
        usleep(800_000)
        self.tapAccessoryClose()
        usleep(600_000)
        self.shot("withdraw-0-closed")
        sleep(14)
        self.shot("withdraw-1-after-run")
    }

    /// Stop: the run ends and the queued messages come back to the field, in order.
    func testStopRestoresQueue() {
        self.startWorking(20)
        self.type("one")
        self.send()
        usleep(400_000)
        self.type("two")
        self.send()
        usleep(800_000)
        self.shot("stop-0-queued")
        self.app.buttons["stop"].firstMatch.tap()
        sleep(2)
        self.shot("stop-1-restored")
        let field = self.app.textViews.firstMatch.value as? String ?? ""
        XCTAssertEqual(field, "one\n\ntwo")
    }

    /// Send Now on a queued message: the run stops and the message goes at once; the other returns to the field.
    func testSendNow() {
        self.startWorking(20)
        self.type("later one")
        self.send()
        usleep(400_000)
        self.type("urgent")
        self.send()
        usleep(800_000)
        self.tapAccessory()
        usleep(800_000)
        self.app.descendants(matching: .any)["urgent"].firstMatch.tap()
        usleep(700_000)
        self.app.descendants(matching: .any)["Send Now"].firstMatch.tap()
        sleep(5)
        self.shot("sendnow-0")
        let field = self.app.textViews.firstMatch.value as? String ?? ""
        XCTAssertEqual(field, "later one")
    }

    /// Edit takes a queued message back into the field.
    func testEditQueued() {
        self.startWorking(20)
        self.type("fix the typo")
        self.send()
        usleep(800_000)
        self.tapAccessory()
        usleep(800_000)
        self.shot("edit-0-menu")
        self.app.descendants(matching: .any)["Edit"].firstMatch.tap()
        usleep(800_000)
        self.shot("edit-1-back")
        let field = self.app.textViews.firstMatch.value as? String ?? ""
        XCTAssertEqual(field, "fix the typo")
    }

    /// Idle: a message shows at once with the clock, then two checks.
    func testIdleSend() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("hello")
        self.send()
        usleep(150_000)
        self.shot("idle-0-sending")
        sleep(4)
        self.shot("idle-1-answered")
    }

    /// Offline: the clock stays and nothing fails; back online, the message goes, in order after the one before it.
    func testOfflineThenOnline() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("before")
        self.send()
        sleep(5)
        self.server("stop")
        sleep(1)
        self.type("while offline")
        self.send()
        usleep(500_000)
        self.type("and another")
        self.send()
        sleep(4)
        self.shot("offline-0-clock")
        // The list shows the message on its way, with the clock.
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.shot("offline-1-list")
        self.server("start")
        sleep(8)
        self.shot("offline-2-list-delivered")
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.shot("offline-3-delivered")
    }

    /// The app killed with a message on its way: relaunched, the message is still there and goes.
    func testKilledWhileOffline() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("first")
        self.send()
        sleep(5)
        self.server("stop")
        sleep(1)
        self.type("survives a kill")
        self.send()
        sleep(2)
        self.shot("kill-0-clock")
        self.app.terminate()
        self.server("start")
        self.app = XCUIApplication()
        self.app.launchArguments = ["-server.url", "ws://127.0.0.1:7979", "-theme", "dark"]
        self.app.launch()
        sleep(3)
        self.shot("kill-1-list")
        // The newest chat is first.
        self.point(0.5, 0.17).tap()
        sleep(5)
        self.shot("kill-2-delivered")
    }

    /// The server lost the conversation (a fresh database): the message is refused for good and turns red; Delete
    /// drops it.
    func testRefused() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("first")
        self.send()
        sleep(5)
        self.server("wipe")
        sleep(3)
        self.type("into the void")
        self.send()
        sleep(4)
        self.shot("refused-0-red")
        let field = self.app.textViews.firstMatch.frame
        // The red badge sits at the bubble's bottom right, 24 pt in from the edge.
        self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0)).withOffset(CGVector(dx: self.app.windows.firstMatch.frame.width - 14.0, dy: field.minY - 20.0)).tap()
        usleep(900_000)
        self.shot("refused-1-menu")
    }

    /// Back from a chat to the list: the tab bar comes back whole.
    func testTabBarAfterChat() {
        self.launch([])
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-chat")
        self.launch(["-openChat", "1"])
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-openchat")
    }

    /// Send as Steer on a follow-up: it is queued again as a steer, and the panel says so.
    func testMoveToSteer() {
        self.startWorking(20)
        self.type("later")
        self.app.buttons["send"].firstMatch.press(forDuration: 0.6)
        usleep(700_000)
        self.app.descendants(matching: .any)["Send as Follow-up"].firstMatch.tap()
        usleep(900_000)
        self.shot("move-0-follow-up")
        self.tapAccessory()
        usleep(800_000)
        self.app.descendants(matching: .any)["Send as Steer"].firstMatch.tap()
        usleep(1_200_000)
        self.shot("move-1-steer")
    }

    /// Offline, a message with the clock can be deleted; back online, nothing of it arrives.
    func testDeleteWhileOffline() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("first")
        self.send()
        sleep(5)
        self.server("stop")
        sleep(1)
        self.type("drop me")
        self.send()
        sleep(2)
        self.shot("delete-0-clock")
        let field = self.app.textViews.firstMatch.frame
        self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0)).withOffset(CGVector(dx: self.app.windows.firstMatch.frame.width - 60.0, dy: field.minY - 30.0)).press(forDuration: 0.8)
        usleep(900_000)
        self.shot("delete-1-menu")
        self.app.descendants(matching: .any)["Delete"].firstMatch.tap()
        usleep(800_000)
        self.shot("delete-2-gone")
        self.server("start")
        sleep(6)
        self.shot("delete-3-online")
    }
}
