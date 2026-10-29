import UIKit
import SwiftSignalKit

/// Conversations synced with a tau server (docs/protocol.md). Keeps the dialog list subscribed, subscribes to a
/// conversation while a screen shows it, caches entries on disk so a reopened chat shows at once and a reconnect only
/// fetches what is new. Messages go through the outbox (Outbox.swift, docs/sending.md).
final class ServerStore: ConversationStore, TauServer {
    let connection: TauConnection
    private let cache: EntryCache
    private let scroll: ScrollStateStorage
    /// Images of entries, fetched when shown.
    let media: MediaLoader

    private var dialogs: [Int: DialogModel] = [:]
    /// The chat list as the server last said it, each Dialog as it came, and the version it is at: the next connection
    /// asks only for what changed since (`dialogs.subscribe { since }`). Kept on disk with it.
    private var serverDialogs: [Int: JSONObject] = [:]
    private var dialogsVersion: String?
    private var dialogsSaveTimer: SwiftSignalKit.Timer?
    /// The conversation each fork was made from, and the entry it was made at.
    private var forkParents: [Int: (conversationId: Int, at: Int)] = [:]
    /// The database the requests sent behind the hello were for (`opened`), and the chats they subscribed: nil when
    /// none were sent.
    private var speculatedServerId: String?
    private var speculatedChats: Set<Int> = []
    private var dialogOrder: [Int: Int] = [:]
    private let dialogsPromise = ValuePromise<[DialogModel]>([], ignoreRepeated: true)
    /// Hides and shows this device asked for that the server has not taken yet, by conversation: kept on disk and
    /// sent again on each connection, so one made offline is not lost. They win over the server's `hidden` meanwhile.
    private var pendingHides: [Int: Bool]

    private var replicas: [Int: ConversationReplica] = [:]
    /// What entries that links name say, by entry ID (unique in the server's database): fetched once.
    private var linkedEntryTexts: [Int: String] = [:]
    private var watchers: [Int: Int] = [:]
    private var statePromises: [Int: ValuePromise<ConversationState>] = [:]
    let outbox: Outbox
    /// Files over HTTP: the outbox's uploads, the chat's downloads (Server/FileTransfer.swift).
    let transfer: FileTransfer
    /// Row IDs of sent messages by the entry each became, so a row does not change identity when it is placed.
    private var rowIdForUserEntry: [Int: [Int: Int]] = [:]
    private var nextAttachmentId = 1

    /// Drafts: local negative IDs until the first message creates the conversation on the server.
    private struct Draft {
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
    /// Each conversation's prompt cache, from its Dialog.
    private var promptCaches: [Int: PromptCache] = [:]
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
        self.transfer = FileTransfer(connection: self.connection, namespace: url.absoluteString)
        self.inputDrafts = InputDraftStorage(namespace: url.absoluteString)
        self.cache = EntryCache(namespace: url.absoluteString)
        let connection = self.connection
        self.media = MediaLoader(namespace: url.absoluteString, request: { [weak connection] method, params, completion in
            guard let connection else {
                completion(.failure(.disconnected))
                return
            }
            connection.request(method, params, completion: completion)
        })
        // The agent's images are files (server/src/send-file.ts), fetched over HTTP.
        self.media.fetchFile = { [weak connection] id, completion in
            guard let connection else {
                completion(nil)
                return
            }
            var request = URLRequest(url: connection.httpBase.appendingPathComponent("files/\(id)"))
            connection.authorize(&request)
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                DispatchQueue.main.async {
                    completion(ok ? data : nil)
                }
            }.resume()
        }
        self.scroll = ScrollStateStorage(namespace: url.absoluteString)
        var pendingHides: [Int: Bool] = [:]
        for (key, value) in UserDefaults.standard.dictionary(forKey: "hides.\(url.absoluteString)") as? [String: Bool] ?? [:] {
            if let id = Int(key) {
                pendingHides[id] = value
            }
        }
        self.pendingHides = pendingHides
        let saved = self.cache.loadDialogs()
        self.dialogsVersion = saved.version
        for raw in saved.dialogs {
            if let id = raw.object("conversation")?.int("id") {
                self.serverDialogs[id] = raw
            }
        }
        for raw in self.serverDialogs.values {
            // None shows as working before the server says so.
            if var dialog = self.dialogModel(raw) {
                dialog.busy = false
                self.dialogs[dialog.id] = dialog
            }
        }
        self.publishDialogs()

