import XCTest

/// Drives the app inside the simulator and saves a screenshot per step to /tmp/tau-ui, for checking the UI from the
/// command line: `ios/scripts/uitest.sh [test name]`.
/// Where screenshots go, and the server requests of SendingUITests: TAU_UI_DIR, one per simulator when
/// ios/scripts/uitests.sh runs several.
let uiDirectory = ProcessInfo.processInfo.environment["TAU_UI_DIR"] ?? "/tmp/tau-ui"

final class TauUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: uiDirectory, withIntermediateDirectories: true)
    }

    private func launch(_ arguments: [String] = []) {
        self.app = XCUIApplication()
        // Server tests talk to the local server directly, without the tailnet.
        self.app.launchArguments = ["-server.url", "ws://127.0.0.1:7878", "-uiTesting", "YES"] + mainServerToken + (arguments.contains("-wrapCode") ? [] : ["-wrapCode", "YES"]) + arguments
        self.app.launch()
        // Until what the launch opens is there: a chat's transcript, or the list.
        if arguments.contains(where: { ["-openChat", "-newChat", "-sendTo", "-pushChat"].contains($0) }) {
            self.app.waitForChat()
        }
        settle()
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(uiDirectory)/\(name).png"))
    }

    /// The chat's menu, from the bar's ⋯ (the bar's buttons are out of XCUITest's reach, as the list's compose is).
    private func openChatMenu() {
        self.point(0.905, 0.097).tap()
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        return self.app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    func testChatListPreview() {
        self.launch(["-mock", "YES", "-theme", "light"])
        // The first chat, under Archived Chats.
        self.point(0.5, 0.33).press(forDuration: 1.2)
        settle()
        self.shot("list-preview")
        // Tapping the preview opens the chat.
        self.point(0.5, 0.3).tap()
        settle()
        self.shot("list-preview-open")
        // Dismiss a second preview by tapping outside.
        self.point(0.12, 0.08).tap()
        settle()
        self.point(0.5, 0.35).press(forDuration: 1.2)
        settle()
        self.point(0.5, 0.97).tap()
        usleep(100_000)
        self.shot("list-preview-dismissing")
        settle()
        self.shot("list-preview-dismissed")
    }

    func testMessageMenuAndSelection() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "4"])
        // The "Compare the three storage backends" bubble.
        self.point(0.75, 0.47).press(forDuration: 1.0)
        settle()
        self.shot("message-menu")
        let select = self.app.descendants(matching: .any)["Select"].firstMatch
        if select.waitForExistence(timeout: 2) {
            select.tap()
            usleep(150_000)
            self.shot("selection-entering")
            settle()
            self.shot("selection-one")
            self.point(0.5, 0.25).tap()
            settle()
            self.shot("selection")
            // Cancel, where the back button was.
            self.point(0.1, 0.08).tap()
            settle()
            self.shot("selection-cancelled")
        }
    }

    func testEdit() {
        self.launch(["-mock", "YES", "-theme", "dark", "-openChat", "4"])
        self.point(0.75, 0.47).press(forDuration: 1.0)
        settle()
        self.shot("edit-menu")
        settle()
        let edit = self.app.descendants(matching: .any)["Edit"].firstMatch
        if edit.waitForExistence(timeout: 2) {
            edit.tap()
            settle()
            self.shot("edit")
        }
    }

    func testAttachmentPicker() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "1"])
        self.app.buttons["attach"].firstMatch.tap()
        settle()
        // The photo library permission prompt, on first run.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
            settle()
            break
        }
        self.shot("attach")
        self.point(0.5, 0.62).tap()
        settle()
        self.point(0.83, 0.62).tap()
        settle()
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
        settle()
        self.shot("tab-settings")
        self.point(0.5, 0.653).tap()
        settle()
        self.shot("appearance")
        // The third row, Night.
        self.point(0.5, 0.33).tap()
        settle()
        self.shot("appearance-night")
        self.point(0.5, 0.21).tap()
        settle()
    }

    func testScrollMemory() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "5"])
        for _ in 0 ..< 3 {
            self.point(0.5, 0.3).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.85))
        }
        settle()
        self.shot("scroll-before")
        // Back, then open the same chat again.
        self.point(0.08, 0.075).tap()
        settle()
        self.point(0.5, 0.52).tap()
        settle()
        self.shot("scroll-after")
    }

    func testMicrophone() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "2"])
        self.app.buttons["microphone"].firstMatch.tap()
        settle()
        self.shot("microphone")
    }

    func testComposeDiscard() {
        self.launch(["-mock", "YES", "-theme", "light"])
        // The compose button, top right: straight into a new chat.
        self.point(0.9, 0.098).tap()
        settle()
        self.shot("compose")
        self.point(0.1, 0.08).tap()
        settle()
        self.shot("compose-discarded")
        self.point(0.9, 0.098).tap()
        settle()
        self.point(0.5, 0.955).tap()
        settle()
        self.app.typeText("hello there")
        self.app.buttons["send"].firstMatch.tap()
        self.app.waitForIdle(timeout: 60)
        settle()
        self.shot("compose-sent")
        self.point(0.1, 0.08).tap()
        settle()
        self.shot("compose-kept")
    }

    /// Against a running tau server (no -mock): send, then watch the run stream in.
    func testServerLive() {
        self.launch(["-theme", "light", "-openChat", "3"])
        settle()
        self.point(0.5, 0.955).tap()
        settle()
        self.app.typeText("Count the Swift files under ios/Tau with a shell command, then name the three largest.")
        self.app.buttons["send"].firstMatch.tap()
        for step in 0 ..< 8 {
            usleep(1_200_000)
            self.shot("live-\(step)")
        }
        self.app.waitForIdle(timeout: 120)
        settle()
        self.shot("live-done")
    }

    func testTitleMenu() {
        self.launch(["-theme", "light", "-openChat", "3"])
        settle()
        self.openChatMenu()
        settle()
        self.shot("title-menu")
        let model = self.app.descendants(matching: .any)["Model"].firstMatch
        if model.waitForExistence(timeout: 2) {
            model.tap()
            settle()
            self.shot("title-models")
        }
    }

    func testDownButton() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "5"])
        settle()
        self.app.swipeDown()
        self.app.swipeDown()
        settle()
        self.shot("down-visible")
        self.point(0.92, 0.895).tap()
        settle()
        self.shot("down-tapped")
    }

    /// Against a running tau server: a photo with a caption goes to the model.
    func testServerPhoto() {
        self.launch(["-theme", "light", "-openChat", "3"])
        settle()
        self.app.buttons["attach"].firstMatch.tap()
        settle()
        self.point(0.5, 0.62).tap()
        settle()
        self.point(0.5, 0.955).tap()
        settle()
        self.app.typeText("What is in this photo? One sentence.")
        let send = self.app.descendants(matching: .any)["attachment-send"].firstMatch
        if send.waitForExistence(timeout: 2) {
            send.tap()
        }
        self.app.waitForIdle(timeout: 60)
        settle()
        self.shot("server-photo")
    }

    func testCaptionKeyboard() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "1"])
        self.app.buttons["attach"].firstMatch.tap()
        settle()
        self.point(0.5, 0.62).tap()
        settle()
        self.point(0.4, 0.955).tap()
        settle()
        self.shot("caption-keyboard")
    }

    /// Against a running tau server: edit the last user message; the chat continues in a fork.
    func testServerEdit() {
        self.launch(["-theme", "light", "-openChat", "3"])
        settle()
        self.shot("server-edit-before")
        // The user bubble near the bottom.
        self.point(0.75, 0.77).press(forDuration: 1.0)
        settle()
        let edit = self.app.descendants(matching: .any)["Edit"].firstMatch
        guard edit.waitForExistence(timeout: 2) else {
            self.shot("server-edit-nomenu")
            return
        }
        edit.tap()
        settle()
        self.app.typeText(" Also, is 1003?")
        self.app.buttons["send"].firstMatch.tap()
        self.app.waitForIdle(timeout: 60)
        settle()
        self.shot("server-edit-after")
    }

    /// Telegram's swipe actions, Archived Chats, and the menu offering Mark as Unread on a read chat.
    func testArchiveAndRead() {
        self.launch(["-mock", "YES", "-theme", "light"])
        // A read chat offers Mark as Unread.
        self.point(0.5, 0.33).press(forDuration: 1.2)
        settle()
        self.shot("archive-menu")
        XCTAssertTrue(self.app.descendants(matching: .any)["Mark as Unread"].firstMatch.waitForExistence(timeout: 2))
        self.point(0.12, 0.06).tap()
        settle()
        // Swipe right: Read / Unread.
        self.point(0.3, 0.42).press(forDuration: 0.05, thenDragTo: self.point(0.6, 0.42))
        settle()
        self.shot("archive-swipe-right")
        self.point(0.12, 0.06).tap()
        settle()
        // Swipe left: Hide, Archive.
        self.point(0.8, 0.33).press(forDuration: 0.05, thenDragTo: self.point(0.45, 0.33))
        settle()
        self.shot("archive-swipe-left")
        // The Archive button, rightmost.
        self.point(0.9, 0.32).tap()
        settle()
        self.shot("archive-archived")
        // Into Archived Chats.
        self.point(0.5, 0.24).tap()
        settle()
        self.shot("archive-folder")
    }

    /// Against a running tau server: a sent photo opens in Telegram's media viewer and swipes away.
    func testImageViewer() {
        self.launch(["-theme", "light", "-openChat", "3"])
        settle()
        // Scroll up to a photo.
        let photo = self.app.descendants(matching: .any).matching(identifier: "photo").firstMatch
        for _ in 0 ..< 6 where !(photo.exists && photo.isHittable) {
            self.point(0.5, 0.35).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.75))
            settle()
        }
        photo.tap()
        usleep(120_000)
        self.shot("viewer-opening")
        settle()
        self.shot("viewer-open")
        // A tap shows the viewer's bar, then Telegram's ⋯: Share, Save Image, Copy.
        if !self.app.descendants(matching: .any)["Back"].firstMatch.isHittable {
            self.point(0.5, 0.5).tap()
            settle()
        }
        self.shot("viewer-controls")
        self.point(0.905, 0.097).tap()
        settle()
        self.shot("viewer-menu")
        XCTAssertTrue(self.app.descendants(matching: .any)["Save Image"].firstMatch.exists, "the viewer's menu")
        self.point(0.5, 0.85).tap()
        settle()
        // Held, the menu follows the finger: lifted on Copy, it copies.
        self.point(0.905, 0.097).press(forDuration: 0.6, thenDragTo: self.point(0.6, 0.263))
        settle()
        self.shot("viewer-held-copy")
        XCTAssertFalse(self.app.descendants(matching: .any)["Save Image"].firstMatch.exists, "the menu chose and closed")
        sleep(2)
        self.point(0.5, 0.5).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.85))
        usleep(150_000)
        self.shot("viewer-closing")
        settle()
        self.shot("viewer-closed")
    }

    /// Telegram's text selection: long press a message for its menu, then long press its text.
    func testTextSelection() {
        self.launch(["-mock", "YES", "-theme", "light", "-openChat", "2"])
        // The last answer, above the input.
        self.point(0.4, 0.87).press(forDuration: 1.0)
        settle()
        self.shot("textsel-menu")
        self.point(0.45, 0.745).press(forDuration: 1.0)
        settle()
        self.shot("textsel-selected")
    }

    /// Against a running tau server: a chat with many tool calls keeps its scroll position when left and reopened,
    /// and after a relaunch.
    func testServerScrollMemory() {
        self.launch(["-theme", "light", "-openChat", "370"])
        settle()
        for _ in 0 ..< 4 {
            self.point(0.5, 0.3).press(forDuration: 0.05, thenDragTo: self.point(0.5, 0.8))
        }
        sleep(2)
        self.shot("scrollmem-left")
        // Home saves the position; the next launch starts the app fresh.
        XCUIDevice.shared.press(.home)
        settle()
        self.launch(["-theme", "light", "-openChat", "370"])
        sleep(3)
        self.shot("scrollmem-relaunched")
    }

    /// Against a running tau server: Settings > Default Model lists the server's models and changes the default.
    func testDefaultModel() {
        self.launch(["-theme", "light", "-tab", "1"])
        settle()
        // Settings > Servers > the server > Default Model.
        self.app.descendants(matching: .any)["Servers"].firstMatch.tap()
        settle()
        self.point(0.5, 0.28).tap()
        settle()
        self.app.descendants(matching: .any)["Default Model"].firstMatch.tap()
        settle()
        self.shot("default-model")
        // Telegram's search field under the title.
        self.point(0.5, 0.176).tap()
        settle()
        self.app.typeText("opus 4")
        settle()
        self.shot("default-model-search")
    }

    /// Against a running tau server: the chat title's Model opens the picker.
    func testChatModelPicker() {
        self.launch(["-theme", "dark", "-openChat", "3"])
        settle()
        self.openChatMenu()
        settle()
        self.app.descendants(matching: .any)["Model"].firstMatch.tap()
        settle()
        self.shot("chat-model-picker")
    }

    /// Against a running tau server: a tap on a code block copies it, as in Telegram.
    func testCodeCopy() {
        self.launch(["-theme", "light", "-openChat", "304"])
        settle()
        // On the Swift block: copied at once, with no wait for a second tap.
        self.point(0.4, 0.38).tap()
        usleep(300_000)
        self.shot("code-copied")
    }

    /// Against a running tau server: with wrapping off, a code block scrolls sideways.
    func testCodeNoWrap() {
        self.launch(["-theme", "dark", "-openChat", "304", "-wrapCode", "NO"])
        settle()
        self.shot("code-nowrap")
        self.point(0.8, 0.42).press(forDuration: 0.01, thenDragTo: self.point(0.1, 0.42))
        settle()
        self.shot("code-nowrap-scrolled")
    }

    /// Against a running tau server: the title menu's usage row and its submenu.
    func testUsageMenu() {
        self.launch(["-theme", "dark", "-openChat", "304"])
        settle()
        self.openChatMenu()
        settle()
        self.shot("usage-menu")
        self.app.descendants(matching: .any)["Usage"].firstMatch.tap()
        settle()
        self.shot("usage-submenu")
    }

    /// Settings > Appearance: the night theme and the code wrapping switch.
    func testAppearanceSettings() {
        self.launch(["-theme", "dark", "-tab", "1"])
        settle()
        self.app.descendants(matching: .any)["Appearance"].firstMatch.tap()
        settle()
        self.app.swipeUp()
        settle()
        self.shot("appearance")
    }

    /// Formulas as models write them, everywhere Markdown puts them (MockStore.mathAnswers), top to bottom.
    func testMathStress() {
        self.launch(["-mock", "YES", "-theme", "night", "-openChat", "6"])
        settle()
        for index in 0 ..< 6 {
            self.shot("math-\(index)")
            self.app.swipeDown(velocity: .slow)
            settle()
        }
    }

    /// The same answer on each theme's plain background.
    func testThemeBackgrounds() {
        for theme in ["classic", "day", "night", "tintedNight"] {
            self.launch(["-mock", "YES", "-theme", theme, "-openChat", "6"])
            settle()
            self.shot("bg-\(theme)")
        }
    }
}
