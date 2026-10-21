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

    func upsert(_ entries: [JSONObject]) {
        for entry in entries {
            if let id = entry.int("id") {
                self.entries[id] = entry
            }
        }
    }

    func removeAll() {
        self.entries.removeAll()
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

    var live: JSONObject {
        return self.docs.object("pi.live") ?? [:]
    }

    var isBusy: Bool {
        return self.live["run"] != nil || !self.inboxItems.isEmpty
    }

    /// What waits for a boundary (`pi.inbox`): steers, follow-ups, and writes such as a queued reset.
    var inboxItems: [JSONObject] {
        return self.docs.object("pi.inbox")?.objects("items") ?? []
    }
}

/// Turns entries and live docs into chat rows. Row IDs stay stable across the switch from streaming to committed: an
/// assistant row is keyed by the generation task that wrote it, which `pi.live.run.taskId` names while it streams and
/// `byTaskId` names on the entry, so the streamed row becomes the final one in place.
enum TranscriptBuilder {
    static func rowId(base: Int, block: Int) -> Int {
        return base * 64 + block
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
                result.append(QueuedMessage(id: item.requestId, mode: item.mode == .steer ? .steer : .followUp, text: item.text, imageCount: item.imageFiles.count, isSending: false, outgoingId: item.requestId, submissionId: submissionId))
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
                result.append(QueuedMessage(id: item.requestId, mode: item.mode == .steer ? .steer : .followUp, text: item.text, imageCount: item.imageFiles.count, isSending: false, outgoingId: item.requestId, submissionId: submissionId))
            case .pending where item.showsInQueue:
                result.append(QueuedMessage(id: item.requestId, mode: item.mode == .steer ? .steer : .followUp, text: item.text, imageCount: item.imageFiles.count, isSending: true, outgoingId: item.requestId, submissionId: nil))
            default:
                break
            }
        }
        return result
    }

    static func build(replica: ConversationReplica, outbox: Outbox, rowIdForUserEntry: [Int: Int], images: ImageDecoder) -> ConversationState {
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

        /// The run ended on the error: what the model wrote before it, and the error's card.
        func flushError() {
            guard let pending = pendingError else {
                return
            }
            pendingError = nil
            let message = pending.entry.objects("model").first ?? [:]
            addAssistant(content: message.objects("content"), base: pending.base, date: pending.date, entryId: pending.id, streaming: false)
            rows.append(ChatMessage(id: self.rowId(base: pending.id, block: 63), role: .service, text: pending.error, date: pending.date, entryId: pending.id, service: .failed(error: ModelErrorText.clean(pending.error))))
            turnStart = nil
            retriedErrors = 0
        }

        for entry in replica.ordered() {
            guard let id = entry.int("id"), let kind = entry.string("kind") else {
                continue
            }
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
                let attachments = imageBlocks.enumerated().compactMap { index, block -> MessageAttachment? in
                    guard let image = images.image(entryId: id, index: index, block: block) else {
                        return nil
                    }
                    return MessageAttachment(id: id * 64 + index, kind: .image(image))
                }
                if let report = SubagentReport(text) {
                    // A background subagent's answer, posted as a message: its card, not the user's bubble.
                    var tool = ToolCallInfo(callId: "report-\(id)", name: "subagent", summary: report.status == "answered" ? "\(report.name) answered" : "\(report.name) stopped", status: report.status == "answered" ? .done : .failed, output: report.text, childConversationId: report.conversationId)
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
                // Its calls start once it is written.
                let written = date.addingTimeInterval((message.double("durationMs") ?? 0.0) / 1000.0)
                addAssistant(content: message.objects("content"), base: base, date: date, entryId: id, streaming: false, toolStart: written)
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
                // The edit tool's result carries the diff with line numbers.
                if case let .edit(path, _) = tool.detail, let diff = message.object("details")?.string("diff"), !diff.isEmpty {
                    tool.detail = .edit(path: path, diff: diff)
                }
                rows[index].tool = tool
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
                rows.append(ChatMessage(id: self.rowId(base: id, block: 0), role: .service, text: summary, date: date, entryId: id, service: .compacted(summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), reason: reason)))
            default:
                continue
            }
        }

        // What is running now.
        let live = replica.live
        // An error at the end stands unless the run goes on: then the server is asking again.
        if !replica.isBusy {
            flushError()
        }
        if let generation = live.object("generation"), let partial = generation.object("message"), let run = live.object("run"), let taskId = run.int("taskId") {
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
            rows[index].tool = tool
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
        if let compaction = live.objects("compactions").first, let taskId = compaction.int("taskId") {
            rows.append(ChatMessage(id: self.rowId(base: taskId, block: 62), role: .service, text: "", date: Date(timeIntervalSince1970: 0.0), service: .compacting(since: self.firstSeen(compaction: taskId))))
        }
        let queue = self.queue(replica: replica, items: items)
        // The agent works, or something waits for it: a message on its way is not that.
        var state = ConversationState(messages: rows, streaming: nil, busy: replica.isBusy || !queue.isEmpty, queued: queue, hasOlder: replica.hasOlder, isLoaded: replica.isSynced || !replica.entries.isEmpty)
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
    static func userContent(_ content: Any?) -> (String, [JSONObject]) {
        if let text = content as? String {
            return (text, [])
        }
        let blocks = (content as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        let text = blocks.filter { $0.string("type") == "text" }.compactMap { $0.string("text") }.joined(separator: "\n")
        return (text, blocks.filter { $0.string("type") == "image" })
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
        default:
            return .none
        }
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

/// Decodes base64 image blocks once per entry.
final class ImageDecoder {
    private var cache: [Int: UIImage] = [:]

    func image(entryId: Int, index: Int, block: JSONObject) -> UIImage? {
        let key = entryId * 64 + index
        if let image = self.cache[key] {
            return image
        }
        guard let base64 = block.string("data"), let data = Data(base64Encoded: base64), let image = UIImage(data: data) else {
            return nil
        }
        self.cache[key] = image
        return image
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
