import UIKit
import SwiftSignalKit

/// Conversations synced with a tau server (docs/protocol.md). Keeps the dialog list subscribed, subscribes to a
/// conversation while a screen shows it, caches entries on disk so a reopened chat shows at once and a reconnect only
/// fetches what is new, and resends unacknowledged messages with their request IDs after a reconnect.
final class ServerStore: TauStore {
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
    private var pending: [Int: [PendingSend]] = [:]
    private var rowIdForUserEntry: [Int: [Int: Int]] = [:]
    private var nextLocalId = 1_000_000_000
    private var nextAttachmentId = 1

    /// Drafts: local negative IDs until the first message creates the conversation on the server.
    private struct Draft {
        var cwd: String?
        var realId: Int?
        var queued: [(String, [MessageAttachment])] = []
        var isCreating = false
    }
    private var drafts: [Int: Draft] = [:]
    private var nextDraftId = -1

    init(url: URL, token: String?) {
        self.connection = TauConnection(url: url, token: token)
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
        self.connection.start()
    }

    var connectionStatus: Signal<ConnectionStatus, NoError> {
        return self.connection.status
    }

    var serverDescription: String {
        return self.connection.url.host ?? self.connection.url.absoluteString
    }

    /// Set from Settings until the next `hello` reports it.
    private var defaultModelOverride: String?

    var defaultModel: String? {
        return self.defaultModelOverride ?? self.connection.hello?.defaultModel
    }

    func setDefaultModel(_ model: ModelInfo) {
        self.defaultModelOverride = "\(model.provider)/\(model.id)"
        self.connection.request("settings.configure", ["defaultModel": ["provider": model.provider, "modelId": model.id]]) { _ in }
    }

    func close() {
        self.connection.close()
    }

    // MARK: - Connection

    private func connected(_ hello: TauConnection.Hello) {
        self.defaultModelOverride = nil
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
        for (id, sends) in self.pending {
            for send in sends where send.submissionId == nil {
                self.submit(send, to: id)
            }
        }
    }

