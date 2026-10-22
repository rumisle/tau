import UIKit
import ActivityKit
import SwiftSignalKit

/// Keeps tau's Live Activity (docs/live-activity.md): a row for each chat the user sent a message to from this phone,
/// from then until they see how it ended. Updated from the chat list's dialogs while the app runs; without APNs nothing
/// updates it after the half minute iOS gives the app on leaving, so it goes stale with the time it says it has been.
final class LiveActivityController {
    static let shared = LiveActivityController()

    /// Settings > Notifications > Live Activity.
    static var isEnabled: Bool {
        get {
            return UserDefaults.standard.object(forKey: "liveActivity.enabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "liveActivity.enabled")
            if !newValue {
                LiveActivityController.shared.endAll()
            }
        }
    }

    private struct Row {
        var chat: TauActivityAttributes.Chat
        let watchedAt: Date
        /// Its run was seen going: not working after that means it ended.
        var sawWork = false
    }

    private weak var store: TauStore?
    private let dialogsDisposable = MetaDisposable()
    private var rows: [Int: Row] = [:]
    private var lastState: TauActivityAttributes.ContentState?
    private var activity: Activity<TauActivityAttributes>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Each minute while a chat works, for its minutes.
    private var minuteTimer: SwiftSignalKit.Timer?

    /// The theme's accent, which the activity shows its state in.
    private var accent: UInt32?

    private static let doneLifetime: TimeInterval = 30.0 * 60.0
    private static let staleAfter: TimeInterval = 120.0

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didEnterBackground()
        }
    }

    func attach(store: TauStore) {
        self.store = store
        // An activity left from before the app was quit: its rows are gone with the process; start over.
        for activity in Activity<TauActivityAttributes>.activities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        self.dialogsDisposable.set((store.dialogsSignal() |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            self?.update(dialogs)
        }))
    }

    /// New chats waiting for their conversation to be created, to watch then.
    private var pendingDrafts: [Int: Date] = [:]

    /// A message went out to `id` from this phone.
    func watch(_ id: Int) {
        guard LiveActivityController.isEnabled, let store = self.store as? MultiStore else {
            return
        }
        var id = id
        if id < 0 {
            guard let real = store.realId(id) else {
                self.pendingDrafts[id] = Date()
                return
            }
            id = real
        }
        guard let dialog = store.dialog(id) else {
            return
        }
        let serverId = store.server(of: id)?.serverInfo?.serverId ?? ""
        let local = MultiStore.split(id).local
        let chat = TauActivityAttributes.Chat(id: id, serverId: serverId, localId: local, title: dialog.title, state: .working, since: Date(), finishedAt: nil, detail: nil)
        self.rows[id] = Row(chat: chat, watchedAt: Date())
        self.publish(alert: nil)
    }

    /// The accent changed (Settings > Appearance): a shown activity takes it at once.
    func setAccent(_ rgb: UInt32) {
        guard self.accent != rgb else {
            return
        }
        self.accent = rgb
        if !self.rows.isEmpty {
            self.publish(alert: nil)
        }
    }

    /// The chat was opened: how it ended has been seen.
    func seen(_ id: Int) {
        guard let row = self.rows[id], row.chat.state != .working else {
            return
        }
        self.rows.removeValue(forKey: id)
        self.publish(alert: nil)
    }

    private func update(_ dialogs: [DialogModel]) {
        // A new chat's first message: its conversation exists now.
        if let store = self.store as? MultiStore {
            for (draft, at) in self.pendingDrafts {
                if let real = store.realId(draft), dialogs.contains(where: { $0.id == real }) {
                    self.pendingDrafts.removeValue(forKey: draft)
                    self.watch(real)
                } else if Date().timeIntervalSince(at) > 60.0 {
                    self.pendingDrafts.removeValue(forKey: draft)
                }
            }
        }
        guard !self.rows.isEmpty else {
            return
        }
        let byId = Dictionary(dialogs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var finished: TauActivityAttributes.Chat?
        let now = Date()
        for (id, var row) in self.rows {
            guard let dialog = byId[id] else {
                continue
            }
            row.chat.title = dialog.title
            let working = dialog.busy || !dialog.workingSubagents.isEmpty || (dialog.outgoing != nil && !dialog.hasFailedMessage)
            if dialog.hasFailedMessage {
                row.chat.state = .failed
                row.chat.detail = "The message was not sent"
                row.chat.finishedAt = row.chat.finishedAt ?? now
            } else if working {
                row.sawWork = true
                row.chat.state = .working
                row.chat.finishedAt = nil
                row.chat.detail = dialog.subagentActivity ?? "Working"
            } else if row.sawWork, row.chat.state == .working {
                row.chat.state = .done
                row.chat.finishedAt = now
                row.chat.detail = dialog.last.map { firstLine(plainPreview($0.text)) }
                finished = row.chat
            } else if !row.sawWork, now.timeIntervalSince(row.watchedAt) > 60.0 {
                // Its message never started a run that was seen: nothing to wait for.
                self.rows.removeValue(forKey: id)
                continue
            }
            if let ended = row.chat.finishedAt, now.timeIntervalSince(ended) > LiveActivityController.doneLifetime {
                self.rows.removeValue(forKey: id)
                continue
            }
            self.rows[id] = row
        }
        self.publish(alert: finished)
    }

    private func publish(alert finished: TauActivityAttributes.Chat?) {
        guard LiveActivityController.isEnabled else {
            return
        }
        let now = Date()
        let ordered = self.rows.values.sorted { $0.watchedAt > $1.watchedAt }.map { row -> TauActivityAttributes.Chat in
            var chat = row.chat
            chat.minutes = Int((chat.finishedAt ?? now).timeIntervalSince(chat.since) / 60.0)
            return chat
        }
        let state = TauActivityAttributes.ContentState(chats: Array(ordered.prefix(3)), more: max(0, ordered.count - 3), accent: self.accent)
        if ordered.isEmpty {
            self.endAll()
            return
        }
        guard state != self.lastState || finished != nil else {
            return
        }
        self.lastState = state
        let working = ordered.contains { $0.state == .working }
        if working, self.minuteTimer == nil {
            let timer = SwiftSignalKit.Timer(timeout: 60.0, repeat: true, completion: { [weak self] in
                self?.publish(alert: nil)
            }, queue: Queue.mainQueue())
            self.minuteTimer = timer
            timer.start()
        } else if !working, let timer = self.minuteTimer {
            self.minuteTimer = nil
            timer.invalidate()
        }
        let content = ActivityContent(state: state, staleDate: working ? Date().addingTimeInterval(LiveActivityController.staleAfter) : nil)
        if let activity = self.activity, activity.activityState == .active {
            var alert: AlertConfiguration?
            if let finished, UIApplication.shared.applicationState != .active {
                let worked = finished.finishedAt.map { workedText($0.timeIntervalSince(finished.since)) } ?? ""
                alert = AlertConfiguration(title: "\(finished.title)", body: "Done · worked \(worked)\(finished.detail.map { " · \($0)" } ?? "")", sound: .default)
            }
            Task {
                await activity.update(content, alertConfiguration: alert)
            }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled, UIApplication.shared.applicationState == .active {
            // Activities start only from the foreground: as a message is sent.
            self.activity = try? Activity.request(attributes: TauActivityAttributes(), content: content, pushType: nil)
        }
    }

    private func endAll() {
        self.lastState = nil
        self.minuteTimer?.invalidate()
        self.minuteTimer = nil
        let activities = Activity<TauActivityAttributes>.activities
        self.activity = nil
        for activity in activities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// The half minute iOS gives on leaving, to catch an answer that comes right after.
    private func didEnterBackground() {
        guard !self.rows.isEmpty, self.backgroundTask == .invalid else {
            return
        }
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tau.liveActivity") { [weak self] in
            self?.endBackgroundTask()
        }
        Queue.mainQueue().after(25.0) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if self.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }
}

private func firstLine(_ text: String) -> String {
    let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    return line.count > 120 ? String(line.prefix(119)) + "…" : line
}

private func workedText(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60.0)
    if minutes < 1 {
        return "under a minute"
    } else if minutes < 60 {
        return "\(minutes) min"
    }
    return "\(minutes / 60) h \(minutes % 60) min"
}
