import UIKit
import SwiftSignalKit

/// Conversations synced with a tau server (docs/protocol.md). Keeps the dialog list subscribed, subscribes to a
/// conversation while a screen shows it, caches entries on disk so a reopened chat shows at once and a reconnect only
/// fetches what is new. Messages go through the outbox (Outbox.swift, docs/sending.md).
final class ServerStore: ConversationStore, TauServer {
    let connection: TauConnection
    private let cache: EntryCache
    private let scroll: ScrollStateStorage
    private let images = ImageDecoder()

    private var dialogs: [Int: DialogModel] = [:]
    private var dialogOrder: [Int: Int] = [:]
    private let dialogsPromise = ValuePromise<[DialogModel]>([], ignoreRepeated: true)
    private var hiddenDialogs: Set<Int>

    private var replicas: [Int: ConversationReplica] = [:]
    private var watchers: [Int: Int] = [:]
    private var statePromises: [Int: ValuePromise<ConversationState>] = [:]
    let outbox: Outbox
    /// Row IDs of sent messages by the entry each became, so a row does not change identity when it is placed.
    private var rowIdForUserEntry: [Int: [Int: Int]] = [:]
    private var nextAttachmentId = 1

    /// Drafts: local negative IDs until the first message creates the conversation on the server.
    private struct Draft {
        var cwd: String?
        var realId: Int?
        /// Set by the first message: the create request, idempotent, in the outbox.
        var createRequestId: String?
        /// Chosen before the conversation exists; nil for the server's default model.
        var agent: AgentSettings?
        /// An edit's fork: this conversation up to this entry, shown until the fork exists, under its title.
        var forkOf: Int?
        var forkAt: Int?
        var title: String?
        /// Named by the user: the create asks for no automatic title.
        var titleIsManual = false
    }
    /// Each conversation's model as the chat list reports it, for one whose replica is not loaded yet.
    private var dialogAgents: [Int: AgentSettings] = [:]
    /// A model or thinking level just chosen, shown until the conversation's own agent doc says so.
    private var agentOverrides: [Int: (settings: AgentSettings, token: Int, confirmed: Bool)] = [:]
    /// A name just given, shown until the server's dialog says so; `previous` comes back if it is refused.
    private var titleOverrides: [Int: (title: String, previous: String, token: Int)] = [:]
    private var nextAgentToken = 0
    private var drafts: [Int: Draft] = [:]
    private var nextDraftId = -1
    private let inputDrafts: InputDraftStorage

    let slot: Int
    /// The name the user gave this server, if any.
    var configuredName: String?
    /// After `hello`, when the server's name, home or defaults may have changed.
    var infoChanged: (() -> Void)?

    init(url: URL, token: String?, slot: Int = 0, name: String? = nil) {
        self.slot = slot
        self.configuredName = name
        self.connection = TauConnection(url: url, token: token)
        self.outbox = Outbox(connection: self.connection, namespace: url.absoluteString)
        self.inputDrafts = InputDraftStorage(namespace: url.absoluteString)
        self.cache = EntryCache(namespace: url.absoluteString)
        self.scroll = ScrollStateStorage(namespace: url.absoluteString)
        self.hiddenDialogs = Set(UserDefaults.standard.array(forKey: "hidden.\(url.absoluteString)") as? [Int] ?? [])
        for dialog in self.cache.loadDialogs() {
            self.dialogs[dialog.id] = dialog
        }
        self.publishDialogs()

        self.connection.onPush = { [weak self] push in
            self?.handlePush(push)
        }
        self.connection.onConnected = { [weak self] hello in
            self?.connected(hello)
        }
        self.setUpOutbox()
        self.inputDrafts.changed = { [weak self] key in
            if Int(key) != nil {
                self?.publishDialogs()
            }
        }
        self.connection.start()
        NotificationCenter.default.addObserver(self, selector: #selector(self.didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    /// Back in the foreground: a socket that died while suspended is found out at once, not at the next ping.
    @objc private func didBecomeActive() {
        self.connection.checkAlive()
        self.outbox.pump()
        self.sendPresence()
    }

    @objc private func willResignActive() {
        self.sendPresence(active: false)
    }

    /// The server pushes nothing while an app is in the foreground showing its own banners.
    private func sendPresence(active: Bool? = nil) {
        let active = active ?? (UIApplication.shared.applicationState == .active)
        self.connection.request("client.presence", ["active": active]) { _ in }
    }

    private let answersPipe = ValuePipe<ChatAnswer>()

    var answers: Signal<ChatAnswer, NoError> {
        return self.answersPipe.signal()
    }

    private var ntfyOverride: NtfyTarget??

    var ntfy: NtfyTarget? {
        if let override = self.ntfyOverride {
            return override
        }
        return self.connection.hello?.ntfy
    }

    func setNtfy(_ target: NtfyTarget?) {
        self.ntfyOverride = .some(target)
        let value: Any = target.map { ["server": $0.server, "topic": $0.topic] as JSONObject } ?? NSNull()
        self.connection.request("settings.configure", ["ntfy": value]) { _ in }
        self.infoChanged?()
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Leaving with messages on their way: as Telegram does, keep running a little to send them.
    @objc private func didEnterBackground() {
        guard self.outbox.hasWork, self.backgroundTask == .invalid else {
            return
        }
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tau.send") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if self.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    private func setUpOutbox() {
        let outbox = self.outbox
        outbox.mintAttachmentId = { [weak self] in
            return self?.mintAttachmentId() ?? 0
        }
        outbox.changed = { [weak self] id in
            guard let self else {
                return
            }
            if self.backgroundTask != .invalid && !outbox.hasWork {
                self.endBackgroundTask()
            }
            if let id {
                self.publish(id)
            } else {
                for (draftId, draft) in self.drafts where draft.realId == nil {
                    self.statePromises[draftId]?.set(self.state(for: draftId))
                }
            }
            self.publishDialogs()
        }
        outbox.placedEntry = { [weak self] requestId, entryId in
            guard let self, let item = outbox.item(requestId), let id = item.conversationId else {
                return
            }
            // One row per message: a guess the submission record corrected leaves no second entry with this row.
            var map = self.rowIdForUserEntry[id] ?? [:]
            for (key, value) in map where value == item.rowId {
                map[key] = nil
            }
            map[entryId] = item.rowId
            self.rowIdForUserEntry[id] = map
        }
        outbox.restored = { [weak self] id, text in
            self?.emit(id, .restoreInput(text))
        }
        outbox.notice = { [weak self] id, text in
            self?.emit(id, .notice(text))
        }
        outbox.created = { [weak self] create, raw in
            guard let self, let dialog = self.dialogModel(raw) else {
                return
            }
            self.dialogs[dialog.id] = dialog
            self.publishDialogs()
            for (draftId, var draft) in self.drafts where draft.createRequestId == create.requestId {
                draft.realId = dialog.id
                self.drafts[draftId] = draft
                if self.statePromises[draftId] != nil {
                    self.watch(dialog.id)
                }
            }
            self.publish(dialog.id)
        }
    }

    // MARK: - Chat events

    private var eventSubscribers: [Int: Bag<(ChatEvent) -> Void>] = [:]
    /// Events for a conversation no chat shows, delivered to the next one that does.
    private var bufferedEvents: [Int: [ChatEvent]] = [:]

    private func emit(_ realId: Int, _ event: ChatEvent) {
        var keys = [realId]
        keys.append(contentsOf: self.drafts.filter { $0.value.realId == realId }.map(\.key))
        var delivered = false
        for key in keys {
            for subscriber in self.eventSubscribers[key]?.copyItems() ?? [] {
                subscriber(event)
                delivered = true
            }
        }
        if !delivered, case .restoreInput = event {
            self.bufferedEvents[realId, default: []].append(event)
        }
    }

    func chatEvents(_ id: Int) -> Signal<ChatEvent, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                return EmptyDisposable
            }
            let bag = self.eventSubscribers[id] ?? Bag()
            self.eventSubscribers[id] = bag
            let index = bag.add { subscriber.putNext($0) }
            if let realId = self.resolve(id), let buffered = self.bufferedEvents.removeValue(forKey: realId) {
                for event in buffered {
                    subscriber.putNext(event)
                }
            }
            return ActionDisposable { [weak bag] in
                Queue.mainQueue().async {
                    bag?.remove(index)
                }
            }
        } |> runOn(Queue.mainQueue())
    }

