import UIKit

/// The client's copy of one conversation, as `ConversationReplica` in server/src/client.ts: entries cached by ID (never
/// change once written), the docs snapshot kept current with ops, and the start of the active context.
final class ConversationReplica {
    let id: Int
    private(set) var entries: [Int: JSONObject] = [:]
    var docs: JSONObject = [:]
    var head: Int?
    var hasOlder = false
    /// Unsettled submissions by ID.
    var submissions: [Int: JSONObject] = [:]
    /// Whether the docs are current: false between a reconnect and the subscribe response.
    var isSynced = false

    init(id: Int) {
        self.id = id
    }

    var maxId: Int? {
        return self.entries.keys.max()
    }

    var minId: Int? {
        return self.entries.keys.min()
    }

    /// Changes with the entries: the transcript's rows made from them are kept until it does.
    private(set) var entriesVersion = 0
    /// The rows made from the entries, and what the rows after them need to know (TranscriptBuilder.build).
    var committed: TranscriptBuilder.Committed?

    func upsert(_ entries: [JSONObject]) {
        guard !entries.isEmpty else {
            return
        }
        for entry in entries {
            if let id = entry.int("id") {
                self.entries[id] = entry
            }
        }
        self.entriesVersion += 1
    }

    func removeAll() {
        self.entries.removeAll()
        self.entriesVersion += 1
    }

    func ordered() -> [JSONObject] {
        return self.entries.keys.sorted().compactMap { self.entries[$0] }
    }

    /// Applies one `conv.commit` push as a whole.
    func apply(commit push: JSONObject) {
        if let docs = push.object("docs") {
            self.docs = docs
        }
        if let ops = push.array("ops"), let updated = try? JSONOps.apply(ops, to: self.docs) as? JSONObject {
            self.docs = updated
        }
        self.upsert(push.objects("entries"))
        if let head = push.int("head") {
            self.head = head
        }
    }

    /// Since the chat was unsubscribed and until its next subscribe: entries still come (the list's preload), the docs
    /// do not, so what runs (`pi.live`) and waits (`pi.inbox`) is not read from them, or a run long done would show as
    /// streaming beside its committed message. The model and the usage are still read.
    var docsAreStale = false

    var live: JSONObject {
        return self.docsAreStale ? [:] : self.docs.object("pi.live") ?? [:]
    }

    var isBusy: Bool {
        return self.live["run"] != nil || !self.inboxItems.isEmpty
    }

    /// What became of each compaction (`tau.compactions`, server/src/compactions.ts): kept by the server, so read even
    /// from docs a chat left (its running ones are not: what runs is read from the live document).
    var compactions: [CompactionRecord] {
        return (self.docs.object("tau.compactions")?.objects("items") ?? []).compactMap(CompactionRecord.init)
    }

    /// What waits for a boundary (`pi.inbox`): steers, follow-ups, and writes such as a queued reset.
    var inboxItems: [JSONObject] {
        return self.docsAreStale ? [] : self.docs.object("pi.inbox")?.objects("items") ?? []
    }
}

/// One compaction as the server keeps it (server/src/compactions.ts).
struct CompactionRecord: Equatable {
    var taskId: Int
    var reason: String
    var blocking: Bool
    var startedAt: Date
    var state: String
    var entryId: Int?
    var after: Int?
    var error: String?
    var tokensBefore: Int?
    var tokensAfter: Int?
    var cost: Double?

    init?(_ object: JSONObject) {
        guard let taskId = object.int("taskId"), let state = object.string("state") else {
            return nil
        }
        self.taskId = taskId
        self.reason = object.string("reason") ?? "manual"
        self.blocking = object.bool("blocking") ?? false
        self.startedAt = Date(timeIntervalSince1970: (object.double("startedAt") ?? 0.0) / 1000.0)
        self.state = state
        self.entryId = object.int("entryId")
        self.after = object.int("after")
        self.error = object.string("error")
        self.tokensBefore = object.int("tokensBefore")
        self.tokensAfter = object.int("tokensAfter")
        self.cost = object.double("cost")
    }
}

/// Turns entries and live docs into chat rows. Row IDs stay stable across the switch from streaming to committed: an
/// assistant row is keyed by the generation task that wrote it, which `pi.live.run.taskId` names while it streams and
/// `byTaskId` names on the entry, so the streamed row becomes the final one in place.
enum TranscriptBuilder {
    static func rowId(base: Int, block: Int) -> Int {
        return base * 64 + block
    }

    /// The rows the entries make, with what the rows after them need, for as long as the entries and what they were
    /// made with stay the same: a streamed token changes only the live document, and the rows of thousands of entries
    /// were made again for each one.
    struct Committed {
        struct Key: Equatable {
            var entriesVersion: Int
            var rowIdForUserEntry: [Int: Int]
            var streamingTask: Int?
            var hasMedia: Bool
            var compactions: [CompactionRecord]
        }
        let key: Key
        /// Names these rows: two states with the same token have the same rows up to their `StablePrefix`.
        let token: Int
        let rows: [ChatMessage]
        let toolRowIndex: [String: Int]
        let subagentTasks: [String: String]
        let turnStart: Date?
        let subagentCallRows: [String: Int]
        let pendingError: (entry: JSONObject, id: Int, base: Int, date: Date, error: String)?
        let retriedErrors: Int
        let committedTasks: Set<Int>

