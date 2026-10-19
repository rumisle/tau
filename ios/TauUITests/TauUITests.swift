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
        self.app.launchArguments = arguments
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
        self.point(0.5, 0.17).press(forDuration: 1.2)
        sleep(1)
        self.shot("list-preview")
        // Tapping the preview opens the chat.
        self.point(0.5, 0.3).tap()
        sleep(1)
        self.shot("list-preview-open")
        // Dismiss a second preview by tapping outside.
        self.point(0.12, 0.08).tap()
        sleep(1)
        self.point(0.5, 0.27).press(forDuration: 1.2)
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
        self.point(0.83, 0.62).tap()
        sleep(1)
        self.shot("attach-selected")
        self.app.buttons["send-photos"].firstMatch.tap()
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
        // The compose button, top right.
        self.point(0.9, 0.08).tap()
        sleep(1)
        self.shot("compose")
        self.point(0.1, 0.08).tap()
        sleep(1)
        self.shot("compose-discarded")
        self.point(0.9, 0.08).tap()
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
}