    var connectionStatus: Signal<ConnectionStatus, NoError> {
        return self.connection.status
    }

    /// A created conversation's draft is under its ID; New Chat has one draft; an edit's fork, until it exists, its own.
    private func inputDraftKey(_ id: Int) -> String {
        if let realId = self.resolve(id) {
            return String(realId)
        }
        if let draft = self.drafts[id], draft.forkOf != nil {
            return "fork\(-id)"
        }
        return InputDraftStorage.newChatKey
    }

    func inputDraft(_ id: Int) -> InputDraft? {
        return self.inputDrafts.draft(self.inputDraftKey(id))
    }

    func setInputDraft(_ draft: InputDraft?, for id: Int) {
        self.inputDrafts.set(draft, for: self.inputDraftKey(id))
    }

    var serverInfo: ServerInfo? {
        guard let hello = self.connection.hello else {
            return nil
        }
        return ServerInfo(serverId: hello.serverId, address: self.connection.url.absoluteString, hostname: hello.hostname, piRevision: hello.piRevision)
    }

    var name: String {
        if let name = self.configuredName, !name.isEmpty {
            return name
        }
        // The name it was added by, "nest" for nest.example.ts.net; for an IP address, the computer's own name.
        let host = self.connection.url.host ?? self.connection.url.absoluteString
        let isAddress = host.first?.isNumber == true || host.contains(":") || host == "localhost"
        if !isAddress {
            return String(host.split(separator: ".").first ?? Substring(host))
        }
        if let hostname = self.connection.hello?.hostname, !hostname.isEmpty {
            return String(hostname.split(separator: ".").first ?? Substring(hostname))
        }
        return host
    }

    var address: String {
        return self.connection.url.absoluteString
    }

    var status: ConnectionStatus {
        return self.connection.currentStatus
    }

    var latency: Double? {
        return self.connection.currentStatus == .online ? self.connection.latency : nil
    }

    var home: String? {
        return self.connection.hello?.home
    }

    private var defaultThinkingOverride: String?

    var defaultThinkingLevel: String {
        return self.defaultThinkingOverride ?? self.connection.hello?.defaultThinkingLevel ?? "off"
    }

    func setDefaultThinkingLevel(_ level: String) {
        self.defaultThinkingOverride = level
        self.connection.request("settings.configure", ["defaultThinkingLevel": level]) { _ in }
        self.infoChanged?()
    }

    /// Set from Settings until the next `hello` reports it.
    private var defaultModelOverride: String?

    var defaultModel: String? {
        return self.defaultModelOverride ?? self.connection.hello?.defaultModel
    }

    func setDefaultModel(_ model: ModelInfo) {
        self.defaultModelOverride = "\(model.provider)/\(model.id)"
        self.connection.request("settings.configure", ["defaultModel": ["provider": model.provider, "modelId": model.id]]) { _ in }
        self.infoChanged?()
    }

    func close() {
        self.connection.close()
    }

    // MARK: - Connection

    private func connected(_ hello: TauConnection.Hello) {
        self.defaultModelOverride = nil
        self.defaultThinkingOverride = nil
        self.ntfyOverride = nil
        self.sendPresence()
        self.infoChanged?()
        self.readSent.removeAll()
        if self.cache.serverId != hello.serverId {
            // Another database: nothing cached is valid.
            self.cache.reset(serverId: hello.serverId)
            for replica in self.replicas.values {
                replica.upsertReset()
            }
        }
        self.connection.setStatus(.updating)
        // The usage row reads each model's context window from the list.
        if self.modelsCache == nil {
            let _ = self.models().start()
        }
        self.connection.request("dialogs.subscribe") { [weak self] result in
            guard let self, case let .success(value) = result else {
                return
            }
            var updated: [Int: DialogModel] = [:]
            for raw in value.objects("dialogs") {
                if let dialog = self.dialogModel(raw) {
                    updated[dialog.id] = dialog
                }
            }
            self.dialogs = updated
            self.publishDialogs()
            self.connection.setStatus(.online)
        }
        for id in self.replicas.keys where (self.watchers[id] ?? 0) > 0 {
            self.subscribe(id)
        }
        self.outbox.connected(serverId: hello.serverId)
    }

