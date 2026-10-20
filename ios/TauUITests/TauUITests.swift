import XCTest

/// Drives the app inside the simulator and saves a screenshot per step to /tmp/tau-ui, for checking the UI from the
/// command line: `ios/scripts/uitest.sh [test name]`.
final class TauUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: "/tmp/tau-ui", withIntermediateDirectories: true)
    }

    private func launch(_ arguments: [String] = []) {
        self.app = XCUIApplication()
        // Server tests talk to the local server directly, without the tailnet.
        self.app.launchArguments = ["-server.url", "ws://127.0.0.1:7878"] + arguments
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

    func testChatListPreview() {
        self.launch(["-mock", "YES", "-theme", "light"])
        // The first chat, under Archived Chats.
        self.point(0.5, 0.26).press(forDuration: 1.2)
        sleep(1)
        self.shot("list-preview")
        // Tapping the preview opens the chat.
        self.point(0.5, 0.3).tap()
        sleep(1)
        self.shot("list-preview-open")
        // Dismiss a second preview by tapping outside.
        self.point(0.12, 0.08).tap()
        sleep(1)
        self.point(0.5, 0.35).press(forDuration: 1.2)
        sleep(1)
        self.point(0.5, 0.97).tap()
        usleep(100_000)
        self.shot("list-preview-dismissing")
        sleep(1)
        self.shot("list-preview-dismissed")
    }

    func testMessageMenuAndSelection() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "4"])
        // The "Compare the three storage backends" bubble.
        self.point(0.75, 0.47).press(forDuration: 1.0)
        sleep(1)
        self.shot("message-menu")
        let select = self.app.descendants(matching: .any)["Select"].firstMatch
        if select.waitForExistence(timeout: 2) {
            select.tap()
            usleep(150_000)
            self.shot("selection-entering")
            sleep(1)
            self.shot("selection-one")
            self.point(0.5, 0.25).tap()
            sleep(1)
            self.shot("selection")
            // Cancel, where the back button was.
            self.point(0.1, 0.08).tap()
            sleep(1)
            self.shot("selection-cancelled")
        }
    }

    func testEdit() {
        self.launch(["-mock", "YES", "-theme", "dark", "-openChat", "4"])
        self.point(0.75, 0.47).press(forDuration: 1.0)
        sleep(1)
        self.shot("edit-menu")
        sleep(1)
        let edit = self.app.descendants(matching: .any)["Edit"].firstMatch
        if edit.waitForExistence(timeout: 2) {
            edit.tap()
            sleep(2)
            self.shot("edit")
        }
    }

    func testAttachmentPicker() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "1"])
        self.app.buttons["attach"].firstMatch.tap()
        sleep(2)
        // The photo library permission prompt, on first run.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
            sleep(2)
            break
        }
        self.shot("attach")
        self.point(0.5, 0.62).tap()
        sleep(1)
        self.point(0.83, 0.62).tap()
        sleep(1)
        self.shot("attach-selected")
        let send = self.app.descendants(matching: .any)["attachment-send"].firstMatch
        if send.waitForExistence(timeout: 2) {
            send.tap()
        }
        sleep(3)
        self.shot("attach-sent")
    }

    func testTabsAndSettings() {
        self.launch(["-mock", "YES", "-theme", "light"])
        self.point(0.72, 0.945).tap()
        sleep(1)
        self.shot("tab-settings")
        self.point(0.5, 0.653).tap()
        sleep(1)
        self.shot("appearance")
        // The third row, Night.
        self.point(0.5, 0.33).tap()
        sleep(1)
        self.shot("appearance-night")
        self.point(0.5, 0.21).tap()
        sleep(1)
    }

    func testScrollMemory() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "5"])
        for _ in 0 ..< 3 {
            self.point(0.5, 0.3).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.85))
        }
        sleep(1)
        self.shot("scroll-before")
        // Back, then open the same chat again.
        self.point(0.08, 0.075).tap()
        sleep(1)
        self.point(0.5, 0.52).tap()
        sleep(2)
        self.shot("scroll-after")
    }

    func testMicrophone() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "2"])
        self.app.buttons["microphone"].firstMatch.tap()
        sleep(1)
        self.shot("microphone")
    }

    func testComposeDiscard() {
        self.launch(["-mock", "YES", "-theme", "light"])
        // The compose button, top right, then the default folder.
        self.point(0.9, 0.08).tap()
        sleep(1)
        self.shot("compose-picker")
        self.app.descendants(matching: .any)["Default folder"].firstMatch.tap()
        sleep(1)
        self.shot("compose")
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.shot("compose-discarded")
        self.point(0.9, 0.08).tap()
        sleep(1)
        self.app.descendants(matching: .any)["Default folder"].firstMatch.tap()
        sleep(1)
        self.point(0.5, 0.955).tap()
        sleep(1)
        self.app.typeText("hello there")
        self.app.buttons["send"].firstMatch.tap()
        sleep(3)
        self.shot("compose-sent")
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.shot("compose-kept")
    }

    /// Against a running tau server (no -mock): send, then watch the run stream in.
    func testServerLive() {
        self.launch(["-theme", "light", "-openChat", "3"])
        sleep(2)
        self.point(0.5, 0.955).tap()
        sleep(1)
        self.app.typeText("Count the Swift files under ios/Tau with a shell command, then name the three largest.")
        self.app.buttons["send"].firstMatch.tap()
        for step in 0 ..< 8 {
            usleep(1_200_000)
            self.shot("live-\(step)")
        }
        sleep(6)
        self.shot("live-done")
    }

    func testTitleMenu() {
        self.launch(["-theme", "light", "-openChat", "3"])
        sleep(2)
        self.point(0.5, 0.08).tap()
        sleep(1)
        self.shot("title-menu")
        let model = self.app.descendants(matching: .any)["Model"].firstMatch
        if model.waitForExistence(timeout: 2) {
            model.tap()
            sleep(2)
            self.shot("title-models")
        }
    }

    func testServerBrowse() {
        self.launch(["-theme", "night"])
        sleep(2)
        self.point(0.9, 0.08).tap()
        sleep(2)
        self.shot("browse-recent")
        self.app.descendants(matching: .any)["Browse…"].firstMatch.tap()
        sleep(2)
        self.shot("browse-home")
    }

    func testDownButton() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "5"])
        sleep(1)
        self.app.swipeDown()
        self.app.swipeDown()
        sleep(1)
        self.shot("down-visible")
        self.point(0.92, 0.895).tap()
        sleep(1)
        self.shot("down-tapped")
    }

    /// Against a running tau server: a photo with a caption goes to the model.
    func testServerPhoto() {
        self.launch(["-theme", "light", "-openChat", "3"])
        sleep(2)
        self.app.buttons["attach"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.62).tap()
        sleep(1)
        self.point(0.5, 0.955).tap()
        sleep(1)
        self.app.typeText("What is in this photo? One sentence.")
        let send = self.app.descendants(matching: .any)["attachment-send"].firstMatch
        if send.waitForExistence(timeout: 2) {
            send.tap()
        }
        sleep(12)
        self.shot("server-photo")
    }

    func testCaptionKeyboard() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "1"])
        self.app.buttons["attach"].firstMatch.tap()
        sleep(2)
        self.point(0.5, 0.62).tap()
        sleep(1)
        self.point(0.4, 0.955).tap()
        sleep(2)
        self.shot("caption-keyboard")
    }

    /// Against a running tau server: edit the last user message; the chat continues in a fork.
    func testServerEdit() {
        self.launch(["-theme", "light", "-openChat", "3"])
        sleep(2)
        self.shot("server-edit-before")
        // The user bubble near the bottom.
        self.point(0.75, 0.77).press(forDuration: 1.0)
        sleep(1)
        let edit = self.app.descendants(matching: .any)["Edit"].firstMatch
        guard edit.waitForExistence(timeout: 2) else {
            self.shot("server-edit-nomenu")
            return
        }
        edit.tap()
        sleep(1)
        self.app.typeText(" Also, is 1003?")
        self.app.buttons["send"].firstMatch.tap()
        sleep(10)
        self.shot("server-edit-after")
    }

    /// Telegram's swipe actions, Archived Chats, and the menu offering Mark as Unread on a read chat.
    func testArchiveAndRead() {
        self.launch(["-mock", "YES", "-theme", "light"])
        // A read chat offers Mark as Unread.
        self.point(0.5, 0.26).press(forDuration: 1.2)
        sleep(1)
        self.shot("archive-menu")
        XCTAssertTrue(self.app.descendants(matching: .any)["Mark as Unread"].firstMatch.waitForExistence(timeout: 2))
        self.point(0.12, 0.06).tap()
        sleep(1)
        // Swipe right: Read / Unread.
        self.point(0.3, 0.35).press(forDuration: 0.05, thenDragTo: self.point(0.6, 0.35))
        sleep(1)
        self.shot("archive-swipe-right")
        self.point(0.12, 0.06).tap()
        sleep(1)
        // Swipe left: Delete, Archive.
        self.point(0.8, 0.26).press(forDuration: 0.05, thenDragTo: self.point(0.45, 0.26))
        sleep(1)
        self.shot("archive-swipe-left")
        // The Archive button, rightmost.
        self.point(0.9, 0.25).tap()
        sleep(2)
        self.shot("archive-archived")
        // Into Archived Chats.
        self.point(0.5, 0.17).tap()
        sleep(1)
        self.shot("archive-folder")
    }

    /// Against a running tau server: a sent photo opens in Telegram's media viewer and swipes away.
    func testImageViewer() {
        self.launch(["-theme", "light", "-openChat", "3"])
        sleep(2)
        // Scroll up to a photo.
        let photo = self.app.descendants(matching: .any).matching(identifier: "photo").firstMatch
        for _ in 0 ..< 6 where !(photo.exists && photo.isHittable) {
            self.point(0.5, 0.35).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.75))
            sleep(1)
        }
        photo.tap()
        usleep(120_000)
        self.shot("viewer-opening")
        sleep(1)
        self.shot("viewer-open")
        self.point(0.5, 0.5).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.85))
        usleep(150_000)
        self.shot("viewer-closing")
        sleep(1)
        self.shot("viewer-closed")
    }

    /// Telegram's text selection: long press a message for its menu, then long press its text.
    func testTextSelection() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "2"])
        // The last answer, above the input.
        self.point(0.4, 0.87).press(forDuration: 1.0)
        sleep(1)
        self.shot("textsel-menu")
        self.point(0.45, 0.745).press(forDuration: 1.0)
        sleep(1)
        self.shot("textsel-selected")
    }

    /// Against a running tau server: a chat with many tool calls keeps its scroll position when left and reopened,
    /// and after a relaunch.
    func testServerScrollMemory() {
        self.launch(["-theme", "light", "-openChat", "370"])
        sleep(2)
        for _ in 0 ..< 4 {
            self.point(0.5, 0.3).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.8))
        }
        sleep(2)
        self.shot("scrollmem-left")
        // Home saves the position; the next launch starts the app fresh.
        XCUIDevice.shared.press(.home)
        sleep(2)
        self.launch(["-theme", "light", "-openChat", "370"])
        sleep(3)
        self.shot("scrollmem-relaunched")
    }

    /// Against a running tau server: Settings > Default Model lists the server's models and changes the default.
    func testDefaultModel() {
        self.launch(["-theme", "light", "-tab", "1"])
        sleep(1)
        self.app.descendants(matching: .any)["Default Model"].firstMatch.tap()
        sleep(2)
        self.shot("default-model")
    }

    /// Against a running tau server: a tap on a code block copies it, as in Telegram.
    func testCodeCopy() {
        self.launch(["-theme", "light", "-openChat", "304"])
        sleep(2)
        self.point(0.4, 0.32).tap()
        usleep(300_000)
        self.shot("code-copied")
    }
}
