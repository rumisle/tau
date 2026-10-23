import XCTest

/// The sending state machine (docs/sending.md) against the dev server: `ios/scripts/devserver.sh start` runs the
/// dev/echo model on port 7979, whose `$ <command>` messages run bash, so `$ sleep N` keeps the agent working for N
/// seconds. `ios/scripts/sending-tests.sh [test ...]` runs these and stops and starts the server when a test asks;
/// screenshots go to /tmp/tau-ui.
/// The dev server: TAU_DEV_SERVER, which ios/scripts/uitests.sh gives each simulator its own of.
let devServer = ProcessInfo.processInfo.environment["TAU_DEV_SERVER"] ?? "ws://127.0.0.1:7979"
/// The tokens of this Mac's tau server (port 7878) and remote's, which the test scripts read (`TAU_TOKEN`,
/// `TAU_REMOTE_TOKEN`): as launch arguments, none when unset.
let mainServerToken = ProcessInfo.processInfo.environment["TAU_TOKEN"].flatMap { $0.isEmpty ? nil : ["-server.token", $0] } ?? []
let remoteServer = ["-server2.url", "ws://remote.example.ts.net:7878"] + (ProcessInfo.processInfo.environment["TAU_REMOTE_TOKEN"].flatMap { $0.isEmpty ? nil : ["-server2.token", $0] } ?? [])