    private func handlePush(_ push: JSONObject) {
        switch push.string("event") {
        case "dialog":
            if let raw = push.object("dialog"), var dialog = self.dialogModel(raw) {
                // A run that ended with a new answer of a top-level chat: its banner.
                let previous = self.dialogs[dialog.id]
                if let last = dialog.last, last.role == .assistant, !dialog.busy, dialog.parentConversationId == nil, dialog.unreadCount > 0, last.id > (previous?.last?.id ?? 0), previous?.busy == true || previous == nil {
                    self.answersPipe.putNext(ChatAnswer(conversationId: dialog.id, title: dialog.title, text: plainPreview(last.text)))
                }
                if let override = self.titleOverrides[dialog.id] {
                    if dialog.title == override.title {
                        self.titleOverrides[dialog.id] = nil
                    } else {
                        dialog.title = override.title
                    }
                }
                self.dialogs[dialog.id] = dialog
                self.publishDialogs()
                // An open chat's title follows, as when the server names it after its first answer.
                self.publish(dialog.id)
                // A subagent's cards and its parent's activity follow it.
                if let parent = dialog.parentConversationId {
                    self.publish(parent)
                }
            }
        case "conv.commit":
            guard let id = push.int("conversationId"), let replica = self.replicas[id], replica.isSynced else {
                return
            }
            let inboxBefore = Set(replica.inboxItems.filter { $0.string("mode") != "write" }.compactMap { $0.int("id") })
            let maxBefore = replica.maxId ?? 0
            replica.apply(commit: push)
            let inboxAfter = Set(replica.inboxItems.compactMap { $0.int("id") })
            let users = replica.entries.filter { $0.key > maxBefore && $0.value.string("kind") == "pi.user" }.map { entry -> (id: Int, text: String, images: Int) in
                let (text, images) = TranscriptBuilder.userContent(entry.value.objects("model").first?["content"])
                return (entry.key, text, images.count)
            }
            if !users.isEmpty {
                self.outbox.matchPlacements(conversationId: id, removedSubmissions: Array(inboxBefore.subtracting(inboxAfter)), newUserEntries: users)
            }
            self.outbox.settle(conversationId: id, entries: Set(replica.entries.keys))
            self.publish(id)
            self.cache.scheduleSave(replica)
        case "submission":
            guard let record = push.object("record"), let id = record.int("conversationId") else {
                return
            }
            if let submissionId = record.int("id") {
                self.replicas[id]?.submissions[submissionId] = record
            }
            self.outbox.apply(record: record)
            if let replica = self.replicas[id] {
                self.outbox.settle(conversationId: id, entries: Set(replica.entries.keys))
            }
            self.publish(id)
        default:
            break
        }
    }

    // MARK: - Dialogs

    private func dialogModel(_ raw: JSONObject) -> DialogModel? {
        guard let conversation = raw.object("conversation"), let id = conversation.int("id") else {
            return nil
        }
        let agent = raw.object("agent") ?? [:]
        if let model = agent.object("model"), let modelId = model.string("modelId") {
            self.dialogAgents[id] = AgentSettings(provider: model.string("provider"), modelId: modelId, thinkingLevel: agent.string("thinkingLevel"))
        }
        let model = agent.object("model")?.string("modelId") ?? ""
        var last: DialogModel.EntrySummary?
        if let summary = raw.object("last"), let entryId = summary.int("id") {
            let role: MessageRole
            switch summary.string("kind") {
            case "pi.user":
                role = .user
            case "pi.tool-result":
                role = .tool(name: "")
            default:
                role = .assistant
            }
            let date = summary.double("timestamp").map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()
            last = DialogModel.EntrySummary(id: entryId, role: role, text: summary.string("text") ?? "", date: date)
        }
        self.dialogOrder[id] = last?.id ?? raw.int("createdAt") ?? id
        var dialog = DialogModel(
            id: id,
            title: raw.string("title") ?? "New chat",
            parentConversationId: conversation.object("owner")?.int("conversationId"),
            cwd: agent.string("cwd") ?? "~",
            model: model,
            last: last,
            busy: raw.bool("busy") ?? false,
            unreadCount: raw.int("unreadCount") ?? 0,
            markedUnread: raw.bool("markedUnread") ?? false,
            archived: raw.bool("archived") ?? false
        )
        dialog.pinned = raw.double("pinned")
        dialog.hasFailedMessage = self.hasFailedMessage(id)
        dialog.outgoing = self.outgoingSummary(id)
        // A read this device sent and the server has not reflected yet.
        if let sent = self.readSent[id], let last, sent >= last.id {
            dialog.unreadCount = 0
            dialog.markedUnread = false
        }
        return dialog
    }

    private func hasFailedMessage(_ id: Int) -> Bool {
        return self.outbox.items(for: id).contains { item in
            if case .failed = item.state {
                return true
            }
            return false
        }
    }

    /// The latest message on its way to a conversation, or refused, for its chat list row.
    private func outgoingSummary(_ id: Int) -> DialogModel.Outgoing? {
        let items = self.outbox.items(for: id).filter { item in
            switch item.state {
            case .pending, .queued, .withdrawing, .failed:
                return true
            case .placed:
                return false
            }
        }
        guard let latest = items.max(by: { $0.seq < $1.seq }) else {
            return nil
        }
        var text = latest.text
        if text.isEmpty {
            text = latest.imageFiles.count > 1 ? "\(latest.imageFiles.count) Photos" : "Photo"
        }
        return DialogModel.Outgoing(text: text, date: latest.date, failed: self.hasFailedMessage(id))
    }

    private func publishDialogs() {
        for id in Array(self.dialogs.keys) {
            self.dialogs[id]?.hasFailedMessage = self.hasFailedMessage(id)
            self.dialogs[id]?.outgoing = self.outgoingSummary(id)
            self.dialogs[id]?.draft = self.inputDrafts.draft(String(id))
        }
        var working: [Int: [String]] = [:]
        for dialog in self.dialogs.values where dialog.busy {
            if let parent = dialog.parentConversationId {
                // Background subagents are titled "name: task".
                working[parent, default: []].append(dialog.title.components(separatedBy: ":").first ?? dialog.title)
            }
        }
        for id in Array(self.dialogs.keys) {
            self.dialogs[id]?.workingSubagents = (working[id] ?? []).sorted()
        }
        let visible = self.dialogs.values.filter { $0.parentConversationId == nil && !self.hiddenDialogs.contains($0.id) }
        let sorted = visible.sorted { lhs, rhs in
            let l = lhs.last?.id ?? self.dialogOrder[lhs.id] ?? lhs.id
            let r = rhs.last?.id ?? self.dialogOrder[rhs.id] ?? rhs.id
            return l > r
        }
        self.dialogsPromise.set(sorted)
        self.cache.saveDialogs(Array(self.dialogs.values))
    }

    func dialogsSignal() -> Signal<[DialogModel], NoError> {
        return self.dialogsPromise.get()
    }

    func dialog(_ id: Int) -> DialogModel? {
        if let draft = self.drafts[id] {
            if let realId = draft.realId, let dialog = self.dialogs[realId] {
                return dialog
            }
            let cwd = draft.cwd ?? self.connection.hello?.defaultCwd ?? "~"
            let model = self.agent(id).modelId ?? ""
            return DialogModel(id: id, title: draft.title ?? "New chat", cwd: cwd, model: model, last: nil, busy: false)
        }
        return self.dialogs[id]
    }

    // MARK: - Conversations

    private func resolve(_ id: Int) -> Int? {
        if id < 0 {
            return self.drafts[id]?.realId
        }
        return id
    }

