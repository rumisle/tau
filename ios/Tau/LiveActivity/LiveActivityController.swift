import UIKit
import ActivityKit
import SwiftSignalKit

/// Keeps tau's Live Activities (docs/live-activity.md): a row for each chat the user sent a message to from this phone,
/// from then until they see how it ended, in one activity per server. Updated from the chat list's dialogs while the
/// app runs. A server with the account's APNs key gets each activity's push token and its rows, and updates it while
/// tau is away; without one, nothing does after the half minute iOS gives the app on leaving, so it goes stale with the
/// time it says it has been.
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
    /// Per server slot: its activity, what it shows, its push token, and whether the server was asked to start one.
    private var activities: [Int: Activity<TauActivityAttributes>] = [:]
    private var lastStates: [Int: TauActivityAttributes.ContentState] = [:]
    private var pushTokens: [Int: String] = [:]
    private var startRequested: Set<Int> = []
    private var observed: Set<String> = []
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
        // Activities from before: the ones a server keeps up to date (or started for a reply) go on, with their
        // rows; the others are stale, and go.
        for activity in Activity<TauActivityAttributes>.activities {
            self.adopt(activity)
        }
        // One a server started (push-to-start) while tau runs, for a notification's reply.
        Task { @MainActor [weak self] in
            for await activity in Activity<TauActivityAttributes>.activityUpdates {
                self?.adopt(activity)
            }
        }
        self.dialogsDisposable.set((store.dialogsSignal() |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            self?.update(dialogs)
        }))
    }

    private func slot(of chatId: Int) -> Int {
        return MultiStore.split(chatId).slot
    }

    private func serverStore(_ slot: Int) -> ServerStore? {
        return (self.store as? MultiStore)?.serverStore(slot)
    }

    /// Takes an activity this process did not start: its rows, and its updates from then on.
    private func adopt(_ activity: Activity<TauActivityAttributes>) {
        guard activity.activityState == .active, LiveActivityController.isEnabled, let first = activity.content.state.chats.first else {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        let slot = self.slot(of: first.id)
        if let current = self.activities[slot], current.id != activity.id {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        self.activities[slot] = activity
        self.startRequested.remove(slot)
        let now = Date()
        for (index, chat) in activity.content.state.chats.enumerated() where self.rows[chat.id] == nil {
            self.rows[chat.id] = Row(chat: chat, watchedAt: now.addingTimeInterval(-Double(index)), sawWork: chat.state == .working)
        }
        self.lastStates[slot] = activity.content.state
        self.observe(activity, slot: slot)
    }

    private func observe(_ activity: Activity<TauActivityAttributes>, slot: Int) {
        guard !self.observed.contains(activity.id) else {
            return
        }
        self.observed.insert(activity.id)
        Task { @MainActor [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self, self.activities[slot]?.id == activity.id else {
                    return
                }
                self.pushTokens[slot] = PushRegistration.hex(data)
                self.sync(slot)
            }
        }
        Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, state == .ended || state == .dismissed else {
                    continue
                }
                self.observed.remove(activity.id)
                guard self.activities[slot]?.id == activity.id else {
                    return
                }
                // Ended by its server (its chats done half an hour) or dismissed: what finished has been seen;
                // a chat still working gets a new activity once tau is open.
                self.activities[slot] = nil
                self.pushTokens[slot] = nil
                self.lastStates[slot] = nil
                for (id, row) in self.rows where self.slot(of: id) == slot && row.chat.state != .working {
                    self.rows.removeValue(forKey: id)
                }
                self.sync(slot)
                return
            }
        }
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
            } else if !row.sawWork, row.chat.state == .working, now.timeIntervalSince(row.watchedAt) > 60.0 {
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

    /// Whether a server keeps this slot's activity up to date: it has its push token.
    private func serverPushes(_ slot: Int) -> Bool {
        return self.pushTokens[slot] != nil && self.serverStore(slot)?.canPush == true
    }

    private func publish(alert finished: TauActivityAttributes.Chat?) {
        guard LiveActivityController.isEnabled else {
            return
        }
        let now = Date()
        var bySlot: [Int: [Row]] = [:]
        for (id, row) in self.rows {
            bySlot[self.slot(of: id), default: []].append(row)
        }
        let slots = Set(bySlot.keys).union(self.activities.keys).union(self.lastStates.keys)
        for slot in slots {
            let ordered = (bySlot[slot] ?? []).sorted { $0.watchedAt > $1.watchedAt }.map { row -> TauActivityAttributes.Chat in
                var chat = row.chat
                chat.minutes = Int((chat.finishedAt ?? now).timeIntervalSince(chat.since) / 60.0)
                return chat
            }
            if ordered.isEmpty {
                self.end(slot)
                continue
            }
            let state = TauActivityAttributes.ContentState(chats: Array(ordered.prefix(3)), more: max(0, ordered.count - 3), accent: self.accent)
            let finishedHere = finished.map { self.slot(of: $0.id) == slot } ?? false
            guard state != self.lastStates[slot] || finishedHere else {
                continue
            }
            self.lastStates[slot] = state
            let working = ordered.contains { $0.state == .working }
            let pushes = self.serverPushes(slot)
            // Kept up to date by its server, it is not stale while it works.
            let content = ActivityContent(state: state, staleDate: working && !pushes ? now.addingTimeInterval(LiveActivityController.staleAfter) : nil)
            let active = UIApplication.shared.applicationState == .active
            if let activity = self.activities[slot], activity.activityState == .active {
                var alert: AlertConfiguration?
                // Its server's update carries the alert while tau is away: not twice.
                if let finished, finishedHere, !active, !pushes {
                    let worked = finished.finishedAt.map { workedText($0.timeIntervalSince(finished.since)) } ?? ""
                    alert = AlertConfiguration(title: "\(finished.title)", body: "Done · worked \(worked)\(finished.detail.map { " · \($0)" } ?? "")", sound: .default)
                }
                Task {
                    await activity.update(content, alertConfiguration: alert)
                }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled, active {
                // Activities start from the foreground, as a message is sent; with a push token when its server can use one.
                let serverId = self.serverStore(slot)?.serverInfo?.serverId ?? ""
                let canPush = self.serverStore(slot)?.canPush == true
                if let activity = try? Activity.request(attributes: TauActivityAttributes(serverId: serverId), content: content, pushType: canPush ? .token : nil) {
                    self.activities[slot] = activity
                    self.observe(activity, slot: slot)
                }
            } else if !active, !self.startRequested.contains(slot), let server = self.serverStore(slot), server.canPush {
                // Away (a notification's reply): only the server can start one.
                self.startRequested.insert(slot)
                server.startLiveActivity(rows: (bySlot[slot] ?? []).map(self.serverRow), accent: self.accent) { [weak self] started in
                    if !started {
                        self?.startRequested.remove(slot)
                    }
                }
            }
            self.sync(slot)
        }
        let working = self.rows.values.contains { $0.chat.state == .working }
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
    }

    /// A row as the server keeps it (server/src/devices.ts).
    private func serverRow(_ row: Row) -> JSONObject {
        var value: JSONObject = [
            "appId": row.chat.id,
            "conversationId": row.chat.localId,
            "title": row.chat.title,
            "state": row.chat.state.rawValue,
            "since": Int(row.chat.since.timeIntervalSince1970 * 1000.0),
            "watchedAt": Int(row.watchedAt.timeIntervalSince1970 * 1000.0),
        ]
        if let finishedAt = row.chat.finishedAt {
            value["finishedAt"] = Int(finishedAt.timeIntervalSince1970 * 1000.0)
        }
        if let detail = row.chat.detail {
            value["detail"] = detail
        }
        return value
    }

    /// Tells the slot's server what its activity shows, and where to push.
    private func sync(_ slot: Int) {
        guard let server = self.serverStore(slot), server.canPush else {
            return
        }
        guard let activity = self.activities[slot] else {
            server.setLiveActivity(nil)
            return
        }
        var value: JSONObject = ["id": activity.id, "rows": self.rows.filter { self.slot(of: $0.key) == slot }.values.map(self.serverRow)]
        if let token = self.pushTokens[slot] {
            value["token"] = token
        }
        if let accent = self.accent {
            value["accent"] = Int(accent)
        }
        server.setLiveActivity(value)
    }

    private func end(_ slot: Int) {
        self.lastStates[slot] = nil
        self.pushTokens[slot] = nil
        self.startRequested.remove(slot)
        if let activity = self.activities.removeValue(forKey: slot) {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        self.sync(slot)
    }

    private func endAll() {
        for slot in Set(self.activities.keys).union(self.lastStates.keys) {
            self.end(slot)
        }
        self.minuteTimer?.invalidate()
        self.minuteTimer = nil
        for activity in Activity<TauActivityAttributes>.activities {
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