        private static var nextToken = 0
        static func newToken() -> Int {
            self.nextToken += 1
            return self.nextToken
        }
    }

    /// A sent message as a chat row: with the clock while on its way, red once refused, with two checks once it is in
    /// the transcript but its entry has not reached the replica yet.
    static func row(for item: OutgoingMessage, outbox: Outbox) -> ChatMessage {
        let delivery: ChatMessage.Delivery
        switch item.state {
        case let .failed(_, message):
            delivery = .failed(reason: message)
        case .placed:
            delivery = .delivered
        default:
            delivery = .sending
        }
        return ChatMessage(id: item.rowId, role: .user, text: item.text, date: item.date, attachments: outbox.attachments(item), delivery: delivery, outgoingId: item.requestId)
    }

    /// The input panel's queue: the inbox in its order, this device's messages matched to their items, then this
    /// device's messages still on their way to it.
    static func queue(replica: ConversationReplica, items: [OutgoingMessage]) -> [QueuedMessage] {
        var result: [QueuedMessage] = []
        var shown = Set<String>()
        let bySubmission = Dictionary(items.compactMap { item in item.submissionId.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
        for raw in replica.inboxItems {
            guard let submissionId = raw.int("id") else {
                continue
            }
            let mode: QueuedMessage.Mode
            switch raw.string("mode") {
            case "steer":
                mode = .steer
            case "followUp":
                mode = .followUp
            default:
                // Of the writes only a reset is something the user asked for.
                guard raw.object("entry")?.string("kind") == "pi.reset" else {
                    continue
                }
                mode = .newContext
            }
            if let item = bySubmission[submissionId] {
                shown.insert(item.requestId)
                if case .withdrawing = item.state {
                    continue
                }
                result.append(QueuedMessage(id: item.requestId, mode: item.mode == .steer ? .steer : .followUp, text: item.text, imageCount: item.photoCount, isSending: false, outgoingId: item.requestId, submissionId: submissionId))
            } else {
                let (text, images) = self.userContent(raw["content"])
                result.append(QueuedMessage(id: "s\(submissionId)", mode: mode, text: text, imageCount: images.count, isSending: false, outgoingId: nil, submissionId: submissionId))
            }
        }
        for item in items.sorted(by: { $0.seq < $1.seq }) where !shown.contains(item.requestId) {
            switch item.state {
            case let .queued(submissionId):
                // Synced and not in the inbox: it left it, for the transcript or withdrawn, and its record is on the
                // way; showing it queued meanwhile would be stale.
                if replica.isSynced && !item.needsRefresh {
                    continue
                }
                result.append(QueuedMessage(id: item.requestId, mode: item.mode == .steer ? .steer : .followUp, text: item.text, imageCount: item.photoCount, isSending: false, outgoingId: item.requestId, submissionId: submissionId))
            case .pending where item.showsInQueue:
                result.append(QueuedMessage(id: item.requestId, mode: item.mode == .steer ? .steer : .followUp, text: item.text, imageCount: item.photoCount, isSending: true, outgoingId: item.requestId, submissionId: nil))
            default:
                break
            }
        }
        return result
    }

    static func build(replica: ConversationReplica, outbox: Outbox, rowIdForUserEntry: [Int: Int], media: MediaLoader? = nil) -> ConversationState {
        /// An entry's image: a reference from a server that sends them so, else the data, decoded.
        func attachment(entryId: Int, index: Int, block: JSONObject) -> MessageAttachment? {
            // By reference, as the server sends every image (server/src/media.ts).
            return media?.image(conversationId: replica.id, entryId: entryId, index: index, block: block).map { MessageAttachment(id: entryId * 64 + index, kind: .remote($0)) }
        }
        /// What send_file sent (server/src/send-file.ts), as the chat shows it: photos, and files to open.
        func sentFiles(_ files: [JSONObject], entryId id: Int) -> [MessageAttachment] {
            return files.enumerated().compactMap { index, file -> MessageAttachment? in
                guard let fileId = file.string("id") else {
                    return nil
                }
                var size: CGSize?
                if let width = file.double("width"), let height = file.double("height"), width > 0.0, height > 0.0 {
                    size = CGSize(width: width, height: height)
                }
                let mimeType = file.string("mimeType") ?? "application/octet-stream"
                let bytes = file.double("bytes") ?? 0.0
                // An image the chat can show (a known format, at most 20 MB) as a photo; anything else a file.
                if let media, ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mimeType), bytes <= 20.0 * 1024.0 * 1024.0 {
                    return MessageAttachment(id: id * 64 + index, kind: .remote(media.fileImage(id: fileId, mimeType: mimeType, bytes: Int(bytes), pixelSize: size)))
                }
                return MessageAttachment(id: id * 64 + index, kind: .file(FileAttachment(name: file.string("name") ?? "file", size: Int64(bytes), mimeType: mimeType, serverId: fileId, pixelSize: size)))
            }
        }
        let items = outbox.items(for: replica.id)
        var rows: [ChatMessage] = []
        var toolRowIndex: [String: Int] = [:]
        /// Each subagent's task, for the quote on its answers.
        var subagentTasks: [String: String] = [:]
        /// When the run being read began: its first message.
        var turnStart: Date?

        /// The row of each subagent's latest spawn or message, whose answer is still to come.
        var subagentCallRows: [String: Int] = [:]
        /// A model error not yet known to be the run's last: the server may be asking again. Its entry, content and
        /// error; errors in the run it asked past.
        var pendingError: (entry: JSONObject, id: Int, base: Int, date: Date, error: String)?
        var retriedErrors = 0
        /// The generation tasks whose message is in the transcript and ended them. Not an aborted one: durable resumes a
        /// generation cut off by a restart under the same task.
        var committedTasks = Set<Int>()

        func addAssistant(content: [JSONObject], base: Int, date: Date, entryId: Int?, streaming: Bool, toolStart: Date? = nil) {
            for (index, block) in content.enumerated() {
                let rowId = self.rowId(base: base, block: index)
                switch block.string("type") {
                case "text":
                    let text = block.string("text") ?? ""
                    if text.isEmpty {
                        continue
                    }
                    rows.append(ChatMessage(id: rowId, role: .assistant, text: text, date: date, isStreaming: streaming, entryId: entryId))
                case "thinking":
                    let text = (block.string("thinking") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        continue
                    }
                    rows.append(ChatMessage(id: rowId, role: .thinking, text: text, date: date, isStreaming: streaming, entryId: entryId))
                case "toolCall":
                    let name = block.string("name") ?? "tool"
                    let callId = block.string("id") ?? "\(rowId)"
                    let arguments = block.object("arguments") ?? [:]
                    var tool = ToolCallInfo(callId: callId, name: name, summary: ToolSummary.summary(name: name, arguments: arguments), status: streaming ? .preparing : .pending, output: nil, childConversationId: nil, detail: ToolSummary.detail(name: name, arguments: arguments))
                    tool.startedAt = toolStart
                    if name == "subagent", var call = ToolSummary.subagent(arguments) {
                        call.startedAt = toolStart
                        tool.subagent = call
                        if call.kind == .spawn {
                            subagentTasks[call.name] = call.text
                        }
                        if call.kind == .spawn || call.kind == .send {
                            subagentCallRows[call.name] = rows.count
                        }
                    }
                    toolRowIndex[callId] = rows.count
                    rows.append(ChatMessage(id: rowId, role: .tool(name: name), text: "", date: date, tool: tool, isStreaming: false, entryId: entryId))
                default:
                    continue
                }
            }
        }

        /// The run ended on the error: what the model wrote before it, and the error's card. `retry`: Retry continues
        /// it (the failure is the latest run's, and nothing runs).
        func flushError(retry: Bool = false) {
            guard let pending = pendingError else {
                return
            }
            pendingError = nil
            let message = pending.entry.objects("model").first ?? [:]
            addAssistant(content: message.objects("content"), base: pending.base, date: pending.date, entryId: pending.id, streaming: false)
            rows.append(ChatMessage(id: self.rowId(base: pending.id, block: 63), role: .service, text: pending.error, date: pending.date, entryId: pending.id, service: .failed(title: "The model failed", error: ModelErrorText.clean(pending.error), retry: retry)))
            turnStart = nil
            retriedErrors = 0
        }

        // The task streaming now: a generation cut off by a server restart is committed as an aborted message and
        // asked again under the same task.
        let streamingTask = replica.live.object("generation") != nil ? replica.live.object("run")?.int("taskId") : nil
        let compactions = replica.compactions
        let key = Committed.Key(entriesVersion: replica.entriesVersion, rowIdForUserEntry: rowIdForUserEntry, streamingTask: streamingTask, hasMedia: media != nil, compactions: compactions)
        let token: Int
        if let cached = replica.committed, cached.key == key {
            token = cached.token
            rows = cached.rows
            toolRowIndex = cached.toolRowIndex
            subagentTasks = cached.subagentTasks
            turnStart = cached.turnStart
            subagentCallRows = cached.subagentCallRows
            pendingError = cached.pendingError
            retriedErrors = cached.retriedErrors
            committedTasks = cached.committedTasks
        } else {
            let ordered = replica.ordered()
            // Each generation task's last message.
            var lastOfTask: [Int: Int] = [:]
            for entry in ordered where entry.string("kind") == "pi.assistant" {
                if let taskId = entry.int("byTaskId"), let id = entry.int("id") {
                    lastOfTask[taskId] = max(lastOfTask[taskId] ?? id, id)
                }
            }

            // Compactions that ended unused, each a note after the entry the chat had then; not those before what is
            // loaded.
            let oldestLoaded = ordered.first?.int("id") ?? 0
            var notes = compactions.filter { ["stale", "failed", "empty"].contains($0.state) && $0.after != nil && !(replica.hasOlder && $0.after! < oldestLoaded) }.sorted { $0.after! < $1.after! }
            func addNotes(before id: Int?) {
                while let note = notes.first, id == nil || note.after! < id! {
                    notes.removeFirst()
                    rows.append(ChatMessage(id: self.rowId(base: note.taskId, block: 62), role: .service, text: "", date: note.startedAt, service: .compactionUnused(state: note.state, error: note.error)))
                }
            }

            for entry in ordered {
                guard let id = entry.int("id"), let kind = entry.string("kind") else {
                    continue
                }
                addNotes(before: id)
                // A message after an error: the run had ended on it.
                if kind == "pi.user" {
                    flushError()
                }
                let message = entry.objects("model").first ?? [:]
                let date = message.double("timestamp").map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()
                switch kind {
                case "pi.user":
                    if turnStart == nil {
                        turnStart = date
                    }
                    let (text, imageBlocks) = self.userContent(message["content"])
                    let lines = self.attachmentLines(message["content"])
                    let photoLines = lines.filter { $0.kind == .image }
                    var attachments = imageBlocks.enumerated().compactMap { index, block -> MessageAttachment? in
                        // A photo the user sent is a file the server keeps: fetched over HTTP, beside the socket, as an
                        // edit sends it again (docs/media.md). The entry's own copy only without one.
                        if index < photoLines.count, let fileId = photoLines[index].fileId, let media {
                            let line = photoLines[index]
                            return MessageAttachment(id: id * 64 + index, kind: .remote(media.fileImage(id: fileId, mimeType: line.mimeType, bytes: Int(line.bytes), pixelSize: line.pixelSize ?? media.image(conversationId: replica.id, entryId: id, index: index, block: block)?.pixelSize)))
                        }
                        return attachment(entryId: id, index: index, block: block)
                    }
                    // And the files only named.
                    attachments += lines.filter { $0.kind == .file }.enumerated().map { index, line in
                        MessageAttachment(id: id * 64 + 32 + index, kind: .file(line.file))
                    }
                    if let report = SubagentReport(text) {
                        // A background subagent's answer, posted as a message: its card, not the user's bubble.
                        var tool = ToolCallInfo(callId: "report-\(id)", name: "subagent", summary: report.status == "answered" ? "\(report.name) answered" : "\(report.name) failed", status: report.status == "answered" ? .done : .failed, output: report.text, childConversationId: report.conversationId)
                        var call = SubagentCall(kind: report.status == "answered" ? .answer : .failed, name: report.name, text: report.text, task: subagentTasks[report.name])
                        // How long it worked: from the call that gave it the work, which shows the time too.
                        if let callRow = subagentCallRows.removeValue(forKey: report.name), let started = rows[callRow].tool?.subagent?.startedAt {
                            call.duration = max(0.0, date.timeIntervalSince(started))
                            rows[callRow].tool?.subagent?.duration = call.duration
                        }
                        tool.subagent = call
                        rows.append(ChatMessage(id: self.rowId(base: id, block: 0), role: .tool(name: "subagent"), text: "", date: date, tool: tool, entryId: id))
                        continue
                    }
                    rows.append(ChatMessage(id: rowIdForUserEntry[id] ?? self.rowId(base: id, block: 0), role: .user, text: text, date: date, attachments: attachments, entryId: id))
                case "pi.assistant":
                    let base = entry.int("byTaskId") ?? id
                    // Cut off and asked again: the later attempt replaces it, as for the model, which does not read aborted
                    // messages either. One the user stopped ends its task, and stays.
                    if message.string("stopReason") == "aborted", let taskId = entry.int("byTaskId"), (lastOfTask[taskId] ?? id) > id || streamingTask == taskId {
                        continue
                    }
                    if message.string("stopReason") == "error" {
                        // Shown only if the run ends on it; a later attempt replaces it, as it does for the model, which
                        // never reads failed responses.
                        if pendingError != nil {
                            retriedErrors += 1
                        }
                        pendingError = (entry, id, base, date, message.string("errorMessage") ?? "The model returned an error")
                        continue
                    }
                    if pendingError != nil {
                        pendingError = nil
                        retriedErrors += 1
                    }
                    if let taskId = entry.int("byTaskId"), message.string("stopReason") != "aborted" {
                        committedTasks.insert(taskId)
                    }
                    // Its calls start once it is written.
                    let written = date.addingTimeInterval((message.double("durationMs") ?? 0.0) / 1000.0)
                    let firstRow = rows.count
                    addAssistant(content: message.objects("content"), base: base, date: date, entryId: id, streaming: false, toolStart: written)
                    // Stopped while the model wrote them: its calls never run (a result, if one came, says otherwise).
                    if message.string("stopReason") == "aborted" {
                        for index in firstRow ..< rows.count where rows[index].tool != nil {
                            rows[index].tool?.status = .stopped
                        }
                    }
                    // The end of a run: its answer says when it came and how long the run took, from the first message.
                    if message.string("stopReason") != "toolUse" {
                        let finished = date.addingTimeInterval((message.double("durationMs") ?? 0.0) / 1000.0)
                        if let last = rows.indices.last, rows[last].role == .assistant, rows[last].entryId == id {
                            rows[last].turn = TurnInfo(finishedAt: finished, duration: turnStart.map { finished.timeIntervalSince($0) }, retries: retriedErrors)
                        }
                        turnStart = nil
                        retriedErrors = 0
                    }
                case "pi.tool-result":
                    guard let callId = message.string("toolCallId"), let index = toolRowIndex[callId], var tool = rows[index].tool else {
                        continue
                    }
                    tool.status = (message.bool("isError") ?? false) ? .failed : .done
                    tool.output = self.text(of: message["content"])
                    let imageBlocks = (message["content"] as? [Any])?.compactMap { $0 as? JSONObject }.filter { $0.string("type") == "image" } ?? []
                    tool.images = imageBlocks.enumerated().compactMap { index, block in
                        attachment(entryId: id, index: index, block: block)
                    }
                    if !tool.images.isEmpty {
                        // The card shows the images themselves, not their "[image]".
                        tool.output = ((message["content"] as? [Any])?.compactMap { ($0 as? JSONObject)?.string("text") } ?? []).joined(separator: "\n")
                    }
                    if let milliseconds = message.double("durationMs") {
                        tool.duration = milliseconds / 1000.0
                    }
                    if let details = message.object("details") {
                        if let child = details.int("conversationId") {
                            tool.childConversationId = child
                        }
                        // What the server made of the options: the model it found, the level it fitted.
                        if var call = tool.subagent {
                            call.model = details.string("model") ?? call.model
                            call.thinking = details.string("thinking") ?? call.thinking
                            tool.subagent = call
                        }
                    }
                    // What send_file sent: shown as photos and files, not as a card (server/src/send-file.ts).
                    if tool.name == "send_file", let files = message.object("details")?.objects("files") {
                        tool.sentFiles = sentFiles(files, entryId: id)
                    }
                    // A script: its calls, and its output without the header the model reads first.
                    if case let .code(script, _) = tool.detail {
                        tool.nested = message.object("details")?.objects("calls").map(ToolSummary.nestedCall) ?? []
                        let (output, error) = ToolSummary.scriptOutput(tool.output ?? "")
                        tool.output = output
                        tool.detail = .code(script: script, error: tool.status == .failed ? error : nil)
                    }
                    // The edit tool's result carries the diff with line numbers.
                    if case let .edit(path, _) = tool.detail, let diff = message.object("details")?.string("diff"), !diff.isEmpty {
                        tool.detail = .edit(path: path, diff: diff)
                    }
                    rows[index].tool = tool
                case "tau.files":
                    // What send_file sent from a script (server/src/shown.ts): as the model's own call shows it.
                    let data = entry.object("data") ?? [:]
                    var tool = ToolCallInfo(callId: data.string("callId") ?? "files-\(id)", name: "send_file", summary: "", status: .done, output: nil, childConversationId: nil)
                    tool.sentFiles = sentFiles(data.objects("files"), entryId: id)
                    rows.append(ChatMessage(id: self.rowId(base: id, block: 0), role: .tool(name: "send_file"), text: "", date: rows.last?.date ?? Date(), tool: tool, entryId: id))
                case "tau.subagent":
                    // A subagent a script started, sent to, or stopped: the card the model's own call has.
                    let data = entry.object("data") ?? [:]
                    guard let name = data.string("name") else {
                        continue
                    }
                    let kind: SubagentCall.Kind
                    switch data.string("action") {
                    case "spawn":
                        kind = .spawn
                    case "send":
                        kind = .send
                    default:
                        kind = .stop
                    }
                    let at = data.double("at").map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? rows.last?.date ?? Date()
                    var call = SubagentCall(kind: kind, name: name, text: data.string("message") ?? "", model: data.string("model"), thinking: data.string("thinking"), fork: data.bool("fork") ?? false)
                    call.startedAt = at
                    var arguments: JSONObject = ["action": data.string("action") ?? "stop", "name": name]
                    arguments["message"] = data.string("message")
                    var tool = ToolCallInfo(callId: data.string("callId") ?? "subagent-\(id)", name: "subagent", summary: ToolSummary.summary(name: "subagent", arguments: arguments), status: .done, output: nil, childConversationId: data.int("conversationId"))
                    tool.startedAt = at
                    tool.subagent = call
                    if kind == .spawn {
                        subagentTasks[name] = call.text
                    }
                    if kind == .spawn || kind == .send {
                        subagentCallRows[name] = rows.count
                    }
                    rows.append(ChatMessage(id: self.rowId(base: id, block: 0), role: .tool(name: "subagent"), text: "", date: at, tool: tool, entryId: id))
                case "pi.compaction":
                    // The summary the model now reads instead of what came before (durable's SUMMARY_PREFIX/SUFFIX).
                    var summary = self.text(of: message["content"])
                    if let start = summary.range(of: "<summary>\n") {
                        summary = String(summary[start.upperBound...])
                    }
                    if summary.hasSuffix("\n</summary>") {
                        summary = String(summary.dropLast("\n</summary>".count))
                    }
                    let reason = entry.object("data")?.string("reason") ?? "manual"
                    // Under the row its compaction had while it ran: the pill turns into the card in place.
                    let record = compactions.first(where: { $0.entryId == id })
                    rows.append(ChatMessage(id: record.map { self.rowId(base: $0.taskId, block: 62) } ?? self.rowId(base: id, block: 0), role: .service, text: summary, date: date, entryId: id, service: .compacted(summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), reason: reason, before: record?.tokensBefore, after: record?.tokensAfter, cost: record?.cost)))
                default:
                    continue
                }
            }
            addNotes(before: nil)
            token = Committed.newToken()
            replica.committed = Committed(key: key, token: token, rows: rows, toolRowIndex: toolRowIndex, subagentTasks: subagentTasks, turnStart: turnStart, subagentCallRows: subagentCallRows, pendingError: pendingError, retriedErrors: retriedErrors, committedTasks: committedTasks)
        }
        /// The rows from here on may differ from the committed ones.
        var stableCount = rows.count

        // What is running now.
        let live = replica.live
        // An error at the end stands unless the run goes on: then the server is asking again. Why the latest run
        // ended without an answer is durable's `runFailure`, until the next run starts: a model error's card is its
        // error entry's, the others (cut off by a restart, no model, ...) have no entry and are a card of their own.
        // Retry continues the run where it stopped, while nothing runs and something is left to answer.
        if !replica.isBusy {
            let failure = live.object("runFailure")
            let reason = failure?.string("reason")
            let retry = reason.map(RunFailureText.canContinue) ?? false
            let erred = pendingError != nil
            flushError(retry: retry && reason == "model_error")
            if let failure, let reason, !(erred && reason == "model_error"), let card = RunFailureText.card(reason: reason, detail: failure.string("detail")) {
                let taskId = failure.int("taskId") ?? 0
                rows.append(ChatMessage(id: self.rowId(base: taskId, block: 61), role: .service, text: card.text, date: Date(timeIntervalSince1970: 0.0), service: .failed(title: card.title, error: card.text, retry: retry)))
            }
        }
        // Not once the message that ended its task is in the transcript: its rows would have the committed ones' IDs.
        // (The replica's stale docs are not read; this guards against a live document behind its entries otherwise.)
        if let generation = live.object("generation"), let partial = generation.object("message"), let run = live.object("run"), let taskId = run.int("taskId"), !committedTasks.contains(taskId) {
            addAssistant(content: partial.objects("content"), base: taskId, date: Date(), entryId: nil, streaming: true)
        }
        for slot in live.objects("tools") {
            guard let callId = slot.string("callId"), let index = toolRowIndex[callId], var tool = rows[index].tool else {
                continue
            }
            switch slot.string("status") {
            case "running":
                tool.status = .running
            case "done":
                if tool.status != .failed {
                    tool.status = .done
                }
            default:
                if tool.status == .preparing {
                    tool.status = .pending
                }
            }
            if let output = slot.string("output") {
                tool.output = output
            }
            if let child = slot.object("details")?.int("conversationId") {
                tool.childConversationId = child
            }
            if rows[index].tool != tool {
                rows[index].tool = tool
                stableCount = min(stableCount, index)
            }
        }
        // A running script's calls, until its result lists them.
        for slot in live.objects("nestedTools") {
            guard let parent = slot.string("parentCallId"), let index = toolRowIndex[parent], var tool = rows[index].tool, tool.status != .done, tool.status != .failed else {
                continue
            }
            let summary = slot.object("summary")
            var call = ToolSummary.nestedCall(name: slot.string("name") ?? "tool", arguments: slot.object("arguments") ?? [:])
            if let summary {
                call.status = (summary.bool("isError") ?? false) ? .failed : .done
                call.duration = summary.double("durationMs").map { $0 / 1000.0 }
                call.error = summary.string("error")
            } else {
                call.status = .running
                call.output = slot.string("output")
            }
            tool.nested.append(call)
            rows[index].tool = tool
            stableCount = min(stableCount, index)
        }

        // Sent and not in the replica's transcript yet, in the order sent: on their way (not those the queue shows),
        // refused, or placed with the entry still to come.
        for item in items.sorted(by: { $0.seq < $1.seq }) {
            switch item.state {
            case .failed:
                rows.append(self.row(for: item, outbox: outbox))
            case .pending where !item.showsInQueue:
                rows.append(self.row(for: item, outbox: outbox))
            case let .placed(entryId) where replica.entries[entryId] == nil:
                rows.append(self.row(for: item, outbox: outbox))
            default:
                break
            }
        }
        // A summary being made: it does not stop the conversation, so it is a row of its own at the end.
        // Its row from the start, at the end until its summary is placed (or it ends unused): running, then waiting
        // for a run's next step. From the server's record (when it began); from the live document until that comes.
        var shown = Set<Int>()
        let liveTasks = Set(live.objects("compactions").compactMap { $0.int("taskId") })
        // A running one only while the live document lists its task: a record the server could not settle yet (it
        // writes it after the commit that ended the task, and a crash between the two left it running) must not tick
        // on for good. A waiting one is no longer listed there, rightly.
        for record in compactions where !replica.docsAreStale && ((record.state == "running" && liveTasks.contains(record.taskId)) || record.state == "waiting") {
            shown.insert(record.taskId)
            rows.append(ChatMessage(id: self.rowId(base: record.taskId, block: 62), role: .service, text: "", date: Date(timeIntervalSince1970: 0.0), service: .compacting(since: record.startedAt, waiting: record.state == "waiting")))
        }
        for compaction in live.objects("compactions") {
            guard let taskId = compaction.int("taskId"), !shown.contains(taskId), !compactions.contains(where: { $0.taskId == taskId }) else {
                continue
            }
            rows.append(ChatMessage(id: self.rowId(base: taskId, block: 62), role: .service, text: "", date: Date(timeIntervalSince1970: 0.0), service: .compacting(since: self.firstSeen(compaction: taskId), waiting: false)))
        }
        // A run waiting on a compaction (past the blocking threshold): what holds the user up is the compaction.
        let blocksRun = replica.live["run"] != nil && live.objects("compactions").contains { $0.bool("blocking") == true }
        let queue = self.queue(replica: replica, items: items)
        // The agent works, or something waits for it: a message on its way is not that.
        var state = ConversationState(messages: rows, streaming: nil, busy: replica.isBusy || !queue.isEmpty, queued: queue, hasOlder: replica.hasOlder, isLoaded: replica.isSynced || !replica.entries.isEmpty)
        state.stablePrefix = StablePrefix(token: token, count: stableCount)
        state.compactionBlocksRun = blocksRun
        state.runStartedAt = replica.isBusy ? turnStart : nil
        if let failure = live.object("compactionFailure"), let taskId = failure.int("taskId") {
            state.compactionFailure = CompactionFailure(taskId: taskId, error: failure.string("error") ?? "")
        }
        // The backoff, or the request after it; the error before it when the transcript has it.
        // A request that has started writing is no longer a retry to wait on.
        if replica.isBusy, let generation = live.object("generation"), generation.object("message")?.objects("content").isEmpty ?? true {
            let attempt = generation.int("attempt") ?? 1
            let retry = generation.object("retry")
            let error = retry?.string("error") ?? pendingError?.error
            if retry != nil || attempt > 1 {
                state.retry = RetryState(attempt: retry == nil ? attempt : attempt + 1, at: retry?.double("at").map { Date(timeIntervalSince1970: $0 / 1000.0) }, reason: error.map(ModelErrorText.reason) ?? "error")
            }
        }
        return state
    }