    func conversationSignal(_ id: Int) -> Signal<ConversationState, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                return EmptyDisposable
            }
            let promise = self.statePromise(id)
            let disposable = promise.get().start(next: { subscriber.putNext($0) })
            if let realId = self.resolve(id) {
                self.watch(realId)
            }
            return ActionDisposable { [weak self] in
                disposable.dispose()
                Queue.mainQueue().async {
                    if let self, let realId = self.resolve(id) {
                        self.unwatch(realId)
                    }
                }
            }
        } |> runOn(Queue.mainQueue())
    }

    private func statePromise(_ id: Int) -> ValuePromise<ConversationState> {
        if let promise = self.statePromises[id] {
            return promise
        }
        let promise = ValuePromise<ConversationState>(self.state(for: id), ignoreRepeated: true)
        self.statePromises[id] = promise
        return promise
    }

    private func state(for id: Int) -> ConversationState {
        if let draft = self.drafts[id], let forkOf = draft.forkOf, let forkAt = draft.forkAt {
            // An edit's fork until it exists and its transcript has come: the original up to the edit.
            let forkReplica = draft.realId.flatMap { self.replicas[$0] }
            if forkReplica.map({ !$0.isSynced && $0.entries.isEmpty }) ?? true {
                let preview = ConversationReplica(id: id)
                if let parent = self.replicas[forkOf] {
                    preview.upsert(parent.entries.filter { $0.key <= forkAt }.map(\.value))
                }
                preview.isSynced = true
                var state = TranscriptBuilder.build(replica: preview, outbox: self.outbox, rowIdForUserEntry: self.rowIdForUserEntry[forkOf] ?? [:], images: self.images)
                let items = draft.createRequestId.map { self.outbox.items(forCreate: $0) } ?? draft.realId.map { self.outbox.items(for: $0) } ?? []
                state.messages += items.map { TranscriptBuilder.row(for: $0, outbox: self.outbox) }
                state.busy = false
                state.agent = self.agent(id)
                state.title = self.dialog(id)?.title
                return state
            }
        }
        guard let realId = self.resolve(id) else {
            // A draft: its messages wait for the conversation to be created.
            let items = self.drafts[id]?.createRequestId.map { self.outbox.items(forCreate: $0) } ?? []
            let rows = items.map { TranscriptBuilder.row(for: $0, outbox: self.outbox) }
            var state = ConversationState(messages: rows, streaming: nil, busy: false)
            state.agent = self.agent(id)
            state.title = self.dialog(id)?.title
            return state
        }
        let replica = self.replica(realId)
        var state = TranscriptBuilder.build(replica: replica, outbox: self.outbox, rowIdForUserEntry: self.rowIdForUserEntry[realId] ?? [:], images: self.images)
        state.agent = self.agent(realId)
        state.title = self.dialog(id)?.title
        // A background subagent works on after its call returned: its card follows its conversation.
        for index in state.messages.indices {
            if let child = state.messages[index].tool?.childConversationId {
                state.messages[index].tool?.childBusy = self.dialogs[child]?.busy ?? false
            }
        }
        return state
    }

    private func replica(_ id: Int) -> ConversationReplica {
        if let replica = self.replicas[id] {
            return replica
        }
        let replica = ConversationReplica(id: id)
        if let cached = self.cache.load(id) {
            replica.upsert(cached.entries)
            replica.hasOlder = cached.hasOlder
        }
        self.replicas[id] = replica
        return replica
    }

    private func watch(_ id: Int) {
        let count = (self.watchers[id] ?? 0) + 1
        self.watchers[id] = count
        if count == 1 {
            _ = self.replica(id)
            self.subscribe(id)
        }
    }

    private func unwatch(_ id: Int) {
        let count = max(0, (self.watchers[id] ?? 0) - 1)
        self.watchers[id] = count
        if count == 0 {
            self.replicas[id]?.isSynced = false
            self.connection.request("conversation.unsubscribe", ["conversationId": id]) { _ in }
        }
    }

    /// `conversation.subscribe` for entries after the newest cached one, then live commits.
    private func subscribe(_ id: Int) {
        let replica = self.replica(id)
        replica.isSynced = false
        var params: JSONObject = ["conversationId": id, "limit": 100]
        if let after = replica.maxId {
            params["after"] = after
        }
        self.connection.request("conversation.subscribe", params) { [weak self] result in
            guard let self, case let .success(value) = result else {
                return
            }
            if let gap = value.object("gap"), gap.int("after") != nil {
                // Too much is missing: drop the stale tail rather than show a transcript with a hole in it.
                replica.removeAll()
                replica.hasOlder = true
            } else if params["after"] == nil {
                replica.hasOlder = value.bool("hasOlder") ?? false
            }
            replica.docs = value.object("docs") ?? [:]
            replica.head = value.int("head")
            replica.upsert(value.objects("entries"))
            replica.submissions = [:]
            for record in value.objects("submissions") {
                if let submissionId = record.int("id") {
                    replica.submissions[submissionId] = record
                }
                self.outbox.apply(record: record)
            }
            // Queued here but no longer unsettled there: it settled while this chat was not subscribed.
            self.outbox.refreshSettled(conversationId: id, unsettled: Set(replica.submissions.keys))
            replica.isSynced = true
            self.outbox.settle(conversationId: id, entries: Set(replica.entries.keys))
            self.publish(id)
            self.cache.scheduleSave(replica)
        }
    }

    private func publish(_ realId: Int) {
        let state = self.state(for: realId)
        self.statePromises[realId]?.set(state)
        for (draftId, draft) in self.drafts where draft.realId == realId {
            self.statePromises[draftId]?.set(state)
        }
    }

    func loadOlder(_ id: Int) {
        guard let realId = self.resolve(id), let replica = self.replicas[realId], replica.hasOlder, let oldest = replica.minId else {
            return
        }
        self.connection.request("conversation.history", ["conversationId": realId, "before": oldest, "limit": 100]) { [weak self] result in
            guard let self, case let .success(value) = result else {
                return
            }
            replica.upsert(value.objects("entries"))
            replica.hasOlder = value.bool("hasOlder") ?? false
            self.publish(realId)
            self.cache.scheduleSave(replica)
        }
    }

    // MARK: - Drafts

    func createConversation(cwd: String?) -> Int {
        let id = self.nextDraftId
        self.nextDraftId -= 1
        self.drafts[id] = Draft(cwd: cwd)
        return id
    }

    /// A draft not sent yet runs in `cwd` instead. False once its create has gone out.
    func setDraftCwd(_ id: Int, cwd: String) -> Bool {
        guard var draft = self.drafts[id], draft.createRequestId == nil, draft.forkOf == nil else {
            return false
        }
        draft.cwd = cwd
        self.drafts[id] = draft
        self.statePromises[id]?.set(self.state(for: id))
        return true
    }

    func discardIfDraft(_ id: Int) {
        guard let draft = self.drafts[id], draft.realId == nil else {
            return
        }
        if let create = draft.createRequestId, !self.outbox.items(forCreate: create).isEmpty {
            return
        }
        self.drafts.removeValue(forKey: id)
        self.statePromises.removeValue(forKey: id)
    }

    // MARK: - Sending

    /// Whether a message sent now waits in the queue: the agent is working, or something is queued before it.
    private func sendsToQueue(_ realId: Int) -> Bool {
        if let replica = self.replicas[realId], replica.isBusy {
            return true
        }
        return self.outbox.items(for: realId).contains { item in
            switch item.state {
            case .queued:
                return true
            case .pending:
                return item.showsInQueue
            default:
                return false
            }
        }
    }

    func send(_ text: String, attachments: [MessageAttachment], to id: Int, mode: SendMode) {
        let outboxMode: OutgoingMessage.Mode = mode == .steer ? .steer : .followUp
        if id < 0 {
            guard var draft = self.drafts[id] else {
                return
            }
            if let realId = draft.realId {
                self.send(text, attachments: attachments, to: realId, mode: mode)
                return
            }
            let createRequestId = draft.createRequestId ?? UUID().uuidString
            if draft.createRequestId == nil {
                draft.createRequestId = createRequestId
                self.drafts[id] = draft
                // The first message stands in as the title until the server names the conversation after the first
                // answer.
                let title = draft.titleIsManual ? (draft.title ?? "") : String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
                if let forkOf = draft.forkOf, let forkAt = draft.forkAt {
                    // A copy made before its message (Restore Full Context): the fork, then the message.
                    self.outbox.enqueueCreate(requestId: createRequestId, cwd: nil, title: draft.title ?? title, agent: nil, forkOf: forkOf, forkAt: forkAt)
                } else {
                    self.outbox.enqueueCreate(requestId: createRequestId, cwd: draft.cwd, title: title, agent: draft.agent)
                }
                if draft.titleIsManual {
                    _ = self.outbox.renameCreate(createRequestId, title: title)
                }
            }
            self.outbox.enqueue(text: text, attachments: attachments, conversationId: nil, createRequestId: createRequestId, mode: outboxMode, showsInQueue: false)
            self.statePromises[id]?.set(self.state(for: id))
            return
        }
        self.outbox.enqueue(text: text, attachments: attachments, conversationId: id, createRequestId: nil, mode: outboxMode, showsInQueue: self.sendsToQueue(id))
    }

    func stop(_ id: Int) {
        guard let realId = self.resolve(id) else {
            return
        }
        self.interrupt(realId, sendNow: nil)
    }

    func stopAndSend(_ text: String, attachments: [MessageAttachment], in id: Int) {
        guard let realId = self.resolve(id) else {
            self.send(text, attachments: attachments, to: id, mode: .steer)
            return
        }
        self.interrupt(realId, sendNow: nil)
        // After the abort in this conversation's order: the run is over, so it goes to the chat, not the queue.
        self.outbox.enqueue(text: text, attachments: attachments, conversationId: realId, createRequestId: nil, mode: .steer, showsInQueue: false)
    }

    func sendNow(_ queued: QueuedMessage, in id: Int) {
        guard let realId = self.resolve(id) else {
            return
        }
        if queued.outgoingId != nil {
            self.interrupt(realId, sendNow: queued.outgoingId)
        } else {
            // Another device's message: taken back, then sent from here once the run is stopped.
            self.withdrawOther(queued, in: realId, restore: false) { [weak self] withdrawn in
                guard let self, withdrawn else {
                    return
                }
                self.interrupt(realId, sendNow: nil)
                self.outbox.enqueue(text: queued.text, attachments: [], conversationId: realId, createRequestId: nil, mode: .steer, showsInQueue: false)
            }
        }
    }

    /// Stop the run: this device's queued messages are withdrawn in order and return to the input field; the abort
    /// withdraws the other devices' ones, which return too.
    private func interrupt(_ realId: Int, sendNow: String?) {
        let queue = self.state(for: realId).queued
        let own = queue.compactMap(\.outgoingId)
        let others = queue.filter { $0.outgoingId == nil && $0.mode != .newContext && !$0.text.isEmpty }
        self.outbox.interrupt(conversationId: realId, restoring: own, sendNow: sendNow) { [weak self] result in
            guard let self, case .success = result else {
                return
            }
            let inbox = Set(self.replicas[realId]?.inboxItems.compactMap { $0.int("id") } ?? [])
            for message in others where !inbox.contains(message.submissionId ?? -1) {
                self.emit(realId, .restoreInput(message.text))
            }
        }
    }

    func withdraw(_ queued: QueuedMessage, in id: Int, restore: Bool) {
        guard let realId = self.resolve(id) else {
            return
        }
        if let outgoingId = queued.outgoingId {
            if !self.outbox.withdraw(outgoingId, restore: restore) {
                self.emit(realId, .notice("Already delivered"))
            }
        } else {
            self.withdrawOther(queued, in: realId, restore: restore, completion: { _ in })
        }
    }

    func move(_ queued: QueuedMessage, in id: Int, to mode: SendMode) {
        guard let realId = self.resolve(id) else {
            return
        }
        let outboxMode: OutgoingMessage.Mode = mode == .steer ? .steer : .followUp
        if let outgoingId = queued.outgoingId {
            self.outbox.move(outgoingId, to: outboxMode)
        } else {
            self.withdrawOther(queued, in: realId, restore: false) { [weak self] withdrawn in
                if withdrawn {
                    self?.outbox.enqueue(text: queued.text, attachments: [], conversationId: realId, createRequestId: nil, mode: outboxMode, showsInQueue: true)
                }
            }
        }
    }

    /// Another device's queued message, by its submission ID, in this conversation's order.
    private func withdrawOther(_ queued: QueuedMessage, in realId: Int, restore: Bool, completion: @escaping (Bool) -> Void) {
        guard let submissionId = queued.submissionId else {
            completion(false)
            return
        }
        self.outbox.enqueueRequest("submission.abort", conversationId: realId, params: ["submissionId": submissionId], repeatable: true) { [weak self] result in
            guard let self else {
                return
            }
            let withdrawn: Bool
            if case let .success(value) = result, value.string("result") == "aborted" {
                withdrawn = true
            } else {
                withdrawn = false
            }
            if withdrawn {
                if restore && !queued.text.isEmpty {
                    self.emit(realId, .restoreInput(queued.text))
                }
            } else if case .success = result {
                self.emit(realId, .notice("Already delivered"))
            }
            completion(withdrawn)
        }
    }

    func resend(_ outgoingId: String, in id: Int) {
        guard let item = self.outbox.item(outgoingId) else {
            return
        }
        let attachments = self.outbox.attachments(item)
        let target = item.conversationId ?? id
        self.outbox.discard(outgoingId)
        self.send(item.text, attachments: attachments, to: target, mode: item.mode == .steer ? .steer : .followUp)
    }

    func discard(_ outgoingId: String, in id: Int) {
        self.outbox.discard(outgoingId)
        if let realId = self.resolve(id) {
            self.publish(realId)
        } else {
            self.statePromises[id]?.set(self.state(for: id))
        }
    }

    // MARK: - Forks

    func edit(messageId: Int, text: String, in id: Int, completion: @escaping (Int) -> Void) {
        guard let realId = self.resolve(id), let replica = self.replicas[realId] else {
            return
        }
        let state = self.state(for: realId)
        guard let message = state.messages.first(where: { $0.id == messageId }), let entryId = message.entryId else {
            return
        }
        let parent = self.dialogs[realId]
        // Fork at the entry before the edited message, so the fork's transcript ends just before it. Through the
        // outbox, as a create: on disk, idempotent, and the edited message waits for it.
        guard let at = replica.entries.keys.filter({ $0 < entryId }).max() else {
            // Editing the first message: a fresh conversation in the same directory, with the same model.
            let draftId = self.createConversation(cwd: parent?.cwd)
            self.drafts[draftId]?.agent = self.agent(realId)
            self.send(text, attachments: message.attachments, to: draftId)
            completion(draftId)
            return
        }
        let draftId = self.nextDraftId
        self.nextDraftId -= 1
        let createRequestId = UUID().uuidString
        var draft = Draft(cwd: parent?.cwd)
        draft.agent = self.agent(realId)
        draft.forkOf = realId
        draft.forkAt = at
        draft.title = parent?.title ?? "Edited"
        draft.createRequestId = createRequestId
        self.drafts[draftId] = draft
        self.outbox.enqueueCreate(requestId: createRequestId, cwd: nil, title: draft.title ?? "Edited", agent: nil, forkOf: realId, forkAt: at)
        self.outbox.enqueue(text: text, attachments: message.attachments, conversationId: nil, createRequestId: createRequestId, mode: .followUp, showsInQueue: false)
        completion(draftId)
    }

    func forkBefore(entryId: Int, in id: Int) -> Int? {
        guard let realId = self.resolve(id), let replica = self.replicas[realId], let at = replica.entries.keys.filter({ $0 < entryId }).max() else {
            return nil
        }
        // Created by its first message, through the outbox, as any draft: leaving it unsent leaves nothing behind.
        let draftId = self.nextDraftId
        self.nextDraftId -= 1
        var draft = Draft(cwd: self.dialogs[realId]?.cwd)
        draft.agent = self.agent(realId)
        draft.forkOf = realId
        draft.forkAt = at
        draft.title = self.dialogs[realId]?.title
        self.drafts[draftId] = draft
        return draftId
    }

    func subagents(of id: Int) -> [DialogModel] {
        guard let realId = self.resolve(id) else {
            return []
        }
        return self.dialogs.values.filter { $0.parentConversationId == realId }.sorted { $0.id < $1.id }
    }

    func duplicateConversation(_ id: Int, completion: @escaping (Int) -> Void) {
        guard let realId = self.resolve(id), let dialog = self.dialogs[realId], let at = dialog.last?.id else {
            return
        }
        self.connection.request("conversation.fork", ["conversationId": realId, "at": at, "title": "\(dialog.title) (copy)"]) { [weak self] result in
            guard let self, case let .success(value) = result, let raw = value.object("dialog"), let dialog = self.dialogModel(raw) else {
                return
            }
            self.dialogs[dialog.id] = dialog
            self.publishDialogs()
            completion(dialog.id)
        }
    }

    /// The last entry each conversation was marked read at from here, so a repeat is not sent.
    private var readSent: [Int: Int] = [:]

    func markSeen(_ id: Int) {
        guard let realId = self.resolve(id) else {
            return
        }
        let latest = max(self.replicas[realId]?.maxId ?? 0, self.dialogs[realId]?.last?.id ?? 0)
        let isUnread = self.dialogs[realId]?.isUnread ?? false
        guard latest > 0, isUnread || (self.readSent[realId] ?? 0) < latest else {
            return
        }
        self.readSent[realId] = latest
        if isUnread {
            self.dialogs[realId]?.unreadCount = 0
            self.dialogs[realId]?.markedUnread = false
            self.publishDialogs()
        }
        self.connection.request("conversation.read", ["conversationId": realId, "at": latest]) { _ in }
    }

    func setUnread(_ id: Int, _ unread: Bool) {
        guard let realId = self.resolve(id) else {
            return
        }
        // Shown at once; the server's dialog push confirms it.
        if unread {
            self.readSent.removeValue(forKey: realId)
            self.dialogs[realId]?.markedUnread = true
        } else {
            self.dialogs[realId]?.markedUnread = false
            self.dialogs[realId]?.unreadCount = 0
            if let last = self.dialogs[realId]?.last?.id {
                self.readSent[realId] = last
            }
        }
        self.publishDialogs()
        self.connection.request("conversation.mark", ["conversationId": realId, "unread": unread]) { _ in }
    }

    func setPinned(_ id: Int, _ pinned: Bool) {
        guard let realId = self.resolve(id) else {
            return
        }
        // The time, so the newest pin is on top across servers too.
        let key = Date().timeIntervalSince1970 * 1000.0
        self.dialogs[realId]?.pinned = pinned ? key : nil
        self.publishDialogs()
        self.connection.request("conversation.mark", ["conversationId": realId, "pinned": pinned ? key : false]) { _ in }
    }

    func setArchived(_ id: Int, _ archived: Bool) {
        guard let realId = self.resolve(id) else {
            return
        }
        self.dialogs[realId]?.archived = archived
        self.publishDialogs()
        self.connection.request("conversation.mark", ["conversationId": realId, "archived": archived]) { _ in }
    }

    /// The server keeps every conversation; deleting hides it from this device's list.
    func deleteConversation(_ id: Int) {
        guard let realId = self.resolve(id) else {
            return
        }
        self.hiddenDialogs.insert(realId)
        UserDefaults.standard.set(Array(self.hiddenDialogs), forKey: "hidden.\(self.connection.url.absoluteString)")
        self.publishDialogs()
    }

    // MARK: - Agent

    private var modelsCache: [ModelInfo]?

    func storageUsage() -> StorageUsage {
        var usage = StorageUsage()
        usage.chats = self.cache.sizes().sorted { $0.bytes > $1.bytes }
        usage.unsentBytes = self.outbox.diskBytes
        usage.draftBytes = self.inputDrafts.diskBytes
        return usage
    }

    func clearCache() {
        // Open chats keep theirs: their transcripts are on screen and in memory.
        let open = Set(self.watchers.filter { $0.value > 0 }.map(\.key))
        self.cache.remove(except: open)
        for (id, replica) in self.replicas where !open.contains(id) {
            replica.removeAll()
            self.replicas[id] = nil
        }
    }

    func cachedModel(provider: String, id: String) -> ModelInfo? {
        return self.modelsCache?.first { $0.provider == provider && $0.id == id }
    }

    func models() -> Signal<[ModelInfo], NoError> {
        if let cached = self.modelsCache {
            return .single(cached)
        }
        return self.connection.request("models.list")
        |> map { value -> [ModelInfo] in
            return value.objects("models").map { ModelInfo(provider: $0.string("provider") ?? "", id: $0.string("id") ?? "", name: $0.string("name") ?? $0.string("id") ?? "", reasoning: $0.bool("reasoning") ?? false, thinkingLevels: ($0["thinkingLevels"] as? [Any])?.compactMap { $0 as? String } ?? ["off"], contextWindow: $0.int("contextWindow")) }
        }
        |> `catch` { _ -> Signal<[ModelInfo], NoError> in
            return .single([])
        }
        |> deliverOnMainQueue
        |> beforeNext { [weak self] models in
            if !models.isEmpty {
                self?.modelsCache = models
            }
        }
    }

    /// A conversation's model: the one chosen just now, else its agent doc, else what the chat list said. A draft
    /// has the one chosen in it or the server's default, which the server fixes in the conversation when it creates
    /// it: changing the default later moves no existing conversation.
    func agent(_ id: Int) -> AgentSettings {
        let fallback = self.defaultModel?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        let defaultAgent = AgentSettings(provider: fallback.first, modelId: fallback.count > 1 ? fallback[1] : nil, thinkingLevel: self.defaultThinkingLevel == "off" ? nil : self.defaultThinkingLevel)
        if id < 0, let draft = self.drafts[id], draft.realId == nil {
            return draft.agent ?? defaultAgent
        }
        guard let realId = self.resolve(id) else {
            return defaultAgent
        }
        var stored: AgentSettings?
        if let agent = self.replicas[realId]?.docs.object("pi.agent"), let model = agent.object("model") {
            stored = AgentSettings(provider: model.string("provider"), modelId: model.string("modelId"), thinkingLevel: agent.string("thinkingLevel"))
        }
        if let override = self.agentOverrides[realId] {
            if override.confirmed && stored == override.settings {
                self.agentOverrides[realId] = nil
            } else {
                return override.settings
            }
        }
        return stored ?? self.dialogAgents[realId] ?? defaultAgent
    }

    func usage(_ id: Int) -> ConversationUsage {
        let agent = self.agent(id)
        let contextWindow = self.modelsCache?.first(where: { $0.provider == agent.provider && $0.id == agent.modelId })?.contextWindow
        guard let realId = self.resolve(id), let replica = self.replicas[realId] else {
            return ConversationUsage(models: [], contextTokens: nil, contextWindow: contextWindow)
        }
        func tokenUsage(_ object: JSONObject) -> TokenUsage {
            return TokenUsage(input: object.int("input") ?? 0, output: object.int("output") ?? 0, cacheRead: object.int("cacheRead") ?? 0, cacheWrite: object.int("cacheWrite") ?? 0, cost: object.object("cost")?.double("total") ?? 0.0)
        }
        let ledger = replica.docs.object("pi.usage")?.object("models") ?? [:]
        let models = ledger.compactMap { key, value in (value as? JSONObject).map { (model: key, usage: tokenUsage($0)) } }.sorted { $0.usage.cost > $1.usage.cost }
        // The latest response since the newest reset or compaction; an aborted or failed one reports nothing.
        var contextTokens: Int?
        for entryId in replica.entries.keys.sorted(by: >) {
            if let head = replica.head, entryId <= head {
                break
            }
            let kind = replica.entries[entryId]?.string("kind")
            if kind == "pi.reset" || kind == "pi.compaction" {
                break
            }
            guard let entry = replica.entries[entryId], kind == "pi.assistant", let usage = entry.objects("model").first?.object("usage") else {
                continue
            }
            let value = tokenUsage(usage)
            let total = value.input + value.output + value.cacheRead + value.cacheWrite
            if total > 0 {
                contextTokens = total
                break
            }
        }
        return ConversationUsage(models: models, contextTokens: contextTokens, contextWindow: contextWindow)
    }

    func configure(_ id: Int, model: ModelInfo?, thinkingLevel: String?) {
        var next = self.agent(id)
        var patch: JSONObject = [:]
        if let model {
            next.provider = model.provider
            next.modelId = model.id
            patch["model"] = ["provider": model.provider, "modelId": model.id]
        }
        if let thinkingLevel {
            next.thinkingLevel = thinkingLevel == "off" ? nil : thinkingLevel
            patch["thinkingLevel"] = thinkingLevel == "off" ? NSNull() : thinkingLevel
        }
        if id < 0, var draft = self.drafts[id], draft.realId == nil {
            // Not created yet: the create asks for it, or, if it is already on its way, a configure follows it.
            draft.agent = next
            self.drafts[id] = draft
            if let create = draft.createRequestId, !self.outbox.configureCreate(create, provider: model?.provider, modelId: model?.id, thinkingLevel: thinkingLevel) {
                self.outbox.enqueueRequest("conversation.configure", createRequestId: create, params: ["agent": patch], repeatable: true)
            }
            self.statePromises[id]?.set(self.state(for: id))
            return
        }
        guard let realId = self.resolve(id) else {
            return
        }
        // Shown at once, as Telegram applies a setting before the server confirms it.
        self.nextAgentToken += 1
        let token = self.nextAgentToken
        self.agentOverrides[realId] = (next, token, false)
        // In order with the messages around it: a model chosen before a message is the one that answers it.
        self.outbox.enqueueRequest("conversation.configure", conversationId: realId, params: ["agent": patch], repeatable: true) { [weak self] result in
            guard let self, self.agentOverrides[realId]?.token == token else {
                return
            }
            switch result {
            case .success:
                // The agent doc's change may come after the answer; until then the choice stands.
                self.agentOverrides[realId]?.confirmed = true
                Queue.mainQueue().after(5.0) { [weak self] in
                    if let self, self.agentOverrides[realId]?.token == token {
                        self.agentOverrides[realId] = nil
                        self.publish(realId)
                    }
                }
            case let .failure(error):
                self.agentOverrides[realId] = nil
                self.emit(realId, .notice("The model could not be changed: \(error.message)"))
            }
            self.publish(realId)
        }
        self.publish(realId)
    }

    func listDirectory(_ path: String?) -> Signal<DirectoryListing, RequestError> {
        var params: JSONObject = [:]
        if let path {
            params["path"] = path
        }
        return self.connection.request("fs.list", params)
        |> map { value -> DirectoryListing in
            let entries = value.objects("entries").map { entry in
                DirectoryListing.Entry(name: entry.string("name") ?? "", isDirectory: entry.string("kind") == "dir", isRepository: entry.bool("git") ?? false)
            }
            return DirectoryListing(path: value.string("path") ?? path ?? "~", parent: value.string("parent"), entries: entries)
        }
        |> deliverOnMainQueue
    }

    func compact(_ id: Int) {
        if let realId = self.resolve(id) {
            // Not repeated after a lost connection: two compactions in a row would summarize the summary.
            self.outbox.enqueueRequest("conversation.compact", conversationId: realId, params: [:], repeatable: false)
        }
    }

    func rename(_ id: Int, title: String) {
        if id < 0, var draft = self.drafts[id], draft.realId == nil {
            draft.title = title
            draft.titleIsManual = true
            self.drafts[id] = draft
            if let create = draft.createRequestId, !self.outbox.renameCreate(create, title: title) {
                self.outbox.enqueueRequest("conversation.rename", createRequestId: create, params: ["title": title], repeatable: true)
            }
            self.statePromises[id]?.set(self.state(for: id))
            return
        }
        guard let realId = self.resolve(id), let current = self.dialogs[realId] else {
            return
        }
        self.nextAgentToken += 1
        let token = self.nextAgentToken
        let previous = self.titleOverrides[realId]?.previous ?? current.title
        self.titleOverrides[realId] = (title, previous, token)
        self.dialogs[realId]?.title = title
        self.publishDialogs()
        self.publish(realId)
        // In order with the conversation's other requests, and again after a lost connection.
        self.outbox.enqueueRequest("conversation.rename", conversationId: realId, params: ["title": title], repeatable: true) { [weak self] result in
            guard let self, let override = self.titleOverrides[realId], override.token == token else {
                return
            }
            if case let .failure(error) = result {
                self.titleOverrides[realId] = nil
                self.dialogs[realId]?.title = override.previous
                self.publishDialogs()
                self.publish(realId)
                self.emit(realId, .notice("The chat could not be renamed: \(error.message)"))
            }
        }
    }

    func resetContext(_ id: Int) {
        if let realId = self.resolve(id) {
            self.outbox.enqueueRequest("conversation.reset", conversationId: realId, params: [:], repeatable: false)
        }
    }

    // MARK: - Misc

    func scrollState(_ id: Int) -> ChatScrollState? {
        return self.resolve(id).flatMap { self.scroll.get($0) }
    }

    func setScrollState(_ state: ChatScrollState?, for id: Int) {
        if let realId = self.resolve(id) {
            self.scroll.set(state, for: realId)
        }
    }

    func mintAttachmentId() -> Int {
        self.nextAttachmentId += 1
        return self.nextAttachmentId
    }
}

