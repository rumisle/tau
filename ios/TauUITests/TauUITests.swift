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
        self.launch(["-theme", "light"])
        self.point(0.5, 0.17).press(forDuration: 1.2)
        sleep(1)
        self.shot("list-preview")
    }

    func testMessageMenuAndSelection() {
        self.launch(["-theme", "light", "-openChat", "4"])
        // The "Compare the three storage backends" bubble.
        self.point(0.75, 0.47).press(forDuration: 1.0)
        sleep(1)
        self.shot("message-menu")
        if self.app.buttons["Select"].waitForExistence(timeout: 2) {
            self.app.buttons["Select"].tap()
            sleep(1)
            self.point(0.5, 0.25).tap()
            sleep(1)
            self.shot("selection")
        }
    }

    func testEdit() {
        self.launch(["-theme", "dark", "-openChat", "4"])
        self.point(0.75, 0.47).press(forDuration: 1.0)
        sleep(1)
        self.shot("edit-menu")
        sleep(1)
        if self.app.buttons["Edit"].waitForExistence(timeout: 2) {
            self.app.buttons["Edit"].tap()
            sleep(2)
            self.shot("edit")
        }
    }

    func testAttachmentPicker() {
        self.launch(["-theme", "light", "-openChat", "1"])
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
        self.launch(["-theme", "light"])
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
        self.launch(["-theme", "light", "-openChat", "5"])
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
        self.launch(["-theme", "light", "-openChat", "2"])
        self.app.buttons["microphone"].firstMatch.tap()
        sleep(1)
        self.shot("microphone")
    }
}