    private func handlePush(_ push: JSONObject) {
        switch push.string("event") {
        case "dialog":
            if let raw = push.object("dialog"), let dialog = self.dialogModel(raw) {
                self.dialogs[dialog.id] = dialog
                self.publishDialogs()
            }
        case "conv.commit":
            guard let id = push.int("conversationId"), let replica = self.replicas[id], replica.isSynced else {
                return
            }
            replica.apply(commit: push)
            self.settlePending(id)
            self.publish(id)
            self.cache.scheduleSave(replica)
        case "submission":
            guard let record = push.object("record"), let id = record.int("conversationId") else {
                return
            }
            self.updateSubmission(record, in: id)
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
        let model = agent.object("model")?.string("modelId") ?? self.defaultModel?.components(separatedBy: "/").last ?? ""
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
        // A read this device sent and the server has not reflected yet.
        if let sent = self.readSent[id], let last, sent >= last.id {
            dialog.unreadCount = 0
            dialog.markedUnread = false
        }
        return dialog
    }

    private func publishDialogs() {
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
            let model = self.defaultModel?.components(separatedBy: "/").last ?? ""
            return DialogModel(id: id, title: "New chat", cwd: cwd, model: model, last: nil, busy: false)
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
        guard let realId = self.resolve(id) else {
            let queued = self.drafts[id]?.queued ?? []
            let rows = queued.enumerated().map { ChatMessage(id: -1000 - $0.offset, role: .user, text: $0.element.0, date: Date(), attachments: $0.element.1, isPending: true) }
            return ConversationState(messages: rows, streaming: nil, busy: !rows.isEmpty)
        }
        let replica = self.replica(realId)
        return TranscriptBuilder.build(replica: replica, pending: self.pending[realId] ?? [], rowIdForUserEntry: self.rowIdForUserEntry[realId] ?? [:], images: self.images)
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
            }
            replica.isSynced = true
            self.settlePending(id)
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

    func discardIfDraft(_ id: Int) {
        if let draft = self.drafts[id], draft.realId == nil, draft.queued.isEmpty {
            self.drafts.removeValue(forKey: id)
            self.statePromises.removeValue(forKey: id)
        }
    }

    private func createDraftConversation(_ draftId: Int, title: String) {
        guard var draft = self.drafts[draftId], draft.realId == nil, !draft.isCreating else {
            return
        }
        draft.isCreating = true
        self.drafts[draftId] = draft
        // The first message stands in as the title until the server names the conversation after the first answer.
        var params: JSONObject = ["title": title, "autoTitle": true]
        if let cwd = draft.cwd {
            params["agent"] = ["cwd": cwd]
        }
        self.connection.request("conversation.create", params) { [weak self] result in
            guard let self, var draft = self.drafts[draftId] else {
                return
            }
            draft.isCreating = false
            guard case let .success(value) = result, let raw = value.object("dialog"), let dialog = self.dialogModel(raw) else {
                self.drafts[draftId] = draft
                // Retry once connected again.
                Queue.mainQueue().after(2.0) {
                    self.createDraftConversation(draftId, title: title)
                }
                return
            }
            draft.realId = dialog.id
            let queued = draft.queued
            draft.queued = []
            self.drafts[draftId] = draft
            self.dialogs[dialog.id] = dialog
            self.publishDialogs()
            if (self.statePromises[draftId] != nil) {
                self.watch(dialog.id)
            }
            for (text, attachments) in queued {
                self.send(text, attachments: attachments, to: dialog.id)
            }
            self.publish(dialog.id)
        }
    }

    // MARK: - Sending

    func send(_ text: String, attachments: [MessageAttachment], to id: Int) {
        if id < 0 {
            guard var draft = self.drafts[id] else {
                return
            }
            if let realId = draft.realId {
                self.send(text, attachments: attachments, to: realId)
                return
            }
            draft.queued.append((text, attachments))
            self.drafts[id] = draft
            self.statePromises[id]?.set(self.state(for: id))
            self.createDraftConversation(id, title: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)))
            return
        }
        let send = PendingSend(rowId: self.nextLocalId, requestId: UUID().uuidString, text: text, attachments: attachments, date: Date())
        self.nextLocalId += 1
        self.pending[id, default: []].append(send)
        self.publish(id)
        self.submit(send, to: id)
    }

    private func submit(_ send: PendingSend, to id: Int) {
        let content: Any
        let images = send.attachments.compactMap { attachment -> JSONObject? in
            guard case let .image(image) = attachment.kind, let data = ImageEncoding.jpeg(image) else {
                return nil
            }
            return ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]
        }
        let files = send.attachments.compactMap { attachment -> String? in
            guard case let .file(name, size) = attachment.kind else {
                return nil
            }
            return "[Attached file: \(name), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))]"
        }
        let text = ([send.text] + files).filter { !$0.isEmpty }.joined(separator: "\n")
        if images.isEmpty {
            content = text
        } else {
            content = (text.isEmpty ? [] : [["type": "text", "text": text]]) + images
        }
        self.connection.request("conversation.submit", ["conversationId": id, "requestId": send.requestId, "content": content, "whenBusy": "followUp"]) { [weak self] result in
            guard let self, case let .success(value) = result, let record = value.object("submission") else {
                // Resent with the same request ID on reconnect; the server answers with the existing submission.
                return
            }
            if let index = self.pending[id]?.firstIndex(where: { $0.requestId == send.requestId }) {
                self.pending[id]?[index].submissionId = record.int("id")
            }
            self.updateSubmission(record, in: id)
        }
    }

    private func updateSubmission(_ record: JSONObject, in id: Int) {
        guard let submissionId = record.int("id") else {
            return
        }
        self.replicas[id]?.submissions[submissionId] = record
        guard let index = self.pending[id]?.firstIndex(where: { $0.submissionId == submissionId || $0.requestId == record.string("requestId") }) else {
            return
        }
        self.pending[id]?[index].submissionId = submissionId
        if let entryId = record.int("entry") {
            self.pending[id]?[index].entryId = entryId
            self.rowIdForUserEntry[id, default: [:]][entryId] = self.pending[id]?[index].rowId
        }
        switch record.string("status") {
        case "unanswered", "done":
            if self.pending[id]?[index].entryId == nil {
                self.pending[id]?.remove(at: index)
            }
        default:
            break
        }
        self.settlePending(id)
        self.publish(id)
    }

    /// Pending sends whose entry has arrived are now ordinary rows.
    private func settlePending(_ id: Int) {
        guard let replica = self.replicas[id], var sends = self.pending[id] else {
            return
        }
        sends.removeAll { send in
            guard let entryId = send.entryId else {
                return false
            }
            return replica.entries[entryId] != nil
        }
        self.pending[id] = sends
    }

    func abort(_ id: Int) {
        guard let realId = self.resolve(id) else {
            return
        }
        self.connection.request("conversation.abort", ["conversationId": realId]) { _ in }
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
        // Fork at the entry before the edited message, so the fork's transcript ends just before it.
        guard let at = replica.entries.keys.filter({ $0 < entryId }).max() else {
            // Editing the first message: a fresh conversation in the same directory.
            let draft = self.createConversation(cwd: self.dialogs[realId]?.cwd)
            self.send(text, attachments: message.attachments, to: draft)
            completion(draft)
            return
        }
        let title = self.dialogs[realId]?.title ?? "Edited"
        self.connection.request("conversation.fork", ["conversationId": realId, "at": at, "title": title]) { [weak self] result in
            guard let self, case let .success(value) = result, let raw = value.object("dialog"), let dialog = self.dialogModel(raw) else {
                return
            }
            self.dialogs[dialog.id] = dialog
            self.publishDialogs()
            self.send(text, attachments: message.attachments, to: dialog.id)
            completion(dialog.id)
        }
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

    func models() -> Signal<[ModelInfo], NoError> {
        if let cached = self.modelsCache {
            return .single(cached)
        }
        return self.connection.request("models.list")
        |> map { value -> [ModelInfo] in
            return value.objects("models").map { ModelInfo(provider: $0.string("provider") ?? "", id: $0.string("id") ?? "", name: $0.string("name") ?? $0.string("id") ?? "", reasoning: $0.bool("reasoning") ?? false, contextWindow: $0.int("contextWindow")) }
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

    func agent(_ id: Int) -> AgentSettings {
        guard let realId = self.resolve(id), let agent = self.replicas[realId]?.docs.object("pi.agent") else {
            let fallback = self.defaultModel?.split(separator: "/").map(String.init) ?? []
            return AgentSettings(provider: fallback.first, modelId: fallback.last, thinkingLevel: nil)
        }
        let model = agent.object("model")
        return AgentSettings(provider: model?.string("provider"), modelId: model?.string("modelId"), thinkingLevel: agent.string("thinkingLevel"))
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
        guard let realId = self.resolve(id) else {
            return
        }
        var patch: JSONObject = [:]
        if let model {
            patch["model"] = ["provider": model.provider, "modelId": model.id]
        }
        if let thinkingLevel {
            patch["thinkingLevel"] = thinkingLevel == "off" ? NSNull() : thinkingLevel
        }
        self.connection.request("conversation.configure", ["conversationId": realId, "agent": patch]) { _ in }
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
            self.connection.request("conversation.compact", ["conversationId": realId]) { _ in }
        }
    }

    func resetContext(_ id: Int) {
        if let realId = self.resolve(id) {
            self.connection.request("conversation.reset", ["conversationId": realId]) { _ in }
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
            return DialogModel(id: id, title: row.string("title") ?? "", parentConversationId: row.int("parent"), cwd: row.string("cwd") ?? "~", model: row.string("model") ?? "", last: last, busy: false, unreadCount: row.int("unread") ?? 0, markedUnread: row.bool("markedUnread") ?? false, archived: row.bool("archived") ?? false)
        }
    }
}
