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
        return self.live["run"] != nil || !(self.docs.object("pi.inbox")?.objects("items").isEmpty ?? true)
    }
}

/// A message the user sent that the server has not confirmed yet. It shows at once, as Telegram shows an outgoing
/// message with a clock, and keeps its row ID once it becomes an entry.
struct PendingSend {
    let rowId: Int
    let requestId: String
    let text: String
    let attachments: [MessageAttachment]
    let date: Date
    var submissionId: Int?
    var entryId: Int?
}

/// Turns entries and live docs into chat rows. Row IDs stay stable across the switch from streaming to committed: an
/// assistant row is keyed by the generation task that wrote it, which `pi.live.run.taskId` names while it streams and
/// `byTaskId` names on the entry, so the streamed row becomes the final one in place.
enum TranscriptBuilder {
    static func rowId(base: Int, block: Int) -> Int {
        return base * 64 + block
    }

    static func build(replica: ConversationReplica, pending: [PendingSend], rowIdForUserEntry: [Int: Int], images: ImageDecoder) -> ConversationState {
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

        // Sent, not yet in the transcript: queued in the inbox, or not acknowledged.
        let placedEntries = Set(replica.entries.keys)
        for send in pending where send.entryId.map({ !placedEntries.contains($0) }) ?? true {
            rows.append(ChatMessage(id: send.rowId, role: .user, text: send.text, date: send.date, attachments: send.attachments, isPending: true))
        }

        return ConversationState(messages: rows, streaming: nil, busy: replica.isBusy || !pending.isEmpty, hasOlder: replica.hasOlder, isLoaded: replica.isSynced || !replica.entries.isEmpty)
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
