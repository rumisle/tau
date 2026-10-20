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

        func addAssistant(content: [JSONObject], base: Int, date: Date, entryId: Int?, streaming: Bool) {
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
                    let tool = ToolCallInfo(callId: callId, name: name, summary: ToolSummary.summary(name: name, arguments: arguments), status: streaming ? .preparing : .pending, output: nil, childConversationId: nil, detail: ToolSummary.detail(name: name, arguments: arguments))
                    toolRowIndex[callId] = rows.count
                    rows.append(ChatMessage(id: rowId, role: .tool(name: name), text: "", date: date, tool: tool, isStreaming: false, entryId: entryId))
                default:
                    continue
                }
            }
        }

        for entry in replica.ordered() {
            guard let id = entry.int("id"), let kind = entry.string("kind") else {
                continue
            }
            let message = entry.objects("model").first ?? [:]
            let date = message.double("timestamp").map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()
            switch kind {
            case "pi.user":
                let (text, imageBlocks) = self.userContent(message["content"])
                let attachments = imageBlocks.enumerated().compactMap { index, block -> MessageAttachment? in
                    guard let image = images.image(entryId: id, index: index, block: block) else {
                        return nil
                    }
                    return MessageAttachment(id: id * 64 + index, kind: .image(image))
                }
                rows.append(ChatMessage(id: rowIdForUserEntry[id] ?? self.rowId(base: id, block: 0), role: .user, text: text, date: date, attachments: attachments, entryId: id))
            case "pi.assistant":
                let base = entry.int("byTaskId") ?? id
                addAssistant(content: message.objects("content"), base: base, date: date, entryId: id, streaming: false)
                if message.string("stopReason") == "error", let error = message.string("errorMessage") {
                    rows.append(ChatMessage(id: self.rowId(base: base, block: 63), role: .assistant, text: "**Error:** \(error)", date: date, entryId: id))
                }
            case "pi.tool-result":
                guard let callId = message.string("toolCallId"), let index = toolRowIndex[callId], var tool = rows[index].tool else {
                    continue
                }
                tool.status = (message.bool("isError") ?? false) ? .failed : .done
                tool.output = self.text(of: message["content"])
                if let child = (message.object("details"))?.int("conversationId") {
                    tool.childConversationId = child
                }
                // The edit tool's result carries the diff with line numbers.
                if case let .edit(path, _) = tool.detail, let diff = message.object("details")?.string("diff"), !diff.isEmpty {
                    tool.detail = .edit(path: path, diff: diff)
                }
                rows[index].tool = tool
            default:
                continue
            }
        }

        // What is running now.
        let live = replica.live
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
        let queue = self.queue(replica: replica, items: items)
        // The agent works, or something waits for it: a message on its way is not that.
        return ConversationState(messages: rows, streaming: nil, busy: replica.isBusy || !queue.isEmpty, queued: queue, hasOlder: replica.hasOlder, isLoaded: replica.isSynced || !replica.entries.isEmpty)
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
            return arguments.string("task") ?? ""
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