extension ConversationReplica {
    func upsertReset() {
        self.removeAll()
        self.isSynced = false
    }
}

enum ImageEncoding {
    /// A photo as the model should get it: at most 1568 pt on its long side (Anthropic's recommended size), JPEG.
    static func jpeg(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 1568.0
        let size = image.size
        let scale = min(1.0, maxSide / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint(), size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

/// Entries per conversation in Caches, as JSON. Entries never change, so a cached one is always right; a different
/// `serverId` drops everything.
final class EntryCache {
    private let directory: URL
    private var saveTimers: [Int: SwiftSignalKit.Timer] = [:]
    private(set) var serverId: String?

    init(namespace: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = namespace.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        self.directory = base.appendingPathComponent("tau/\(safe)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.serverId = try? String(contentsOf: self.directory.appendingPathComponent("server-id"), encoding: .utf8)
    }

    /// Each cached transcript's size.
    func sizes() -> [(id: Int, bytes: Int64)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json", let id = Int(url.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (id, Int64(size))
        }
    }

    func remove(except kept: Set<Int>) {
        for (id, _) in self.sizes() where !kept.contains(id) {
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("\(id).json"))
        }
    }

    func reset(serverId: String) {
        try? FileManager.default.removeItem(at: self.directory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try? serverId.write(to: self.directory.appendingPathComponent("server-id"), atomically: true, encoding: .utf8)
        self.serverId = serverId
    }

    func load(_ id: Int) -> (entries: [JSONObject], hasOlder: Bool)? {
        guard let data = try? Data(contentsOf: self.directory.appendingPathComponent("\(id).json")), let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            return nil
        }
        return (object.objects("entries"), object.bool("hasOlder") ?? true)
    }

    /// Writes a conversation's newest entries a moment after the last change, off the main queue.
    func scheduleSave(_ replica: ConversationReplica) {
        self.saveTimers[replica.id]?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: false, completion: { [weak self, weak replica] in
            guard let self, let replica else {
                return
            }
            self.saveTimers[replica.id] = nil
            let entries = Array(replica.ordered().suffix(300))
            let hasOlder = replica.hasOlder || replica.entries.count > entries.count
            let url = self.directory.appendingPathComponent("\(replica.id).json")
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONSerialization.data(withJSONObject: ["entries": entries, "hasOlder": hasOlder]) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }, queue: Queue.mainQueue())
        self.saveTimers[replica.id] = timer
        timer.start()
    }

    func saveDialogs(_ dialogs: [DialogModel]) {
        let rows: [JSONObject] = dialogs.map { dialog in
            var row: JSONObject = ["id": dialog.id, "title": dialog.title, "cwd": dialog.cwd, "model": dialog.model, "busy": false, "unread": dialog.unreadCount, "markedUnread": dialog.markedUnread, "archived": dialog.archived]
            if let parent = dialog.parentConversationId {
                row["parent"] = parent
            }
            if let pinned = dialog.pinned {
                row["pinned"] = pinned
            }
            if let last = dialog.last {
                row["last"] = ["id": last.id, "text": last.text, "date": last.date.timeIntervalSince1970, "user": last.role == .user]
            }
            return row
        }
        let url = self.directory.appendingPathComponent("dialogs.json")
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONSerialization.data(withJSONObject: rows) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func loadDialogs() -> [DialogModel] {
        guard let data = try? Data(contentsOf: self.directory.appendingPathComponent("dialogs.json")), let rows = (try? JSONSerialization.jsonObject(with: data)) as? [JSONObject] else {
            return []
        }
        return rows.compactMap { row in
            guard let id = row.int("id") else {
                return nil
            }
            var last: DialogModel.EntrySummary?
            if let summary = row.object("last"), let entryId = summary.int("id") {
                last = DialogModel.EntrySummary(id: entryId, role: (summary.bool("user") ?? false) ? .user : .assistant, text: summary.string("text") ?? "", date: Date(timeIntervalSince1970: summary.double("date") ?? 0))
            }
            var dialog = DialogModel(id: id, title: row.string("title") ?? "", parentConversationId: row.int("parent"), cwd: row.string("cwd") ?? "~", model: row.string("model") ?? "", last: last, busy: false, unreadCount: row.int("unread") ?? 0, markedUnread: row.bool("markedUnread") ?? false, archived: row.bool("archived") ?? false)
            dialog.pinned = row.double("pinned")
            return dialog
        }
    }
}