        self.connection.onPush = { [weak self] push in
            self?.handlePush(push)
        }
        self.connection.onOpen = { [weak self] in
            self?.opened()
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
        NotificationCenter.default.addObserver(self, selector: #selector(self.registerDevice), name: PushRegistration.changed, object: nil)
    }

    // MARK: - Apple's push

    /// It has the account's APNs key (server/src/apns.ts).
    var canPush: Bool {
        return self.connection.hello?.apns ?? false
    }

    /// Settings > Notifications: its answers as notifications.
    var pushAlerts: Bool {
        return PushRegistration.alerts(serverId: self.connection.hello?.serverId ?? "")
    }

    func setPushAlerts(_ value: Bool) {
        guard let serverId = self.connection.hello?.serverId else {
            return
        }
        PushRegistration.setAlerts(value, serverId: serverId)
    }

    /// Tells the server this phone's tokens, again on each connection and when one changes.
    @objc private func registerDevice() {
        guard let hello = self.connection.hello, hello.apns else {
            return
        }
        self.connection.request("devices.register", PushRegistration.shared.registration(serverId: hello.serverId)) { _ in }
    }

    /// What the Live Activity shows of this server's chats, for the server to update it while tau is away; nil:
    /// none. Sent now, or once connected.
    private var liveActivity: JSONObject??
    private var liveActivitySent = true
    private var pendingActivityStart: (rows: [JSONObject], accent: UInt32?, completion: (Bool) -> Void)?

    func setLiveActivity(_ activity: JSONObject?) {
        self.liveActivity = .some(activity)
        self.liveActivitySent = false
        self.sendLiveActivity()
    }

    /// Tau is away and cannot start an activity itself: the server starts one (or updates its own) with these rows.
    func startLiveActivity(rows: [JSONObject], accent: UInt32?, completion: @escaping (Bool) -> Void) {
        self.pendingActivityStart = (rows, accent, completion)
        self.sendLiveActivity()
    }

    private func sendLiveActivity() {
        guard let hello = self.connection.hello, hello.apns else {
            return
        }
        let deviceId = PushRegistration.shared.deviceId
        if !self.liveActivitySent, let activity = self.liveActivity {
            self.liveActivitySent = true
            let sent = activity
            self.connection.request("liveActivity.update", ["deviceId": deviceId, "activity": sent ?? NSNull()]) { [weak self] result in
                if case .failure = result, let self, self.liveActivity.map({ ($0 as NSDictionary?) == (sent as NSDictionary?) }) == true {
                    self.liveActivitySent = false
                }
            }
        }
        if let start = self.pendingActivityStart {
            self.pendingActivityStart = nil
            var params: JSONObject = ["deviceId": deviceId, "rows": start.rows]
            if let accent = start.accent {
                params["accent"] = Int(accent)
            }
            self.connection.request("liveActivity.start", params) { [weak self] result in
                switch result {
                case let .success(value):
                    start.completion(value.string("result") != "none")
                case .failure:
                    // Once connected again.
                    self?.pendingActivityStart = start
                }
            }
        }
    }

    /// Back in the foreground: a socket that died while suspended is found out at once, not at the next ping.
    @objc private func didBecomeActive() {
        self.wake()
        self.sendPresence()
    }

    /// Back in the foreground, or woken in the background for a notification's reply: the socket is checked, or
    /// replaced when the server has closed it by now, and what waits to be sent goes.
    func wake() {
        self.connection.wake()
        self.outbox.pump()
    }

    @objc private func willResignActive() {
        self.sendPresence(active: false)
        for id in Array(self.readTimers.keys) {
            self.sendRead(id)
        }
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
        outbox.transfer = self.transfer
        outbox.maxFileBytes = { [weak self] in
            return self?.connection.hello?.maxFileBytes ?? 0
        }
        outbox.fileImage = { [weak self] id, mimeType, bytes, size in
            return self?.media.fileImage(id: id, mimeType: mimeType, bytes: bytes, pixelSize: size)
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
            // Its photos are here already: the entry's references need no fetch.
            for photo in outbox.photoData(requestId) {
                self.media.seed(fileId: photo.fileId, data: photo.data)
            }
        }
        outbox.restored = { [weak self] id, text in
            self?.emit(id, .restoreInput(text))
        }
        outbox.notice = { [weak self] id, text in
            self?.emit(id, .notice(text))
        }
        outbox.created = { [weak self] create, raw in
            guard let self, let dialog = self.takeDialog(raw) else {
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

    private var defaultThinkingOverride: String?

    var defaultThinkingLevel: String {
        return self.defaultThinkingOverride ?? self.connection.hello?.defaultThinkingLevel ?? "off"
    }

    func setDefaultThinkingLevel(_ level: String) {
        self.defaultThinkingOverride = level
        self.connection.request("settings.configure", ["defaultThinkingLevel": level]) { _ in }
        self.infoChanged?()
    }

    private var cacheWarmingOverride: String?

    var cacheWarming: String {
        return self.cacheWarmingOverride ?? self.connection.hello?.cacheWarming ?? "idle"
    }

    func setCacheWarming(_ mode: String) {
        self.cacheWarmingOverride = mode
        self.connection.request("settings.configure", ["cacheWarming": mode]) { _ in }
        self.infoChanged?()
    }

    private var compactionOverride: CompactionThreshold?

    var compaction: CompactionThreshold {
        return self.compactionOverride ?? self.connection.hello?.compaction ?? .standard
    }

    func setCompaction(_ threshold: CompactionThreshold) {
        self.compactionOverride = threshold
        self.connection.request("settings.configure", ["compaction": threshold.json]) { _ in }
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
        self.cacheWarmingOverride = nil
        self.compactionOverride = nil
        self.sendPresence()
        self.registerDevice()
        self.sendLiveActivity()
        self.infoChanged?()
        self.readSent.removeAll()
        if self.cache.serverId != hello.serverId {
            // Another database: nothing cached is valid. Its conversations and entries reuse the IDs, so images and
            // drafts kept by them go too.
            if self.cache.serverId != nil {
                self.inputDrafts.removeConversationDrafts()
            }
            self.media.clear()
            self.preloadedThrough = [:]
            self.cache.reset(serverId: hello.serverId)
            if !self.pendingHides.isEmpty {
                self.pendingHides = [:]
                self.savePendingHides()
            }
            for replica in self.replicas.values {
                replica.upsertReset()
            }
            self.serverDialogs = [:]
            self.dialogsVersion = nil
            self.forkParents = [:]
        }
        self.connection.setStatus(.updating)
        // The usage row reads each model's context window from the list.
        if self.modelsCache == nil {
            let _ = self.models().start()
        }
        for (id, hidden) in self.pendingHides {
            self.sendHidden(id, hidden)
        }
        // Asked for behind the hello already, for this database; else now. A chat opened since is subscribed now.
        let speculated = self.speculatedServerId == hello.serverId
        if !speculated {
            self.syncDialogs(serverId: hello.serverId)
        }
        for id in self.replicas.keys where (self.watchers[id] ?? 0) > 0 && !(speculated && self.speculatedChats.contains(id)) {
            self.subscribe(id, serverId: hello.serverId)
        }
        self.speculatedServerId = nil
        self.speculatedChats = []
        self.outbox.connected(serverId: hello.serverId)
    }

    /// The socket is open and its hello on its way: the chat list's changes and the open chats' new entries are asked
    /// for in the same flight, for the database this device has cached. The server answers the hello first; if it says
    /// another database, `connected` drops the cache and asks again, and these answers are ignored.
    private func opened() {
        self.speculatedServerId = self.cache.serverId
        self.speculatedChats = []
        guard let serverId = self.cache.serverId else {
            return
        }
        self.syncDialogs(serverId: serverId)
        for id in self.replicas.keys where (self.watchers[id] ?? 0) > 0 {
            self.subscribe(id, serverId: serverId)
            self.speculatedChats.insert(id)
        }
    }

    /// The chat list: what changed since the version this device has, or all of it (docs/protocol.md).
    private func syncDialogs(serverId: String) {
        var params: JSONObject = [:]
        if let version = self.dialogsVersion {
            params["since"] = version
        }
        self.connection.request("dialogs.subscribe", params) { [weak self] result in
            guard let self, case let .success(value) = result, self.connection.hello?.serverId == serverId else {
                return
            }
            if value.bool("full") ?? true {
                self.serverDialogs = [:]
            }
            for raw in value.objects("dialogs") {
                if let id = raw.object("conversation")?.int("id") {
                    self.serverDialogs[id] = raw
                }
            }
            self.dialogsVersion = value.string("version")
            var updated: [Int: DialogModel] = [:]
            for raw in self.serverDialogs.values {
                if let dialog = self.dialogModel(raw) {
                    updated[dialog.id] = dialog
                }
            }
            self.dialogs = updated
            self.saveDialogsSoon()
            self.publishDialogs()
            self.connection.setStatus(.online)
        }
    }

    /// A Dialog from the server (a push, a create's or fork's answer): kept as it came, then as the app shows it.
    private func takeDialog(_ raw: JSONObject, version: String? = nil) -> DialogModel? {
        guard let id = raw.object("conversation")?.int("id") else {
            return nil
        }
        self.serverDialogs[id] = raw
        if let version {
            self.dialogsVersion = version
        }
        self.saveDialogsSoon()
        return self.dialogModel(raw)
    }

    /// The chat list on disk a moment after it last changed, with its version.
    private func saveDialogsSoon() {
        guard self.dialogsSaveTimer == nil else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: false, completion: { [weak self] in
            guard let self else {
                return
            }
            self.dialogsSaveTimer = nil
            self.cache.saveDialogs(Array(self.serverDialogs.values), version: self.dialogsVersion)
        }, queue: Queue.mainQueue())
        self.dialogsSaveTimer = timer
        timer.start()
    }

    private func handlePush(_ push: JSONObject) {
        switch push.string("event") {
        case "dialog":
            if let raw = push.object("dialog"), var dialog = self.takeDialog(raw, version: push.string("version")) {
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
                let content = entry.value.objects("model").first?["content"]
                let (text, images) = TranscriptBuilder.userContent(content)
                // Its photos and files, as the outbox counts them.
                let files = TranscriptBuilder.attachmentLines(content)
                return (entry.key, text, files.isEmpty ? images.count : files.count)
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
        if let parent = conversation.object("parent"), let parentId = parent.int("conversationId"), let at = parent.int("at") {
            self.forkParents[id] = (parentId, at)
        }
        if let cache = raw.object("cache") {
            // The entry comes only while it is the conversation's model's; the refresh counters always.
            let entry = cache.double("at").flatMap { at in cache.double("ttl").map { (at: at, ttl: $0) } }
            self.promptCaches[id] = PromptCache(at: entry.map { Date(timeIntervalSince1970: $0.at / 1000.0) }, ttl: entry.map { $0.ttl / 1000.0 }, warming: cache.bool("warming") ?? false, until: cache.double("until").map { Date(timeIntervalSince1970: $0 / 1000.0) }, warms: cache.int("warms") ?? 0, cost: cache.double("cost") ?? 0.0, saved: cache.double("saved") ?? 0.0)
        } else {
            self.promptCaches[id] = nil
        }
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
            model: model,
            last: last,
            busy: raw.bool("busy") ?? false,
            unreadCount: raw.int("unreadCount") ?? 0,
            markedUnread: raw.bool("markedUnread") ?? false,
            archived: raw.bool("archived") ?? false
        )
        dialog.hidden = self.pendingHides[id] ?? raw.bool("hidden") ?? false
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
            let files = latest.uploads.filter { $0.kind == .file }
            if let first = files.first {
                text = files.count > 1 ? "\(files.count) Files" : first.name
            } else {
                text = latest.photoCount > 1 ? "\(latest.photoCount) Photos" : "Photo"
            }
        }
        return DialogModel.Outgoing(text: text, date: latest.date, failed: self.hasFailedMessage(id))
    }

    private func publishDialogs() {
        for id in Array(self.dialogs.keys) {
            self.dialogs[id]?.hasFailedMessage = self.hasFailedMessage(id)
            self.dialogs[id]?.outgoing = self.outgoingSummary(id)
            self.dialogs[id]?.draft = self.inputDrafts.draft(String(id))
        }
        // Each chat's subagents that work, or whose own subagents do, at any depth: by the name of its own subagent.
        var working: [Int: Set<String>] = [:]
        for dialog in self.dialogs.values where dialog.busy {
            var child = dialog
            var depth = 0
            while let parentId = child.parentConversationId, depth < 16 {
                // Background subagents are titled "name: task".
                working[parentId, default: []].insert(child.title.components(separatedBy: ":").first ?? child.title)
                guard let parent = self.dialogs[parentId] else {
                    break
                }
                child = parent
                depth += 1
            }
        }
        for id in Array(self.dialogs.keys) {
            self.dialogs[id]?.workingSubagents = (working[id] ?? []).sorted()
        }
        let visible = self.dialogs.values.filter { $0.parentConversationId == nil && !$0.hidden }
        let sorted = visible.sorted { lhs, rhs in
            let l = lhs.last?.id ?? self.dialogOrder[lhs.id] ?? lhs.id
            let r = rhs.last?.id ?? self.dialogOrder[rhs.id] ?? rhs.id
            return l > r
        }
        self.dialogsPromise.set(sorted)
        self.schedulePreload()
    }

    // MARK: - Preloading

    /// The chats at the top of the list, as Telegram's ChatHistoryPreloadManager keeps the top of its list: how many.
    private static let preloadedChats = 30
    private var preloadTimer: SwiftSignalKit.Timer?
    private var preloadQueue: [(id: Int, lastId: Int)] = []
    private var isPreloading = false
    /// The newest message each chat's cache was brought up to, by this preloading or found there.
    private var preloadedThrough: [Int: Int] = [:]

    /// A second after the list changes, as Telegram waits: the chats at its top whose cache is behind their newest
    /// message get their new entries fetched, one at a time, so opening one shows it at once. Not while connecting,
    /// and at most once a second while chats change.
    private func schedulePreload() {
        guard self.preloadTimer == nil, self.connection.hello != nil else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: false, completion: { [weak self] in
            guard let self else {
                return
            }
            self.preloadTimer = nil
            self.startPreload()
        }, queue: Queue.mainQueue())
        self.preloadTimer = timer
        timer.start()
    }

    private func startPreload() {
        // The list's order, pinned first; not the archive, nor a subagent's chat. A working chat waits for its answer:
        // its entries are still coming, and it is fetched once it ends.
        let listed = self.dialogs.values.filter { $0.parentConversationId == nil && !$0.archived && !$0.hidden }
        let ordered = listed.sorted { lhs, rhs in
            if (lhs.pinned != nil) != (rhs.pinned != nil) {
                return lhs.pinned != nil
            }
            if let l = lhs.pinned, let r = rhs.pinned, l != r {
                return l > r
            }
            return (lhs.last?.id ?? 0) > (rhs.last?.id ?? 0)
        }
        self.preloadQueue = ordered.prefix(ServerStore.preloadedChats).compactMap { dialog in
            guard let lastId = dialog.last?.id, !dialog.busy, (self.preloadedThrough[dialog.id] ?? 0) < lastId else {
                return nil
            }
            return (dialog.id, lastId)
        }
        if !self.isPreloading {
            self.preloadNext()
        }
    }

    private func preloadNext() {
        guard !self.preloadQueue.isEmpty, self.connection.hello != nil else {
            self.isPreloading = false
            return
        }
        self.isPreloading = true
        let (id, lastId) = self.preloadQueue.removeFirst()
        if (self.watchers[id] ?? 0) > 0 {
            // Open: its subscription brings everything.
            self.preloadNext()
        } else if let replica = self.replicas[id] {
            self.preload(id, after: replica.maxId, through: lastId)
        } else {
            self.cache.maxId(id) { [weak self] maxId in
                self?.preload(id, after: maxId, through: lastId)
            }
        }
    }

    /// The entries after `after`, the cache's newest, into the cache: in memory when the chat was opened this run, on
    /// disk otherwise. More than a hundred missing is a gap, and the newest hundred replace the cache, as a subscribe's
    /// gap does.
    private func preload(_ id: Int, after: Int?, through lastId: Int) {
        if let after, after >= lastId {
            self.preloadedThrough[id] = lastId
            self.preloadNext()
            return
        }
        var params: JSONObject = ["conversationId": id, "limit": 100]
        if let after {
            params["after"] = after
        }
        self.connection.request("conversation.history", params) { [weak self] result in
            guard let self else {
                return
            }
            guard case let .success(value) = result else {
                // Offline, or an older server: the next connection's list starts again.
                self.preloadQueue = []
                self.isPreloading = false
                return
            }
            let entries = value.objects("entries")
            let hasOlder = value.bool("hasOlder") ?? false
            let replacing = after == nil || hasOlder
            if (self.watchers[id] ?? 0) > 0 {
                // Opened meanwhile: its subscribe brings these too.
            } else if let replica = self.replicas[id] {
                if replacing {
                    replica.removeAll()
                    replica.hasOlder = hasOlder
                }
                replica.upsert(entries)
                self.cache.scheduleSave(replica)
            } else {
                self.cache.merge(id, entries: entries, replacing: replacing, hasOlder: hasOlder)
            }
            self.preloadedThrough[id] = lastId
            self.preloadNext()
        }
    }

    func dialogsSignal() -> Signal<[DialogModel], NoError> {
        return self.dialogsPromise.get()
    }

    func dialog(_ id: Int) -> DialogModel? {
        if let draft = self.drafts[id] {
            if let realId = draft.realId, let dialog = self.dialogs[realId] {
                return dialog
            }
            let model = self.agent(id).modelId ?? ""
            return DialogModel(id: id, title: draft.title ?? "New chat", model: model, last: nil, busy: false)
        }
        return self.dialogs[id]
    }

    // MARK: - Conversations

    /// A draft's conversation once it is created; another ID as it is.
    func realId(_ id: Int) -> Int? {
        return self.resolve(id)
    }

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
                var state = TranscriptBuilder.build(replica: preview, outbox: self.outbox, rowIdForUserEntry: self.rowIdForUserEntry[forkOf] ?? [:], media: self.media)
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
        var state = TranscriptBuilder.build(replica: replica, outbox: self.outbox, rowIdForUserEntry: self.rowIdForUserEntry[realId] ?? [:], media: self.media)
        state.agent = self.agent(realId)
        state.title = self.dialog(id)?.title
        // Until the subscribe brings the docs (a chat opened from the cache, or again after it was left): the list's
        // word for whether it works.
        if !replica.isSynced, self.dialogs[realId]?.busy == true {
            state.busy = true
        }
        // A background subagent works on after its call returned: its card follows its conversation.
        for index in state.messages.indices {
            if let child = state.messages[index].tool?.childConversationId, let busy = self.dialogs[child]?.busy, busy != state.messages[index].tool?.childBusy {
                state.messages[index].tool?.childBusy = busy
                if let prefix = state.stablePrefix, index < prefix.count {
                    state.stablePrefix?.count = index
                }
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
            self.replicas[id]?.docsAreStale = true
            self.connection.request("conversation.unsubscribe", ["conversationId": id]) { _ in }
        }
    }

    /// `conversation.subscribe` for entries after the newest cached one, then live commits. `serverId`: the database it
    /// is for, when it may go before the hello says which (`opened`).
    private func subscribe(_ id: Int, serverId: String? = nil) {
        let replica = self.replica(id)
        replica.isSynced = false
        self.seedFork(replica)
        var params: JSONObject = ["conversationId": id, "limit": 100]
        if let after = replica.maxId {
            params["after"] = after
        }
        self.connection.request("conversation.subscribe", params) { [weak self] result in
            guard let self, case let .success(value) = result, serverId == nil || self.connection.hello?.serverId == serverId else {
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
            replica.docsAreStale = false
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

    /// A fork with nothing cached starts from what this device has of the conversation it was made from: the entries up
    /// to the fork's point are the same ones, by the same IDs (entries are global and never change). Its subscribe then
    /// brings only what comes after them, as an edit's fork brings little more than the edited message.
    private func seedFork(_ replica: ConversationReplica) {
        guard replica.entries.isEmpty, let fork = self.forkParents[replica.id] else {
            return
        }
        let parent: (entries: [JSONObject], hasOlder: Bool)?
        if let loaded = self.replicas[fork.conversationId], !loaded.entries.isEmpty {
            parent = (loaded.ordered(), loaded.hasOlder)
        } else {
            parent = self.cache.load(fork.conversationId)
        }
        guard let parent else {
            return
        }
        let inherited = parent.entries.filter { ($0.int("id") ?? Int.max) <= fork.at }
        guard !inherited.isEmpty else {
            return
        }
        replica.upsert(inherited)
        replica.hasOlder = parent.hasOlder
    }

    private func publish(_ realId: Int) {
        let state = self.state(for: realId)
        self.statePromises[realId]?.set(state)
        for (draftId, draft) in self.drafts where draft.realId == realId {
            self.statePromises[draftId]?.set(state)
        }
    }

    func loadHistory(_ id: Int, through entryId: Int) {
        guard let realId = self.resolve(id), let replica = self.replicas[realId], replica.hasOlder, let oldest = replica.minId, oldest > entryId else {
            return
        }
        // In pages, each from the oldest loaded, so the transcript stays without gaps.
        self.connection.request("conversation.history", ["conversationId": realId, "before": oldest, "limit": 500]) { [weak self] result in
            guard let self, case let .success(value) = result else {
                return
            }
            replica.upsert(value.objects("entries"))
            replica.hasOlder = value.bool("hasOlder") ?? false
            self.publish(realId)
            self.cache.scheduleSave(replica)
            if replica.hasOlder, let oldest = replica.minId, oldest > entryId {
                self.loadHistory(id, through: entryId)
            }
        }
    }

    func search(_ query: String, typing: Bool, offset: Int) -> Signal<SearchPage, NoError> {
        return self.search(query, typing: typing, offset: offset, limit: 20)
    }

    /// Nothing from a server that cannot answer: search shows what the others found.
    func search(_ query: String, typing: Bool, offset: Int, limit: Int) -> Signal<SearchPage, NoError> {
        return self.connection.request("search", ["query": query, "typing": typing, "offset": offset, "limit": limit])
        |> map { value -> SearchPage in
            let matches = value.objects("results").compactMap { result -> SearchMatch? in
                guard let conversationId = result.int("conversationId"), let hit = result.objects("hits").first else {
                    return nil
                }
                let ranges = (hit.array("ranges") ?? []).compactMap { pair -> NSRange? in
                    guard let values = pair as? [NSNumber], values.count == 2 else {
                        return nil
                    }
                    return NSRange(location: values[0].intValue, length: values[1].intValue - values[0].intValue)
                }
                return SearchMatch(conversationId: conversationId, entryId: hit.int("entryId"), kind: SearchMatch.Kind(rawValue: hit.string("kind") ?? "") ?? .assistant, text: hit.string("text") ?? "", ranges: ranges, date: Date(timeIntervalSince1970: (hit.double("time") ?? 0.0) / 1000.0), before: hit.bool("before") ?? false, after: hit.bool("after") ?? false, matches: result.int("matches") ?? 0, score: result.double("score") ?? 0.0)
            }
            let total = value.int("total") ?? matches.count
            return SearchPage(matches: matches, hasMore: offset + matches.count < total, terms: ServerStore.searchTerms(value))
        }
        |> `catch` { _ -> Signal<SearchPage, NoError> in
            return .single(SearchPage(matches: [], hasMore: false, terms: []))
        }
        |> deliverOnMainQueue
    }

    func searchConversation(_ id: Int, query: String, typing: Bool) -> Signal<ChatSearchResult, NoError> {
        guard let realId = self.resolve(id) else {
            return .single(ChatSearchResult(entryIds: [], terms: []))
        }
        return self.connection.request("search", ["query": query, "typing": typing, "conversationId": realId])
        |> map { value -> ChatSearchResult in
            return ChatSearchResult(entryIds: value.objects("hits").compactMap { $0.int("entryId") }, terms: ServerStore.searchTerms(value))
        }
        |> `catch` { _ -> Signal<ChatSearchResult, NoError> in
            return .single(ChatSearchResult(entryIds: [], terms: []))
        }
        |> deliverOnMainQueue
    }

    private static func searchTerms(_ value: JSONObject) -> [SearchTerm] {
        return value.objects("terms").map { term in
            SearchTerm(tokens: (term.array("tokens") ?? []).compactMap { $0 as? String }, prefix: term.bool("prefix") ?? false, variants: (term.array("variants") ?? []).compactMap { $0 as? String })
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

    /// What one of a conversation's entries says, for a link to it (docs/links.md): the phone's copy, else the server's.
    func linkedEntryText(_ realId: Int, entryId: Int, completion: @escaping (String?) -> Void) {
        if let text = self.linkedEntryTexts[entryId] {
            completion(text)
            return
        }
        if let entry = self.replicas[realId]?.entries[entryId] {
            let text = TranscriptBuilder.quotedText(entry)
            self.linkedEntryTexts[entryId] = text
            completion(text)
            return
        }
        self.connection.request("conversation.history", ["conversationId": realId, "before": entryId + 1, "limit": 1]) { [weak self] result in
            guard case let .success(value) = result, let entry = value.objects("entries").first(where: { $0.int("id") == entryId }) else {
                completion(nil)
                return
            }
            let text = TranscriptBuilder.quotedText(entry)
            self?.linkedEntryTexts[entryId] = text
            completion(text)
        }
    }

    /// When its latest chat was last written in: which server New Chat starts on.
    var lastActivity: Date? {
        return self.dialogs.values.compactMap { $0.parentConversationId == nil ? $0.last?.date : nil }.max()
    }

    func createConversation() -> Int {
        let id = self.nextDraftId
        self.nextDraftId -= 1
        self.drafts[id] = Draft()
        return id
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
        if let replica = self.replicas[realId], replica.isBusy || (replica.docsAreStale && self.dialogs[realId]?.busy == true) {
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
                // answer; photos alone as Telegram's list names them.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = draft.titleIsManual ? (draft.title ?? "") : (trimmed.isEmpty ? attachmentsTitle(attachments) : String(trimmed.prefix(48)))
                if let forkOf = draft.forkOf, let forkAt = draft.forkAt {
                    // A copy made before its message (Restore Full Context): the fork, then the message.
                    self.outbox.enqueueCreate(requestId: createRequestId, title: draft.title ?? title, agent: nil, forkOf: forkOf, forkAt: forkAt)
                } else {
                    self.outbox.enqueueCreate(requestId: createRequestId, title: title, agent: draft.agent)
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

    /// `attachments` with the server's images fetched, as photos to send again; at once when there are none.
    private func resolvingRemote(_ attachments: [MessageAttachment], completion: @escaping ([MessageAttachment]) -> Void) {
        // A photo the server keeps as a file goes again by its ID; one sent before files were kept is fetched.
        let remote = attachments.compactMap { attachment -> (Int, RemoteImage)? in
            if case let .remote(image) = attachment.kind, image.fileId == nil {
                return (attachment.id, image)
            }
            return nil
        }
        guard !remote.isEmpty else {
            completion(attachments)
            return
        }
        let _ = (combineLatest(remote.map { $0.1.data() }) |> take(1) |> deliverOnMainQueue).start(next: { datas in
            var images: [Int: UIImage] = [:]
            for ((id, _), data) in zip(remote, datas) {
                images[id] = data.flatMap { UIImage(data: $0) }
            }
            completion(attachments.compactMap { attachment in
                guard case .remote = attachment.kind, images.keys.contains(attachment.id) || remote.contains(where: { $0.0 == attachment.id }) else {
                    return attachment
                }
                return images[attachment.id].map { MessageAttachment(id: attachment.id, kind: .image($0)) }
            })
        })
    }

    /// `attachments`: the edited message's, its own and any added while editing. Its own photos, on the server, are
    /// fetched to go with the edit.
    func edit(messageId: Int, text: String, attachments: [MessageAttachment], in id: Int, completion: @escaping (Int) -> Void) {
        self.resolvingRemote(attachments) { [weak self] resolved in
            self?.editResolved(messageId: messageId, text: text, attachments: resolved, in: id, completion: completion)
        }
    }

    private func editResolved(messageId: Int, text: String, attachments: [MessageAttachment], in id: Int, completion: @escaping (Int) -> Void) {
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
            // Editing the first message: a fresh conversation with the same model.
            let draftId = self.createConversation()
            self.drafts[draftId]?.agent = self.agent(realId)
            self.send(text, attachments: attachments, to: draftId)
            completion(draftId)
            return
        }
        let draftId = self.nextDraftId
        self.nextDraftId -= 1
        let createRequestId = UUID().uuidString
        var draft = Draft()
        draft.agent = self.agent(realId)
        draft.forkOf = realId
        draft.forkAt = at
        draft.title = parent?.title ?? "Edited"
        draft.createRequestId = createRequestId
        self.drafts[draftId] = draft
        self.outbox.enqueueCreate(requestId: createRequestId, title: draft.title ?? "Edited", agent: nil, forkOf: realId, forkAt: at)
        self.outbox.enqueue(text: text, attachments: attachments, conversationId: nil, createRequestId: createRequestId, mode: .followUp, showsInQueue: false)
        completion(draftId)
    }

    func forkBefore(entryId: Int, in id: Int) -> Int? {
        guard let realId = self.resolve(id), let replica = self.replicas[realId], let at = replica.entries.keys.filter({ $0 < entryId }).max() else {
            return nil
        }
        // Created by its first message, through the outbox, as any draft: leaving it unsent leaves nothing behind.
        let draftId = self.nextDraftId
        self.nextDraftId -= 1
        var draft = Draft()
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
            guard let self, case let .success(value) = result, let raw = value.object("dialog"), let dialog = self.takeDialog(raw) else {
                return
            }
            self.dialogs[dialog.id] = dialog
            self.publishDialogs()
            completion(dialog.id)
        }
    }

    /// The last entry each conversation was marked read at from here, so a repeat is not sent.
    private var readSent: [Int: Int] = [:]
    /// Reads go at most every `readInterval` per chat, the first at once: a chat on screen while an answer comes reads
    /// each entry, and one read of the newest a moment later says the same. The newest waiting, and when one went.
    private var readPending: [Int: Int] = [:]
    private var readTimers: [Int: SwiftSignalKit.Timer] = [:]
    private var readSentAt: [Int: CFAbsoluteTime] = [:]
    private static let readInterval: Double = 2.0

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
        self.readPending[realId] = latest
        if self.readTimers[realId] == nil {
            let wait = (self.readSentAt[realId] ?? 0.0) + ServerStore.readInterval - CFAbsoluteTimeGetCurrent()
            if wait <= 0.0 {
                self.sendRead(realId)
            } else {
                let timer = SwiftSignalKit.Timer(timeout: wait, repeat: false, completion: { [weak self] in
                    self?.sendRead(realId)
                }, queue: Queue.mainQueue())
                self.readTimers[realId] = timer
                timer.start()
            }
        }
    }

    /// The newest read waiting for a chat, now.
    private func sendRead(_ id: Int) {
        self.readTimers.removeValue(forKey: id)?.invalidate()
        guard let at = self.readPending.removeValue(forKey: id) else {
            return
        }
        self.readSentAt[id] = CFAbsoluteTimeGetCurrent()
        self.connection.request("conversation.read", ["conversationId": id, "at": at]) { _ in }
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

    func fileStatus(_ file: FileAttachment, in id: Int) -> Signal<FileTransferStatus, NoError> {
        if let key = file.transferKey, file.serverId == nil {
            // On its way up: its upload's progress, and at rest the device's copy.
            let local = file.localURL
            return self.transfer.status(key) |> map { status -> FileTransferStatus in
                if case .remote = status, let local {
                    return .local(local)
                }
                return status
            }
        }
        guard let serverId = file.serverId else {
            return .single(file.localURL.map { .local($0) } ?? .remote)
        }
        return self.transfer.status(serverId)
    }

    func downloadFile(_ file: FileAttachment, in id: Int) {
        self.transfer.download(file)
    }

    func cancelFileDownload(_ file: FileAttachment, in id: Int) {
        if let serverId = file.serverId {
            self.transfer.cancelDownload(serverId)
        }
    }

    func setArchived(_ id: Int, _ archived: Bool) {
        guard let realId = self.resolve(id) else {
            return
        }
        self.dialogs[realId]?.archived = archived
        self.publishDialogs()
        self.connection.request("conversation.mark", ["conversationId": realId, "archived": archived]) { _ in }
    }

    /// Hide, on every device: the server keeps the conversation (durable deletes none) and leaves it out of every list
    /// and search. Shown at once here, and pending until the server has it.
    func setHidden(_ id: Int, _ hidden: Bool) {
        guard let realId = self.resolve(id) else {
            return
        }
        self.pendingHides[realId] = hidden
        self.savePendingHides()
        self.dialogs[realId]?.hidden = hidden
        self.publishDialogs()
        self.sendHidden(realId, hidden)
    }

    private func sendHidden(_ id: Int, _ hidden: Bool) {
        self.connection.request("conversation.mark", ["conversationId": id, "hidden": hidden]) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success:
                break
            case let .failure(error) where error.code == "disconnected" || error.code == "timeout":
                // Sent again on the next connection.
                return
            case .failure:
                // The server will not take it (no such conversation): nothing to wait for.
                break
            }
            // Only the latest wish: an Undo sent meanwhile waits for its own answer.
            if self.pendingHides[id] == hidden {
                self.pendingHides[id] = nil
                self.savePendingHides()
            }
        }
    }

    private func savePendingHides() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: self.pendingHides.map { (String($0.key), $0.value) }), forKey: "hides.\(self.connection.url.absoluteString)")
    }

    // MARK: - Agent

    private var modelsCache: [ModelInfo]?

    func storageUsage() -> StorageUsage {
        var usage = StorageUsage()
        usage.chats = self.cache.sizes().sorted { $0.bytes > $1.bytes }
        usage.unsentBytes = self.outbox.diskBytes
        usage.draftBytes = self.inputDrafts.diskBytes
        usage.mediaBytes = self.media.diskBytes
        usage.fileBytes = self.transfer.diskBytes
        return usage
    }

    func clearCache() {
        // Open chats keep theirs: their transcripts are on screen and in memory.
        let open = Set(self.watchers.filter { $0.value > 0 }.map(\.key))
        self.cache.remove(except: open)
        self.preloadedThrough = [:]
        self.media.clear()
        self.transfer.clear()
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
        return ConversationUsage(models: models, contextTokens: contextTokens, contextWindow: contextWindow, cache: self.promptCaches[realId])
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

    func usageReport(days: Int) -> Signal<UsageReport?, NoError> {
        let slot = self.slot
        return self.connection.request("usage.report", ["days": days, "tzOffset": TimeZone.current.secondsFromGMT() / 60])
        |> map { value -> UsageReport? in
            return UsageReport(value, globalId: { MultiStore.global(slot, $0) })
        }
        |> `catch` { _ -> Signal<UsageReport?, NoError> in
            return .single(nil)
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

/// Entries per conversation in Caches, as JSON. Entries never change, so a cached one is always right; a different
/// `serverId` drops everything.
final class EntryCache {
    private let directory: URL
    private var saveTimers: [Int: SwiftSignalKit.Timer] = [:]
    private(set) var serverId: String?
    /// Every read and write of a transcript file, in order: a chat's save, a preload's merge and a reset never interleave,
    /// and a load sees what was queued before it.
    private let io = DispatchQueue(label: "tau.entry-cache", qos: .utility)
    /// The newest entries a file keeps.
    private static let keptEntries = 300

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
        self.io.sync {
            for (id, _) in self.sizes() where !kept.contains(id) {
                try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("\(id).json"))
            }
        }
    }

    func reset(serverId: String) {
        self.io.sync {
            try? FileManager.default.removeItem(at: self.directory)
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try? serverId.write(to: self.directory.appendingPathComponent("server-id"), atomically: true, encoding: .utf8)
        }
        self.serverId = serverId
    }

    func load(_ id: Int) -> (entries: [JSONObject], hasOlder: Bool)? {
        return self.io.sync {
            self.read(id)
        }
    }

    private func read(_ id: Int) -> (entries: [JSONObject], hasOlder: Bool)? {
        guard let data = try? Data(contentsOf: self.directory.appendingPathComponent("\(id).json")), let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            return nil
        }
        return (object.objects("entries"), object.bool("hasOlder") ?? true)
    }

    private func write(_ id: Int, entries: [JSONObject], hasOlder: Bool) {
        if let data = try? JSONSerialization.data(withJSONObject: ["entries": entries, "hasOlder": hasOlder]) {
            try? data.write(to: self.directory.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }

    /// The newest entry ID a conversation's file has, read off the main queue; nil without one.
    func maxId(_ id: Int, completion: @escaping (Int?) -> Void) {
        self.io.async {
            let maxId = self.read(id)?.entries.compactMap { $0.int("id") }.max()
            DispatchQueue.main.async {
                completion(maxId)
            }
        }
    }

    /// Adds a preload's entries to a conversation's file: after what it has, or in place of it (`replacing`, when there
    /// was a gap between the two, or nothing was cached). `hasOlder` is the server's when replacing.
    func merge(_ id: Int, entries: [JSONObject], replacing: Bool, hasOlder: Bool) {
        self.io.async {
            var byId: [Int: JSONObject] = [:]
            var older = hasOlder
            if !replacing, let cached = self.read(id) {
                older = cached.hasOlder
                for entry in cached.entries {
                    if let entryId = entry.int("id") {
                        byId[entryId] = entry
                    }
                }
            }
            for entry in entries {
                if let entryId = entry.int("id") {
                    byId[entryId] = entry
                }
            }
            let sorted = byId.keys.sorted()
            let kept = sorted.suffix(EntryCache.keptEntries).compactMap { byId[$0] }
            self.write(id, entries: kept, hasOlder: older || sorted.count > kept.count)
        }
    }

    /// Writes a conversation's newest entries a moment after the last change, off the main queue.
    func scheduleSave(_ replica: ConversationReplica) {
        self.saveTimers[replica.id]?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: false, completion: { [weak self, weak replica] in
            guard let self, let replica else {
                return
            }
            self.saveTimers[replica.id] = nil
            let entries = Array(replica.ordered().suffix(EntryCache.keptEntries))
            let hasOlder = replica.hasOlder || replica.entries.count > entries.count
            let id = replica.id
            self.io.async {
                self.write(id, entries: entries, hasOlder: hasOlder)
            }
        }, queue: Queue.mainQueue())
        self.saveTimers[replica.id] = timer
        timer.start()
    }

    /// The chat list as the server gave it, each Dialog as it came, with the version it is at.
    func saveDialogs(_ dialogs: [JSONObject], version: String?) {
        var object: JSONObject = ["dialogs": dialogs]
        if let version {
            object["version"] = version
        }
        self.io.async {
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                try? data.write(to: self.directory.appendingPathComponent("dialogs.json"), options: .atomic)
            }
        }
    }

    func loadDialogs() -> (dialogs: [JSONObject], version: String?) {
        return self.io.sync {
            guard let data = try? Data(contentsOf: self.directory.appendingPathComponent("dialogs.json")), let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
                return ([], nil)
            }
            return (object.objects("dialogs"), object.string("version"))
        }
    }
}

/// A message of attachments alone, as a title: "Photo", "3 Photos", or its file's name.
func attachmentsTitle(_ attachments: [MessageAttachment]) -> String {
    var photos = 0
    var file: String?
    for attachment in attachments {
        switch attachment.kind {
        case .image, .remote:
            photos += 1
        case let .file(attachment):
            file = file ?? attachment.name
        }
    }
    if photos > 0 {
        return photos == 1 ? "Photo" : "\(photos) Photos"
    }
    return file ?? "New chat"
}
