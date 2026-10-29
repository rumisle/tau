import XCTest

/// Waiting on what the app does, not for a guessed time: a guess is too short on a loaded machine and too long on an
/// idle one.

/// Polls `condition` every 0.1 s until it holds; false if `timeout` passes first.
@discardableResult
func waitUntil(_ timeout: TimeInterval = 15.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(100_000)
    }
    return condition()
}

/// For what XCUITest does not wait for itself: Telegram's springs and list animations run on display links, which
/// its idle wait does not see, and a screenshot waits for nothing.
func settle() {
    usleep(600_000)
}

extension XCUIApplication {
    /// The open chat's state (ChatControllerNode's test marker, with `-uiTesting`): "loading", "busy" (the agent
    /// works, streams, has messages queued, or one is on its way) or "idle"; "" with no chat open.
    /// One snapshot: an exists-then-value read failed the test when a chat on its way out took the element between the
    /// two.
    var chatState: String {
        guard let snapshot = try? self.descendants(matching: .any)["chatState"].firstMatch.snapshot() else {
            return ""
        }
        return snapshot.value as? String ?? ""
    }

    /// Until the open chat has its transcript.
    func waitForChat(timeout: TimeInterval = 10.0) {
        _ = waitUntil(timeout) { !["", "loading"].contains(self.chatState) }
    }

    /// Until the open chat has been idle for half a second: the run, its answer's streaming, the queue and anything
    /// on its way are done (a follow-up starts within that).
    @discardableResult
    func waitForIdle(timeout: TimeInterval = 30.0) -> Bool {
        var idleSince: Date?
        return waitUntil(timeout) {
            guard self.chatState == "idle" else {
                idleSince = nil
                return false
            }
            let since = idleSince ?? Date()
            idleSince = since
            return Date().timeIntervalSince(since) >= 0.5
        }
    }

    /// Until the agent works in the open chat.
    @discardableResult
    func waitForBusy(timeout: TimeInterval = 10.0) -> Bool {
        return waitUntil(timeout) { self.chatState == "busy" }
    }

    /// The echo model's answer to `text` (server/src/dev-model.ts), once it is there.
    @discardableResult
    func waitForEcho(_ text: String, timeout: TimeInterval = 15.0) -> Bool {
        let answer = self.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'assistantMessage' AND label BEGINSWITH %@", "You said: \(text)")).firstMatch
        return answer.waitForExistence(timeout: timeout)
    }

    /// Until the keyboard is up.
    func waitForKeyboard(timeout: TimeInterval = 5.0) {
        _ = self.keyboards.firstMatch.waitForExistence(timeout: timeout)
    }
}