    private static let compactionLock = NSLock()
    private static var compactionStarts: [Int: Date] = [:]

    /// When this app first saw a compaction task: the live document says it runs, not since when.
    static func firstSeen(compaction taskId: Int) -> Date {
        self.compactionLock.lock()
        defer {
            self.compactionLock.unlock()
        }
        if let date = self.compactionStarts[taskId] {
            return date
        }
        let now = Date()
        self.compactionStarts[taskId] = now
        return now
    }

    /// A user message's text and its image blocks.
    /// What a user message says (without its attachments block) and its image blocks.
    static func userContent(_ content: Any?) -> (String, [JSONObject]) {
        if let text = content as? String {
            return (text, [])
        }
        let blocks = (content as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        let text = blocks.filter { $0.string("type") == "text" }.compactMap { $0.string("text") }.filter { AttachmentLine.parse($0) == nil }.joined(separator: "\n")
        return (text, blocks.filter { $0.string("type") == "image" })
    }

    /// The files a user message's attachments block names (Server/AttachmentsBlock.swift); none without one.
    static func attachmentLines(_ content: Any?) -> [AttachmentLine] {
        let blocks = (content as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        for block in blocks where block.string("type") == "text" {
            if let lines = block.string("text").flatMap(AttachmentLine.parse) {
                return lines
            }
        }
        return []
    }

    /// What an entry says, as a link to it shows it (docs/links.md): a user's message, or an answer's text without its
    /// reasoning and tool calls; nil for anything else.
    static func quotedText(_ entry: JSONObject) -> String? {
        let message = entry.objects("model").first ?? [:]
        switch entry.string("kind") {
        case "pi.user":
            return self.userContent(message["content"]).0
        case "pi.assistant":
            let blocks = (message["content"] as? [Any])?.compactMap { $0 as? JSONObject } ?? []
            return blocks.filter { $0.string("type") == "text" }.compactMap { $0.string("text") }.joined(separator: "\n")
        default:
            return nil
        }
    }

    static func text(of content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        let blocks = (content as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        return blocks.compactMap { block -> String? in
            switch block.string("type") {
            case "text":
                return block.string("text")
            case "image":
                return "[image]"
            default:
                return nil
            }
        }.joined(separator: "\n")
    }
}

/// One line per tool call, the way a terminal agent prints it.
enum ToolSummary {
    static func detail(name: String, arguments: JSONObject) -> ToolDetail {
        let path = arguments.string("path") ?? ""
        switch name {
        case "bash":
            return .bash(command: arguments.string("command") ?? "")
        case "read":
            return .read(path: path)
        case "write":
            return .write(path: path, content: arguments.string("content") ?? "")
        case "edit":
            // Until the result's diff arrives: each replacement's old lines, then its new ones.
            var lines: [String] = []
            for edit in arguments.objects("edits") {
                for line in (edit.string("oldText") ?? "").components(separatedBy: "\n") {
                    lines.append("-" + line)
                }
                for line in (edit.string("newText") ?? "").components(separatedBy: "\n") {
                    lines.append("+" + line)
                }
            }
            return .edit(path: path, diff: lines.joined(separator: "\n"))
        case "codemode":
            return .code(script: arguments.string("code") ?? "", error: nil)
        case HistoryCard.searchName, HistoryCard.readName:
            let call = HistoryCard.call(name: name, arguments: arguments)
            return .history(code: call.code, plain: call.plain, words: call.words)
        default:
            return .none
        }
    }

    /// A script's call as its result lists it: `args` is its arguments' JSON, cut at 200 characters.
    static func nestedCall(_ call: JSONObject) -> NestedToolCall {
        var nested = self.nestedCall(name: call.string("name") ?? "tool", arguments: self.arguments(call.string("args") ?? ""))
        switch call.string("status") {
        case "ok":
            nested.status = .done
        case "error":
            nested.status = .failed
        case "cancelled":
            nested.status = .cancelled
        default:
            nested.status = .running
        }
        nested.duration = call.double("durationMs").map { $0 / 1000.0 }
        nested.error = call.string("error")
        return nested
    }

    static func nestedCall(name: String, arguments: JSONObject) -> NestedToolCall {
        var summary = self.summary(name: name, arguments: arguments)
        if ["read", "write", "edit"].contains(name) {
            // As a card's title shortens a path.
            let components = summary.split(separator: "/", omittingEmptySubsequences: false)
            summary = components.count <= 2 ? summary : components.suffix(2).joined(separator: "/")
        }
        return NestedToolCall(name: name, summary: summary, status: .running)
    }

    /// Arguments from their JSON, also when cut: then the first string, as far as it goes, which is the command or the
    /// path of the tools that matter here.
    static func arguments(_ json: String) -> JSONObject {
        if let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
            return object
        }
        guard let match = json.range(of: #"^\{"([A-Za-z_]+)":""#, options: .regularExpression) else {
            return [:]
        }
        let key = String(json[match].dropFirst(2).dropLast(3))
        var value = ""
        var escaped = false
        for character in json[match.upperBound...] {
            if escaped {
                switch character {
                case "n":
                    value.append("\n")
                case "t":
                    value.append("\t")
                default:
                    value.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                value.append(character)
            }
        }
        if value.hasSuffix("...") {
            value = String(value.dropLast(3)) + "…"
        }
        return [key: value]
    }

    /// A script's result as the card shows it: the output, without the header the model reads ("Script completed",
    /// its wall time, "Output:"), the markers between its texts (a blank line instead) or the console block's tags;
    /// and on failure the error, without the list of calls made, which the card has (durable's codemode/output.ts).
    static func scriptOutput(_ text: String) -> (output: String, error: String?) {
        var output = text
        if let header = output.range(of: #"^Script (completed|failed)\nWall time [0-9.]+ seconds\nOutput:\n\n?"#, options: .regularExpression) {
            output.removeSubrange(header)
        }
        var error: String?
        if let marker = output.range(of: "Script error:\n", options: .backwards) {
            var rest = String(output[marker.upperBound...])
            if let calls = rest.range(of: #"\n\n(Tool calls made before the failure|No tool calls were made)"#, options: [.regularExpression, .backwards]) {
                rest = String(rest[..<calls.lowerBound])
            }
            error = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            output = String(output[..<marker.lowerBound])
        }
        output = output.replacingOccurrences(of: #"(?m)^==> text [0-9]+/[0-9]+ <==\n"#, with: "\n", options: .regularExpression)
        output = output.replacingOccurrences(of: "<console_output>\n", with: "\n").replacingOccurrences(of: "\n</console_output>", with: "")
        return (output.trimmingCharacters(in: .whitespacesAndNewlines), error)
    }

    /// A background subagent's call, from its arguments; nil for status, which names none.
    static func subagent(_ arguments: JSONObject) -> SubagentCall? {
        guard let name = arguments.string("name"), !name.isEmpty else {
            return nil
        }
        let message = arguments.string("message") ?? ""
        let kind: SubagentCall.Kind
        switch arguments.string("action") {
        case "send":
            kind = .send
        case "stop":
            kind = .stop
        case "spawn":
            kind = .spawn
        default:
            return nil
        }
        let fork = arguments.bool("fork") ?? (arguments.string("fork") == "true")
        return SubagentCall(kind: kind, name: name, text: message, model: arguments.string("model"), thinking: arguments.string("thinking"), fork: fork)
    }

    static func summary(name: String, arguments: JSONObject) -> String {
        func path(_ key: String = "path") -> String {
            return arguments.string(key) ?? ""
        }
        switch name {
        case "bash":
            return (arguments.string("command") ?? "").components(separatedBy: "\n").first ?? ""
        case "read":
            var result = path()
            if let offset = arguments.int("offset") {
                result += ":\(offset)"
                if let limit = arguments.int("limit") {
                    result += "-\(offset + limit)"
                }
            }
            return result
        case "write", "edit":
            return path()
        case "codemode":
            return ""
        case HistoryCard.searchName, HistoryCard.readName:
            let call = HistoryCard.call(name: name, arguments: arguments)
            return [call.code, call.words].filter { !$0.isEmpty }.joined(separator: "  ")
        case "send_file":
            return ((arguments["paths"] as? [Any]) ?? []).compactMap { ($0 as? String)?.split(separator: "/").last.map(String.init) }.joined(separator: ", ")
        case "subagent":
            // The background tool names its subagent; the earlier one took a task.
            if let name = arguments.string("name") {
                let message = arguments.string("message") ?? ""
                switch arguments.string("action") {
                case "send":
                    return "\(name) ← \(message)"
                case "stop":
                    return "Stop \(name)"
                default:
                    return message.isEmpty ? name : "\(name): \(message)"
                }
            }
            return arguments.string("task") ?? (arguments.string("action") == "status" ? "Status" : "")
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return String(text.prefix(200))
        }
    }
}

/// A background subagent's answer as the server posts it (server/src/subagent.ts):
/// `<subagent name="…" conversation="…" status="answered">…</subagent>`.
struct SubagentReport {
    let name: String
    let conversationId: Int?
    let status: String
    let text: String

    init?(_ message: String) {
        guard message.hasPrefix("<subagent "), let headerEnd = message.firstIndex(of: ">") else {
            return nil
        }
        let header = String(message[message.startIndex ..< headerEnd])
        func attribute(_ key: String) -> String? {
            guard let range = header.range(of: "\(key)=\"") else {
                return nil
            }
            let rest = header[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else {
                return nil
            }
            return String(rest[..<end]).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&amp;", with: "&")
        }
        guard let name = attribute("name") else {
            return nil
        }
        self.name = name
        self.conversationId = attribute("conversation").flatMap(Int.init)
        self.status = attribute("status") ?? "answered"
        var body = String(message[message.index(after: headerEnd)...])
        if body.hasSuffix("</subagent>") {
            body = String(body.dropLast("</subagent>".count))
        }
        self.text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
