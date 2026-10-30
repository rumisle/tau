import Foundation
import UIKit
import Display

/// The cards of history_search and history_read (docs/history.md, In the app): the first line is the call, below it the
/// result: a line per hit or message and what is not shown ("6 more", "2 earlier"), or "No results". A tap folds and
/// unfolds it, as any tool card.
enum HistoryCard {
    static let searchName = "history_search"
    static let readName = "history_read"

    static func isHistory(_ name: String) -> Bool {
        return name == searchName || name == readName
    }

    /// The call, as its first line says it. What it is about: a search's query and a link as written, in monospace
    /// (`plain` false), or a read's chat named in words, "This chat" until the result names it by its title. Then the
    /// other arguments that are not defaults, in words (`in subagents`, `10 older`), set apart in the dim color.
    static func call(name: String, arguments: JSONObject) -> (code: String, plain: Bool, words: String) {
        var code: [String] = []
        var plain = false
        var words: [String] = []
        if name == searchName {
            if let query = arguments.string("query"), !query.isEmpty {
                code.append(query)
            }
            switch arguments.string("in") {
            case nil:
                break
            case "this"?:
                words.append("in this chat")
            case "owner"?:
                words.append("in its owner")
            case "subagents"?:
                words.append("in subagents")
            case let link?:
                code.append(link)
            }
        } else {
            switch arguments.string("link") {
            case nil, "this"?:
                code.append("This chat")
                plain = true
            case "owner"?:
                code.append("Its owner")
                plain = true
            case let link?:
                code.append(link)
            }
        }
        // The kinds as one set, "User, Answer": an array, or one kind as a string (which the server takes too).
        var kinds = (arguments["kinds"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let one = arguments.string("kinds") {
            kinds = one.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if !kinds.isEmpty {
            words.append(kinds.map(kindWords).joined(separator: ", "))
        }
        if let sort = arguments.string("sort"), sort != "relevance" {
            words.append(sort)
        }
        if arguments.bool("exact") == false {
            words.append("fuzzy")
        }
        if let limit = arguments.int("limit"), limit != 20 {
            words.append(limit < 0 ? "all" : "\(limit) hits")
        }
        if arguments.string("cursor") != nil {
            words.append("more")
        }
        if arguments.bool("text") == false {
            words.append("links only")
        }
        if let older = arguments.int("older"), let newer = arguments.int("newer"), older == 0, newer == 0 {
            words.append("one entry")
        } else {
            if let older = arguments.int("older") {
                words.append("\(older) older")
            }
            if let newer = arguments.int("newer") {
                words.append("\(newer) newer")
            }
        }
        if arguments.bool("truncate") == false {
            words.append("whole")
        }
        return (code.joined(separator: " "), plain, words.joined(separator: "  "))
    }

    private static func kindWords(_ kind: String) -> String {
        switch kind {
        case "user":
            return "User"
        case "assistant":
            return "Answer"
        case "reasoning":
            return "Reasoning"
        case "tool_call":
            return "Tool call"
        case "tool_output":
            return "Tool output"
        case "title":
            return "Title"
        default:
            return kind
        }
    }

    /// A part's kind as a message line names it; a tool call by its tool's card title.
    private static func partName(_ part: JSONObject) -> String {
        switch part.string("kind") {
        case "user":
            return "User"
        case "reasoning":
            return "Reasoning"
        case "tool_call":
            return toolCardTitle(part.string("name") ?? "Tool")
        case "tool_output":
            return "Output"
        case "assistant":
            if part.bool("summary") == true {
                return "Summary"
            }
            return part.bool("error") == true ? "Error" : "Answer"
        default:
            return part.string("kind") ?? ""
        }
    }

    /// The body: the result's lines and what is not shown. Folded: three; unfolded: all the result has.
    static func body(name: String, output: String, isExpanded: Bool, textColor: UIColor, titleColor: UIColor, maxWidth: CGFloat) -> (title: String?, body: NSMutableAttributedString) {
        let body = NSMutableAttributedString()
        guard let data = output.data(using: .utf8), let result = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            if !output.isEmpty {
                body.append(NSAttributedString(string: output, font: Font.regular(12.0), textColor: textColor))
            }
            return (nil, body)
        }
        let summaryFont = Font.regular(12.0)
        /// A line that is not an item: "No results", "4 more", "2 earlier".
        func note(_ text: String) {
            if body.length > 0 {
                body.append(NSAttributedString(string: "\n"))
            }
            body.append(NSAttributedString(string: text, font: summaryFont, textColor: textColor))
        }
        func item(_ line: NSAttributedString) {
            if body.length > 0 {
                body.append(NSAttributedString(string: "\n"))
            }
            body.append(line)
        }
        if name == searchName {
            let hits = result.objects("hits")
            let total = result.int("total") ?? hits.count
            let floor = result.bool("complete") == false
            if hits.isEmpty {
                note(total == 0 ? "No results" : "\(total)\(floor ? "+" : "") more")
                return (nil, body)
            }
            // In one chat, the line says the part's kind; across chats, the chat.
            let chats = Set(hits.compactMap { $0.object("chat")?.string("link") })
            let shown = isExpanded ? hits : Array(hits.prefix(3))
            for hit in shown {
                let label = chats.count <= 1 && hits.count > 1 ? kindLabel(hit.string("kind")) : (hit.object("chat")?.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled")
                let time = hit.string("time").flatMap { ISO8601DateFormatter().date(from: $0) }.map(chatListDateString) ?? ""
                item(line(name: label, marked: hit.string("text") ?? "", time: time, lines: isExpanded ? 2 : 1, textColor: textColor, titleColor: titleColor, maxWidth: maxWidth))
            }
            // What is not shown: folded, the rest; unfolded, what the search has past the page it returned.
            let more = total - shown.count
            if more > 0 {
                note("\(more)\(floor ? "+" : "") more")
            }
            return (nil, body)
        }
        // A read: a line per part, the newest at the bottom.
        let chat = result.object("chat")
        var lines: [(name: String, text: String)] = []
        for entry in result.objects("entries") {
            for part in entry.objects("parts") {
                var text = part.string("text") ?? ""
                // A call's text starts with its tool's name, which the line's name says already.
                if part.string("kind") == "tool_call", let tool = part.string("name") {
                    if text.hasPrefix(tool + ": ") {
                        text = String(text.dropFirst(tool.count + 2))
                    } else if text == tool || text.hasPrefix(tool + "\n") {
                        text = String(text.dropFirst(tool.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                lines.append((partName(part), text))
            }
        }
        if lines.isEmpty {
            note("No messages")
        }
        let shown = isExpanded ? lines : Array(lines.suffix(3))
        if shown.count < lines.count {
            note("\(lines.count - shown.count) earlier")
        }
        for each in shown {
            item(line(name: each.name, marked: each.text, time: "", lines: isExpanded ? 2 : 1, textColor: textColor, titleColor: titleColor, maxWidth: maxWidth))
        }
        return (chat?.string("title").flatMap { $0.isEmpty ? nil : $0 }, body)
    }

    private static func kindLabel(_ kind: String?) -> String {
        switch kind {
        case "user":
            return "User"
        case "assistant":
            return "Answer"
        case "reasoning":
            return "Reasoning"
        case "tool_call":
            return "Call"
        case "tool_output":
            return "Output"
        case "title":
            return "Title"
        default:
            return kind ?? ""
        }
    }

    /// The matched words of an excerpt, between « and », and the text without the marks.
    private static func marks(_ text: String) -> [(range: NSRange, text: String)] {
        var found: [(NSRange, String)] = []
        var plain = ""
        var start: Int?
        for character in text {
            if character == "«" {
                start = (plain as NSString).length
            } else if character == "»", let begin = start {
                let range = NSRange(location: begin, length: (plain as NSString).length - begin)
                found.append((range, (plain as NSString).substring(with: range)))
                start = nil
            } else {
                plain.append(character)
            }
        }
        return found
    }

    /// An item: its name in semibold 12, the text in monospace 12 with its matched words bright, cut to fit `lines`
    /// lines (one folded, two unfolded), and the time at the right of the first line in the dim color.
    private static func line(name: String, marked: String, time: String, lines: Int, textColor: UIColor, titleColor: UIColor, maxWidth: CGFloat) -> NSAttributedString {
        let nameFont = Font.semibold(12.0)
        let codeFont = Font.monospace(12.0)
        let timeFont = Font.regular(12.0)
        let flat = marked.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        let matches = marks(flat)
        let plain = flat.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "") as NSString
        let space = NSAttributedString(string: " ", font: timeFont).size().width
        // The time and at least 8 points before it.
        let timeWidth = time.isEmpty ? 0.0 : ceil(NSAttributedString(string: time, font: timeFont).size().width) + 8.0 + space + 2.0
        /// `plain[from..<to]` in monospace, its matched words bright, after `prefix`, with … when cut.
        func piece(_ prefix: NSAttributedString?, from: Int, to: Int, ellipsis: Bool) -> NSMutableAttributedString {
            let line = NSMutableAttributedString()
            if let prefix {
                line.append(prefix)
            }
            let start = line.length
            line.append(NSAttributedString(string: plain.substring(with: NSRange(location: from, length: to - from)) + (ellipsis ? "…" : ""), font: codeFont, textColor: textColor))
            for match in matches {
                let lower = max(match.range.location, from)
                let upper = min(match.range.location + match.range.length, to)
                if lower < upper {
                    line.addAttribute(.foregroundColor, value: titleColor, range: NSRange(location: start + lower - from, length: upper - lower))
                }
            }
            return line
        }
        /// How much of `plain` from `from` fits `width` after `prefix`; at a space near the end when `words`.
        func fit(_ prefix: NSAttributedString?, from: Int, width: CGFloat, words: Bool) -> Int {
            if piece(prefix, from: from, to: plain.length, ellipsis: false).size().width <= width {
                return plain.length
            }
            var low = from
            var high = plain.length
            while low < high {
                let middle = (low + high + 1) / 2
                if piece(prefix, from: from, to: middle, ellipsis: !words).size().width <= width {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            if words {
                // Back to the last space, unless that loses most of the line.
                let space = plain.range(of: " ", options: .backwards, range: NSRange(location: from, length: low - from))
                if space.location != NSNotFound, low - space.location < 16 {
                    return space.location + 1
                }
            }
            return low
        }
        let prefix = NSMutableAttributedString(string: name + "  ", font: nameFont, textColor: titleColor)
        // The first line: as much as fits before the time; with a second, broken at a word.
        let firstEnd = fit(prefix, from: 0, width: maxWidth - timeWidth, words: lines > 1)
        let wraps = lines > 1 && firstEnd < plain.length
        let line = piece(prefix, from: 0, to: firstEnd, ellipsis: !wraps && firstEnd < plain.length)
        if !time.isEmpty {
            // At the right: a space stretched by its kerning to the time's place, as the text node has no tab stops.
            let gap = max(8.0, floor(maxWidth - (timeWidth - 10.0 - space) - line.size().width - space - 1.0))
            line.append(NSAttributedString(string: " ", attributes: [.font: timeFont, .kern: gap]))
            line.append(NSAttributedString(string: time, font: timeFont, textColor: textColor.withAlphaComponent(0.7)))
        }
        if wraps {
            let secondEnd = fit(nil, from: firstEnd, width: maxWidth, words: false)
            line.append(NSAttributedString(string: "\n"))
            line.append(piece(nil, from: firstEnd, to: secondEnd, ellipsis: secondEnd < plain.length))
        }
        return line
    }
}

/// A tool's name as its own card's title says it, for the lines of a script's card and a read's.
func toolCardTitle(_ name: String) -> String {
    switch name {
    case "bash":
        return "Bash"
    case "read":
        return "Read"
    case "write":
        return "Write"
    case "edit":
        return "Edit"
    case "send_file":
        return "Send"
    case "subagent":
        return "Subagent"
    case HistoryCard.searchName:
        return "History search"
    case HistoryCard.readName:
        return "History read"
    default:
        return name
    }
}