final class SendingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: uiDirectory, withIntermediateDirectories: true)
    }

    private func launch(_ arguments: [String], server: String = devServer) {
        self.app = XCUIApplication()
        self.app.launchArguments = ["-server.url", server, "-wrapCode", "YES", "-theme", "dark"] + arguments
        self.app.launch()
        sleep(2)
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(uiDirectory)/\(name).png"))
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
        let done = "\(uiDirectory)/server-\(action)ed"
        try? FileManager.default.removeItem(atPath: done)
        FileManager.default.createFile(atPath: "\(uiDirectory)/server-\(action)", contents: nil)
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
        self.point(0.5, 0.24).tap()
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
        self.app.launchArguments = ["-server.url", devServer, "-theme", "dark"]
        self.app.launch()
        sleep(3)
        self.shot("kill-1-list")
        // The newest chat is first.
        self.point(0.5, 0.24).tap()
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
        self.point(0.5, 0.24).tap()
        sleep(2)
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-chat")
        self.launch(["-openChat", "1"])
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-openchat")
        // With the keyboard up in the chat.
        self.point(0.5, 0.24).tap()
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
        self.point(0.5, 0.24).tap()
        sleep(2)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.point(0.5, 0.9).tap()
        sleep(1)
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("tabbar-after-menu")
        // After the rename alert.
        self.point(0.5, 0.24).tap()
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
        self.point(0.5, 0.24).tap()
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
        self.point(0.5, 0.24).tap()
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
        self.point(0.5, 0.24).tap()
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
        self.point(0.5, 0.24).tap()
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
        self.point(0.5, 0.24).tap()
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

    /// A server that turns the token away: its row says so, in red, while the other server works.
    func testRefusedToken() {
        self.launch(["-server2.url", "ws://127.0.0.1:7878", "-server2.token", "wrong-token-wrong-token"])
        sleep(6)
        self.point(0.75, 0.96).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Servers"].firstMatch.tap()
        XCTAssertTrue(self.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Token refused", "Token refused")).firstMatch.waitForExistence(timeout: 10))
        self.shot("refused")
    }

    /// Two servers: one list, Telegram's proxy-style server list, a server's page, and a new chat's card.
    func testMultiServer() {
        self.launch(remoteServer)
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
        self.point(0.5, 0.24).tap()
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

    /// Settings > Data and Storage > Storage Usage > Clear Cache: the transcripts leave the phone.
    private func clearCache() {
        self.launch(["-tab", "1"])
        self.app.descendants(matching: .any)["Data and Storage"].firstMatch.tap()
        sleep(1)
        self.app.descendants(matching: .any)["Storage Usage"].firstMatch.tap()
        sleep(1)
        self.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Clear Cache'")).firstMatch.tap()
        sleep(1)
        // The sheet's button, by where it is: XCUITest finds the sheet's buttons not hittable.
        self.app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Clear ' AND NOT (label BEGINSWITH 'Clear Cache')")).firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
    }

    private func userMessage(_ text: String) -> XCUIElement {
        return self.app.descendants(matching: .any).matching(identifier: "userMessage").matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// A chat never waits for the network to open: the top of the list is preloaded, so one not opened since its
    /// transcript left the phone shows with the server gone; with nothing on the phone it opens with Telegram's spinner,
    /// and the transcript takes its place when the server is back.
    func testOpenWithoutWaiting() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("preload me")
        self.send()
        sleep(4)
        self.clearCache()
        // The list brings the chat back to the phone.
        self.launch([])
        sleep(3)
        self.server("stop")
        self.launch([])
        self.point(0.5, 0.24).tap()
        sleep(1)
        self.shot("open-0-preloaded")
        XCTAssertTrue(self.userMessage("preload me").exists, "preloaded")

        self.clearCache()
        self.launch([])
        self.point(0.5, 0.24).tap()
        sleep(1)
        self.shot("open-1-loading")
        XCTAssertFalse(self.userMessage("preload me").exists)
        self.server("start")
        sleep(5)
        self.shot("open-2-loaded")
        XCTAssertTrue(self.userMessage("preload me").exists, "loaded once the server is back")
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
        self.launch(remoteServer)
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

    /// The Subagents list in the title menu keeps time while it is open, without moving.
    func testSubagentMenuTicks() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("& ticker: $ sleep 30 && echo ok")
        self.send()
        sleep(4)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Subagents"].firstMatch.tap()
        sleep(1)
        self.shot("tick-0")
        sleep(2)
        self.shot("tick-1")
    }

    /// Provider errors: while the server retries, the τ says when it asks again and why, and the answer that comes
    /// says it was retried; an error that stands is a card with Retry, which sends the message again.
    func testModelErrors() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("!overloaded 2 hello")
        self.send()
        sleep(1)
        self.shot("err-0-retrying")
        sleep(2)
        self.shot("err-1-retrying-again")
        sleep(8)
        self.shot("err-2-answered")
        self.type("!fatal broken")
        self.send()
        sleep(3)
        self.shot("err-3-failed")
        let card = self.app.descendants(matching: .any).matching(identifier: "modelError").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5.0))
        let frame = card.frame
        self.app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 20.0)).tap()
        sleep(3)
        self.shot("err-4-retried")
    }

    /// Pinned chats, as Telegram's: Pin from the menu puts the chat on top with the pin where the badge goes; the
    /// latest pin is first; a right swipe offers Unpin.
    func testPinnedChats() {
        for text in ["pin one", "pin two", "pin three"] {
            self.launch(["-newChat", "YES"])
            self.focusInput()
            self.type(text)
            self.send()
            sleep(2)
            self.app.terminate()
        }
        self.launch([])
        // Pins an earlier run left.
        for _ in 0 ..< 4 {
            self.point(0.5, 0.24).press(forDuration: 1.0)
            sleep(1)
            let unpin = self.app.descendants(matching: .any)["Unpin"].firstMatch
            if unpin.exists {
                unpin.tap()
                sleep(1)
            } else {
                self.point(0.5, 0.97).tap()
                sleep(1)
                break
            }
        }
        self.point(0.5, 0.414).press(forDuration: 1.0)
        sleep(1)
        self.app.descendants(matching: .any)["Pin"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.414).press(forDuration: 1.0)
        sleep(1)
        self.app.descendants(matching: .any)["Pin"].firstMatch.tap()
        sleep(2)
        self.shot("pin-0-list")
        let row = self.point(0.3, 0.24)
        row.press(forDuration: 0.05, thenDragTo: self.point(0.8, 0.24))
        sleep(1)
        self.shot("pin-1-swipe")
        self.point(0.24, 0.235).tap()
        sleep(2)
        self.shot("pin-2-unpinned")
        // Leave the list as found.
        self.point(0.5, 0.24).press(forDuration: 1.0)
        sleep(1)
        self.app.descendants(matching: .any)["Unpin"].firstMatch.tap()
        sleep(1)
    }

    /// Search as Telegram's: the field under the title; chats by title, then messages from the server's index, the
    /// word being typed matching as a prefix; a message opens its chat at itself with the words marked.
    func testSearch() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("the quokka eats a quince by the river")
        self.send()
        sleep(3)
        self.app.terminate()
        self.launch([])
        self.shot("search-0-list")
        let field = self.app.descendants(matching: .any)["chatSearch"].firstMatch
        if field.waitForExistence(timeout: 3.0) {
            field.tap()
        } else {
            self.point(0.5, 0.14).tap()
        }
        sleep(1)
        self.type("quok")
        sleep(2)
        self.shot("search-1-typing")
        self.type("ka river")
        sleep(2)
        self.shot("search-2-results")
        // The first message result, under the Messages header.
        self.point(0.5, 0.21).tap()
        sleep(2)
        self.shot("search-3-opened")
        // Back: the search as it was; cleared, the chat just opened under Recent; Cancel, the list and the tab bar.
        self.point(0.1, 0.08).tap()
        sleep(2)
        self.shot("search-4-back")
        self.point(0.81, 0.095).tap()
        sleep(2)
        self.shot("search-5-recent")
        self.point(0.93, 0.095).tap()
        sleep(2)
        self.shot("search-6-closed")
    }

    /// Search in a chat, from the title menu: the field replaces the title, the count and arrows the input panel, and
    /// the newest match is shown with its words marked; Up goes to an older one.
    func testChatSearch() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        for text in ["a kiwi in the morning", "nothing here", "another kiwi at night", "plain words"] {
            self.type(text)
            self.send()
            sleep(3)
        }
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Search"].firstMatch.tap()
        sleep(1)
        self.type("kiwi")
        sleep(2)
        self.shot("chatsearch-0-results")
        self.app.descendants(matching: .any)["previous result"].firstMatch.tap()
        sleep(1)
        self.shot("chatsearch-1-older")
        self.app.descendants(matching: .any)["closeSearch"].firstMatch.tap()
        sleep(1)
        self.shot("chatsearch-2-closed")
    }

    /// Settings > Usage: the span, the overview with its changes, the days by model, the models and the top chats.
    /// Against a copy of a server that spent something: `TAU_USAGE_SERVER`, default port 7981.
    func testUsage() {
        self.launch(["-tab", "1"], server: ProcessInfo.processInfo.environment["TAU_USAGE_SERVER"] ?? "ws://127.0.0.1:7981")
        sleep(2)
        self.app.descendants(matching: .any)["Usage"].firstMatch.tap()
        sleep(2)
        self.shot("usage-0")
        self.point(0.885, 0.58).tap()
        sleep(1)
        self.shot("usage-1-day")
        self.app.swipeUp()
        sleep(1)
        self.shot("usage-2-models")
    }

    /// The prompt cache, against a dev server whose model keeps it 15 s (`--dev-cache-ttl 15`, `TAU_CACHE_SERVER`,
    /// default port 7982): "warm" in the Usage row, the cache's time left in its submenu while a command keeps the run
    /// working and refreshes keep it, then what they cost and saved, then expired. Settings > Usage counts the refreshes.
    func testPromptCache() {
        self.launch(["-newChat", "YES"], server: ProcessInfo.processInfo.environment["TAU_CACHE_SERVER"] ?? "ws://127.0.0.1:7982")
        self.focusInput()
        self.type("hello")
        self.send()
        sleep(4)
        self.type("$ sleep 24")
        self.send()
        sleep(9)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.shot("pc-0-menu")
        self.app.descendants(matching: .any)["Usage"].firstMatch.tap()
        sleep(1)
        self.shot("pc-1-usage")
        sleep(2)
        self.shot("pc-2-ticking")
        self.point(0.5, 0.9).tap()
        sleep(18)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Usage"].firstMatch.tap()
        sleep(1)
        self.shot("pc-3-done")
        sleep(16)
        self.shot("pc-4-expired")
        self.point(0.5, 0.9).tap()
        sleep(1)
        self.point(0.5, 0.075).tap()
        sleep(1)
        self.shot("pc-5-menu-cold")
        self.launch(["-tab", "1"], server: ProcessInfo.processInfo.environment["TAU_CACHE_SERVER"] ?? "ws://127.0.0.1:7982")
        sleep(2)
        self.app.descendants(matching: .any)["Usage"].firstMatch.tap()
        sleep(2)
        self.app.swipeUp()
        sleep(1)
        self.shot("pc-6-settings-usage")
    }

    /// Photos: the attachment menu through each step, then albums of two, three and five in Telegram's mosaic, one with
    /// a caption.
    func testPhotoAlbums() {
        self.launch(["-newChat", "YES"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func openPicker(_ name: String) {
            self.app.buttons["attach"].firstMatch.tap()
            sleep(2)
            for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
                sleep(2)
                break
            }
            self.shot("album-\(name)-0-open")
        }
        func pick(_ cells: [(CGFloat, CGFloat)], _ name: String) {
            for (index, cell) in cells.enumerated() {
                self.point(cell.0, cell.1).tap()
                usleep(700_000)
                if index == 0 {
                    self.shot("album-\(name)-1-one")
                }
            }
            sleep(1)
            self.shot("album-\(name)-2-picked")
        }
        func send(_ name: String) {
            let button = self.app.descendants(matching: .any)["attachment-send"].firstMatch
            if button.waitForExistence(timeout: 2) {
                button.tap()
            }
            sleep(3)
            self.shot("album-\(name)-3-sent")
        }
        openPicker("a")
        pick([(0.5, 0.49), (0.83, 0.49)], "a")
        send("a")
        openPicker("b")
        pick([(0.5, 0.49), (0.83, 0.49), (0.5, 0.64)], "b")
        self.point(0.4, 0.955).tap()
        sleep(1)
        self.shot("album-b-2-keyboard")
        self.app.typeText("three of them")
        sleep(1)
        self.shot("album-b-2-caption")
        send("b")
        openPicker("c")
        pick([(0.5, 0.49), (0.83, 0.49), (0.5, 0.64), (0.83, 0.64), (0.17, 0.79)], "c")
        self.app.swipeUp()
        sleep(1)
        self.shot("album-c-2-expanded")
        send("c")
        // Text written first, then photos: it becomes their caption.
        self.focusInput()
        self.type("a caption I wrote first")
        openPicker("d")
        pick([(0.5, 0.49)], "d")
        self.shot("album-d-2-caption")
        send("d")
        // Editing a message, then photos: the edit becomes their caption, and the edited message has them.
        self.focusInput()
        self.type("plain words")
        self.send()
        sleep(4)
        self.pressMessage("plain words")
        sleep(1)
        self.app.descendants(matching: .any)["Edit"].firstMatch.tap()
        sleep(1)
        self.type(" and a photo")
        openPicker("e")
        pick([(0.83, 0.49)], "e")
        self.shot("album-e-2-caption")
        send("e")
        sleep(3)
        self.shot("album-e-4-forked")
        // Written, then the menu closed without sending: the field has it back, as edited in the caption.
        self.focusInput()
        self.type("kept")
        openPicker("f")
        pick([(0.5, 0.49)], "f")
        self.point(0.4, 0.955).tap()
        sleep(1)
        self.app.typeText(" too")
        self.shot("album-f-2-edited")
        self.point(0.096, 0.117).tap()
        sleep(1)
        self.shot("album-f-3-closing")
        for label in ["Discard", "Discard Selection", "Cancel"] where self.app.buttons[label].exists {
            self.app.buttons[label].tap()
            break
        }
        sleep(2)
        self.shot("album-f-4-returned")
    }

    /// An image the model read, in its tool card, fetched by reference; a tap opens it in the media viewer. Photos the
    /// user sent come back by reference too, from the phone's own copy. Needs /tmp/tau-read-test.png.
    func testModelImages() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("!read /tmp/tau-read-test.png")
        self.send()
        sleep(1)
        self.shot("mi-0-loading")
        sleep(4)
        self.shot("mi-1-card")
        self.app.descendants(matching: .any).matching(identifier: "photo").firstMatch.tap()
        sleep(2)
        self.shot("mi-2-viewer")
        self.app.swipeDown()
        sleep(2)
        self.shot("mi-3-closed")
        // Relaunched: the transcript from the cache, the image from the media cache.
        self.launch([])
        self.point(0.5, 0.24).tap()
        sleep(2)
        self.shot("mi-4-relaunched")
    }

    /// Dictation, with the stand-in engine: the field's microphone listens, a disc with the blob in its place, and the
    /// words come in; with text written, Send stays beside it while it adds to the text.
    func testDictation() {
        self.launch(["-newChat", "YES", "-mockDictation", "YES"])
        self.app.descendants(matching: .any)["microphone"].firstMatch.tap()
        sleep(1)
        self.shot("dict-0-listening")
        sleep(2)
        self.shot("dict-1-more")
        self.app.descendants(matching: .any)["stopDictation"].firstMatch.tap()
        sleep(1)
        self.shot("dict-2-stopped")
        self.focusInput()
        self.type(" Then")
        sleep(1)
        self.app.descendants(matching: .any)["microphone"].firstMatch.tap()
        sleep(2)
        self.shot("dict-3-append")
        self.app.descendants(matching: .any)["stopDictation"].firstMatch.tap()
        sleep(1)
        XCTAssertTrue(self.app.descendants(matching: .any)["send"].firstMatch.waitForExistence(timeout: 3))
        self.shot("dict-4-send")
    }

    /// The Live Activity: a message sent puts the chat in the island while it works, the minutes counting; on the lock
    /// screen a card; done, a check.
    func testLiveActivity() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("$ sleep 75 && echo the build passes")
        self.send()
        sleep(3)
        XCUIDevice.shared.press(.home)
        sleep(3)
        self.shot("la-0-island")
        // The island, held: its expanded view.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.2)
        sleep(2)
        self.shot("la-1-expanded")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        sleep(1)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        self.shot("la-2-lock")
        // Back in the app until it answers, so the activity hears it.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(1)
        self.app.activate()
        sleep(75)
        XCUIDevice.shared.press(.home)
        sleep(3)
        self.shot("la-3-done")
        self.app.activate()
    }

    /// Three chats at once: two working, one done, in the island (how many work), expanded (a row each) and on the lock
    /// screen.
    func testLiveActivityChats() {
        self.launch(["-newChat", "YES"])
        for (index, text) in ["$ sleep 90 && echo first", "$ sleep 90 && echo second", "$ sleep 4 && echo all green"].enumerated() {
            if index > 0 {
                self.point(0.1, 0.08).tap()
                sleep(2)
                self.point(0.9, 0.098).tap()
                sleep(2)
            }
            self.focusInput()
            self.type(text)
            self.send()
            sleep(2)
        }
        sleep(6)
        self.point(0.1, 0.08).tap()
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(3)
        self.shot("lac-0-island")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.2)
        sleep(2)
        self.shot("lac-1-expanded")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        sleep(1)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        self.shot("lac-2-lock")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(1)
        self.app.activate()
    }

    /// Folders: seeded on first launch (the biggest project), the tabs under the search field, a tab's list, a swipe
    /// back to All, a tab's menu, Settings > Chat Folders, a new folder and its chat picker.
    func testFolders() {
        // Two chats in one project, so the seed makes its folder: the server may be new.
        for text in ["folder one", "folder two"] {
            self.launch(["-newChat", "YES"])
            self.focusInput()
            self.type(text)
            self.send()
            sleep(2)
        }
        self.launch(["-folders", "YES"])
        sleep(3)
        self.shot("fold-0-tabs")
        let tabs = self.app.descendants(matching: .any).matching(NSPredicate(format: "label == 'tmp'"))
        print("TABS", tabs.count, self.app.descendants(matching: .any).matching(NSPredicate(format: "label == 'All'")).count)
        self.point(0.72, 0.226).tap()
        sleep(2)
        self.shot("fold-1-folder")
        self.app.swipeRight()
        sleep(2)
        self.shot("fold-2-swiped")
        self.point(0.72, 0.226).press(forDuration: 1.0)
        sleep(2)
        self.shot("fold-3-menu")
        self.point(0.5, 0.95).tap()
        sleep(1)
        self.app.terminate()
        self.launch(["-tab", "1", "-folders", "keep"])
        sleep(2)
        self.app.descendants(matching: .any)["Chat Folders"].firstMatch.tap()
        sleep(2)
        self.shot("fold-4-settings")
        self.app.descendants(matching: .any)["Create a New Folder"].firstMatch.tap()
        sleep(2)
        self.shot("fold-5-new")
        self.app.descendants(matching: .any)["Add Chats"].firstMatch.tap()
        sleep(2)
        self.shot("fold-6-picker")
        self.app.descendants(matching: .any)["Working"].firstMatch.tap()
        sleep(1)
        self.point(0.9, 0.08).tap()
        sleep(2)
        self.shot("fold-7-named")
        self.point(0.88, 0.08).tap()
        sleep(2)
        self.app.terminate()
        self.launch(["-folders", "keep"])
        sleep(3)
        self.point(0.83, 0.226).tap()
        sleep(2)
        self.shot("fold-8-empty")
        self.point(0.5, 0.226).press(forDuration: 1.0)
        sleep(2)
        self.shot("fold-9-menu")
        self.app.descendants(matching: .any)["Reorder Tabs"].firstMatch.tap()
        sleep(2)
        self.shot("fold-10-reorder")
        self.point(0.9, 0.08).tap()
        sleep(1)
        self.point(0.5, 0.14).tap()
        sleep(2)
        self.shot("fold-11-search")
        self.type("sleep")
        sleep(2)
        self.shot("fold-12-results")
        self.type("qqqzz")
        sleep(2)
        self.shot("fold-13-none")
    }

    /// Reading back while a long answer streams: scrolled up a little, then a lot, then back to the end; every half second
    /// a screenshot, to see blocks overlap or the row jump.
    func testStreamingScroll() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("!doc 24")
        self.send()
        sleep(6)
        self.app.swipeDown()
        self.shot("ss-00")
        for index in 1 ... 12 {
            usleep(500_000)
            self.shot(String(format: "ss-%02d", index))
        }
        self.point(0.5, 0.4).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.55))
        for index in 13 ... 24 {
            usleep(500_000)
            self.shot(String(format: "ss-%02d", index))
        }
        self.app.swipeUp()
        self.app.swipeUp()
        for index in 25 ... 30 {
            usleep(500_000)
            self.shot(String(format: "ss-%02d", index))
        }
        // The arrow to the end: there the list follows the answer again.
        self.point(0.92, 0.885).tap()
        for index in 31 ... 40 {
            usleep(500_000)
            self.shot(String(format: "ss-%02d", index))
        }
        // Done: the whole answer as it stays, from its end back to its start.
        sleep(30)
        self.shot("ss-done-0")
        for index in 1 ... 3 {
            self.app.swipeDown()
            self.app.swipeDown()
            sleep(1)
            self.shot("ss-done-\(index)")
        }
    }

    /// The streaming answer leaves the screen (the user reads an older one) and comes back: it goes on where it was,
    /// not revealed again from its first letter.
    func testStreamingRecycle() {
        self.launch(["-newChat", "YES"])
        self.focusInput()
        self.type("!doc 4")
        self.send()
        sleep(14)
        self.type("!doc 24")
        self.send()
        sleep(8)
        for _ in 0 ..< 6 {
            self.app.swipeDown()
        }
        self.shot("sr-00")
        sleep(2)
        for _ in 0 ..< 6 {
            self.app.swipeUp()
        }
        for index in 1 ... 8 {
            usleep(250_000)
            self.shot(String(format: "sr-%02d", index))
        }
    }

    /// A pinned chat on top, then the list scrolled and back, the search field collapsing and coming back: the list
    /// must settle (an inset that followed the collapsing field looped until the stack ran out).
    func testPinnedListScrolls() {
        self.launch([])
        self.point(0.5, 0.24).press(forDuration: 1.0)
        sleep(1)
        let pin = self.app.descendants(matching: .any)["Pin"].firstMatch
        if pin.exists {
            pin.tap()
        } else {
            self.point(0.5, 0.97).tap()
        }
        sleep(2)
        self.app.terminate()
        self.launch([])
        sleep(2)
        self.app.swipeUp()
        sleep(1)
        self.app.swipeDown()
        sleep(1)
        self.point(0.5, 0.14).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.11))
        sleep(1)
        self.shot("pinscroll-0")
        XCTAssertEqual(self.app.state, .runningForeground)
        self.point(0.5, 0.24).press(forDuration: 1.0)
        sleep(1)
        self.app.descendants(matching: .any)["Unpin"].firstMatch.tap()
        sleep(1)
    }

    /// The share sheet from another app: Safari's Share, then tau's sheet with the chats as avatars, New Chat first; a
    /// chat picked, a comment, Send; the message arrives in the chat.
    func testShareExtension() {
        self.launch([])
        sleep(3)
        XCUIDevice.shared.press(.home)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.open(URL(string: "https://example.com")!)
        sleep(4)
        self.shot("share-safari")
        print("BUTTONS", safari.buttons.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" })
        let share = safari.buttons.matching(NSPredicate(format: "identifier == 'ShareButton' OR label == 'Share'")).firstMatch
        if share.exists {
            share.tap()
        } else {
            safari.buttons.matching(NSPredicate(format: "label CONTAINS 'More' OR identifier CONTAINS 'More'")).firstMatch.tap()
            sleep(1)
            safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Share'")).firstMatch.tap()
        }
        sleep(2)
        self.shot("share-0-sheet")
        let tau = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'tau'")).firstMatch
        if !tau.waitForExistence(timeout: 3.0) {
            safari.swipeLeft()
        }
        safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'tau'")).firstMatch.tap()
        sleep(3)
        self.shot("share-1-tau")
        // New Chat and the first chat, a comment, Send.
        safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'New Chat'")).firstMatch.tap()
        sleep(1)
        safari.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.27)).tap()
        sleep(1)
        safari.descendants(matching: .textView).firstMatch.tap()
        safari.typeText("read this page")
        sleep(1)
        self.shot("share-2-picked")
        safari.descendants(matching: .any)["Send"].firstMatch.tap()
        sleep(4)
        self.shot("share-3-sent")
        self.app.activate()
        sleep(3)
        self.shot("share-4-list")
    }
}
