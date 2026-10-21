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

    /// A long press on the user's message with this text, wherever the transcript put it.
    private func pressMessage(_ text: String) {
        let bubble = self.app.descendants(matching: .any).matching(identifier: "userMessage").matching(NSPredicate(format: "label == %@", text)).firstMatch
        _ = bubble.waitForExistence(timeout: 5.0)
        // The row spans the screen; the bubble is at its right.
        bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(forDuration: 1.0)
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
        if action == "stop" {
            // A test that fails while the server is down must not leave it down for the next.
            self.addTeardownBlock { [weak self] in
                self?.server("start")
            }
        }
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
        // With the keyboard up in the chat.
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.focusInput()
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-keyboard")
        self.launch(["-newChat", "YES"])
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-newchat")
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("tab bar")
        self.send()
        sleep(4)
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-newchat-sent")
        // After the title menu.
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.point(0.5, 0.9).tap()
        sleep(1)
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-menu")
        // After the rename alert.
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Rename"].firstMatch.tap()
        sleep(1)
        self.app.buttons["Cancel"].firstMatch.tap()
        sleep(1)
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-alert")
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

    /// The connection's state in the chat's subtitle, as Telegram's: "connecting...", "updating...", then back.
    func testConnectionTitle() {
        self.launch([])
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.server("stop")
        sleep(3)
        self.shot("conn-0-connecting")
        self.server("start")
        sleep(5)
        self.shot("conn-1-online")
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.server("stop")
        sleep(3)
        self.shot("conn-2-list")
        self.server("start")
        sleep(5)
    }

    /// Picking a model from the title menu changes the chat's model: the pill and the picker's checkmark follow.
    func testPickModel() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("hello")
        self.send()
        sleep(4)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Model"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.176).tap()
        self.app.typeText("haiku 4.5")
        sleep(1)
        self.shot("pick-0-search")
        self.point(0.5, 0.25).tap()
        sleep(3)
        self.shot("pick-1-chosen")
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.shot("pick-2-menu")
        self.app.descendants(matching: .any)["Model"].firstMatch.tap()
        sleep(2)
        self.shot("pick-3-picker")
    }

    private func pickModel(_ query: String) {
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Model"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.176).tap()
        self.app.typeText(query)
        sleep(1)
        self.point(0.5, 0.25).tap()
    }

    /// A model picked in a new chat before its first message is the one the chat is created with.
    func testDraftModel() {
        self.launch(["-newChat", "YES"])
        sleep(1)
        self.pickModel("haiku 4.5")
        usleep(600_000)
        self.shot("draft-0-toast")
        sleep(2)
        self.shot("draft-1-pill")
        self.focusInput()
        self.type("hi")
        self.send()
        sleep(6)
        self.shot("draft-2-sent")
    }

    /// The default model is for new chats: an existing chat keeps its own.
    func testDefaultModelKeepsChats() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("on echo")
        self.send()
        sleep(4)
        self.launch(["-tab", "1"])
        sleep(1)
        self.app.descendants(matching: .any)["Servers"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.28).tap()
        sleep(2)
        self.app.descendants(matching: .any)["Default Model"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.176).tap()
        self.app.typeText("haiku 4.5")
        sleep(1)
        self.point(0.5, 0.25).tap()
        sleep(2)
        self.shot("default-0-settings")
        self.launch([])
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.shot("default-1-existing")
        self.launch(["-newChat", "YES"])
        sleep(2)
        self.shot("default-2-new")
        // Back to the echo model, which the other tests expect.
        self.launch(["-tab", "1"])
        sleep(1)
        self.app.descendants(matching: .any)["Servers"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.28).tap()
        sleep(2)
        self.app.descendants(matching: .any)["Default Model"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.176).tap()
        self.app.typeText("echo")
        sleep(1)
        self.point(0.5, 0.25).tap()
        sleep(2)
    }

    /// What is written and not sent survives the app being killed, with an edit in progress beside it, as Telegram
    /// keeps a chat's input state; the list shows Telegram's "Draft:".
    func testDraftsSurviveRestart() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("first")
        self.send()
        sleep(4)
        self.type("half written")
        sleep(1)
        self.launch([])
        self.shot("drafts-0-list")
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.shot("drafts-1-restored")
        // Edit the sent message, then kill the app mid-edit.
        self.pressMessage("first")
        sleep(1)
        self.shot("drafts-2-menu")
        self.app.descendants(matching: .any)["Edit"].firstMatch.tap()
        sleep(1)
        self.type(" edited")
        sleep(1)
        self.shot("drafts-3-editing")
        self.launch([])
        self.point(0.5, 0.17).tap()
        sleep(3)
        self.shot("drafts-4-edit-restored")
        // Cancelling the edit brings back what was being written.
        let field = self.app.textViews.firstMatch.frame
        self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.0)).withOffset(CGVector(dx: field.maxX - 20.0, dy: field.minY - 26.0)).tap()
        sleep(1)
        self.shot("drafts-5-cancelled")
    }

    /// An edit made offline is kept like a message: the chat shows its fork with the clock, and it goes out once the
    /// server is back.
    func testEditOffline() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("one")
        self.send()
        sleep(4)
        self.type("two")
        self.send()
        sleep(4)
        self.server("stop")
        self.launch([])
        self.point(0.5, 0.17).tap()
        sleep(2)
        self.shot("editoff-0")
        // The second message.
        self.pressMessage("two")
        sleep(1)
        self.shot("editoff-1-menu")
        self.app.descendants(matching: .any)["Edit"].firstMatch.tap()
        sleep(1)
        self.type(" b")
        self.send()
        sleep(2)
        self.shot("editoff-2-fork-offline")
        self.server("start")
        sleep(14)
        self.shot("editoff-3-online")
    }

    /// Rename from the title menu: Telegram's alert, the title changes at once, the toast offers Undo; the list follows.
    func testRename() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("name me")
        self.send()
        sleep(4)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.shot("rename-0-menu")
        self.app.descendants(matching: .any)["Rename"].firstMatch.tap()
        sleep(1)
        self.shot("rename-1-alert")
        self.app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "Release notes")
        sleep(1)
        self.shot("rename-2-typed")
        self.app.buttons["Done"].firstMatch.tap()
        usleep(700_000)
        self.shot("rename-3-renamed")
        sleep(3)
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("rename-4-list")
    }

    /// Two servers: one list, Telegram's proxy-style server list, a server's page, and a new chat's card.
    func testMultiServer() {
        self.launch(["-server2.url", "ws://remote.example.ts.net:7878"])
        sleep(4)
        self.shot("multi-0-list")
        self.point(0.75, 0.96).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Servers"].firstMatch.tap()
        sleep(3)
        self.shot("multi-1-servers")
        self.point(0.5, 0.28).tap()
        sleep(2)
        self.shot("multi-2-server")
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Add Server"].firstMatch.tap()
        sleep(2)
        self.shot("multi-3-add")
        self.point(0.32, 0.49).tap()
        sleep(1)
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.point(0.25, 0.96).tap()
        sleep(1)
        // New Chat: straight into the chat, its card in the middle.
        self.point(0.9, 0.098).tap()
        sleep(2)
        self.shot("multi-4-newchat")
        self.point(0.5, 0.3).tap()
        sleep(2)
        self.shot("multi-5-projects")
        self.point(0.12, 0.11).tap()
        sleep(1)
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.point(0.9, 0.098).press(forDuration: 0.8)
        sleep(1)
        self.shot("multi-6-compose-menu")
    }

    /// A background subagent: the chat is free at once, its card and the title say it works, and its answer arrives
    /// as its card.
    func testBackgroundSubagent() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("& reader fork thinking=high: $ sleep 10 && echo found the **bug**")
        self.send()
        sleep(4)
        self.shot("sub-0-working")
        // The title menu lists it, with what it does and for how long.
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Subagents"].firstMatch.tap()
        sleep(2)
        self.shot("sub-0b-menu")
        self.point(0.5, 0.97).tap()
        sleep(1)
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("sub-1-list")
        sleep(10)
        self.point(0.5, 0.17).tap()
        sleep(3)
        self.shot("sub-2-answered")
    }

    /// An answer in a chat that is not on screen: Telegram's banner; and Settings > Notifications.
    func testInAppNotification() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("$ sleep 5 && echo ready")
        self.send()
        sleep(1)
        self.point(0.1, 0.08).tap()
        sleep(6)
        self.shot("notify-0-banner")
        sleep(5)
        self.point(0.75, 0.96).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Notifications"].firstMatch.tap()
        sleep(2)
        self.shot("notify-1-settings")
        self.point(0.88, 0.426).tap()
        sleep(2)
        self.shot("notify-2-push-on")
        self.point(0.88, 0.426).tap()
        sleep(1)
    }

    /// Settings > Data and Storage, its storage and network screens, and clearing the cache.
    func testDataAndStorage() {
        self.launch(["-tab", "1"])
        sleep(2)
        self.app.descendants(matching: .any)["Data and Storage"].firstMatch.tap()
        sleep(1)
        self.shot("data-0")
        self.app.descendants(matching: .any)["Storage Usage"].firstMatch.tap()
        sleep(1)
        self.shot("data-1-storage")
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Network Usage"].firstMatch.tap()
        sleep(1)
        self.shot("data-2-network")
    }

    /// The τ while the agent has written nothing yet, then the answer with when it came and how long it took.
    func testWaitingAndFooter() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("~3 hello **there**")
        self.send()
        sleep(1)
        self.shot("wait-0")
        sleep(1)
        self.shot("wait-1")
        sleep(6)
        self.shot("wait-2-answer")
    }

    /// A new chat moved to another server's folder stays the same screen, with what was written; back is the list.
    func testNewChatNavigation() {
        self.launch(["-server2.url", "ws://remote.example.ts.net:7878"])
        sleep(4)
        self.point(0.9, 0.098).tap()
        sleep(2)
        self.focusInput()
        self.type("carry me")
        sleep(1)
        self.shot("nav-0-keyboard")
        self.app.descendants(matching: .any)["newChatProject"].firstMatch.tap()
        sleep(2)
        self.shot("nav-1-picker")
        // The other server's Browse row (the chat starts on the most recent project, remote here), then its home.
        self.app.descendants(matching: .any)["my-mac"].firstMatch.tap()
        sleep(3)
        self.shot("nav-2-browse")
        self.app.descendants(matching: .any)["Use This Folder"].firstMatch.tap()
        sleep(2)
        self.shot("nav-3-moved")
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("nav-4-back")
        // The list, not the chat it started as.
        XCTAssertFalse(self.app.descendants(matching: .any)["newChatProject"].firstMatch.exists)
    }

    /// Compaction from the title menu: its pill with the τ and its time, messages go on meanwhile, then the summary's
    /// card, which unfolds, and Restore Full Context.
    func testCompaction() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        for text in ["one two three four five six seven", "eight nine ten eleven twelve", "thirteen fourteen fifteen"] {
            self.type(text)
            self.send()
            sleep(3)
        }
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Compact Context"].firstMatch.tap()
        usleep(1_500_000)
        self.shot("compact-0-pill")
        self.focusInput()
        self.type("while compacting")
        self.send()
        usleep(1_000_000)
        self.shot("compact-1-during")
        sleep(5)
        self.shot("compact-2-card")
        let card = self.app.descendants(matching: .any).matching(identifier: "compactionCard").firstMatch
        _ = card.waitForExistence(timeout: 5.0)
        card.tap()
        sleep(1)
        self.shot("compact-3-expanded")
        card.press(forDuration: 1.0)
        sleep(1)
        self.shot("compact-4-menu")
        self.app.descendants(matching: .any)["Restore Full Context"].firstMatch.tap()
        sleep(2)
        self.shot("compact-5-restored")
    }

    /// A tool past a second ticks its time; once done it keeps how long it took. The title counts the run.
    func testToolTimer() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("$ sleep 4 && echo done")
        self.send()
        sleep(3)
        self.shot("timer-0-running")
        sleep(4)
        self.shot("timer-1-done")
    }
}
