import Foundation
import UIKit
import Display

/// The cards of history_search and history_read (docs/history.md, In the app): the first line is the call, below it the
/// result: what it amounts to ("9 results", "7 messages"), a line per hit or message, then what is not shown. A hit or a
/// message is a link: a tap opens its chat at it.
enum HistoryCard {
    static let searchName = "history_search"
    static let readName = "history_read"

    static func isHistory(_ name: String) -> Bool {
        return name == searchName || name == readName
    }

    /// The call, as its first line says it: what is written as written (the query, a link), in monospace, and words for
    /// the rest (`tool calls`, `this chat`, `10 older`). Only arguments that are not defaults.
    static func call(name: String, arguments: JSONObject) -> (code: String, words: String) {
        var code: [String] = []
        var words: [String] = []
        func place(_ value: String?) {
            switch value {
            case nil:
                break
            case "this"?:
                words.append("this chat")
            case "owner"?:
                words.append("owner")
            case "subagents"?:
                words.append("subagents")
            case let value?:
                code.append(value)
            }
        }
        if name == searchName {
            if let query = arguments.string("query"), !query.isEmpty {
                code.append(query)
            }
            place(arguments.string("in"))
        } else {
            place(arguments.string("link"))
        }
        if let kinds = arguments["kinds"] as? [Any] {
            words.append(contentsOf: kinds.compactMap { $0 as? String }.map(kindWords))
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
        return (code.joined(separator: " "), words.joined(separator: " "))
    }

    private static func kindWords(_ kind: String) -> String {
        switch kind {
        case "user":
            return "user"
        case "assistant":
            return "answers"
        case "reasoning":
            return "reasoning"
        case "tool_call":
            return "tool calls"
        case "tool_output":
            return "tool output"
        case "title":
            return "titles"
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

    /// The body: the result's summary line, its lines, and what is not shown. Folded: three; unfolded: all.
    static func body(name: String, output: String, isExpanded: Bool, limit: Int, textColor: UIColor, titleColor: UIColor, maxWidth: CGFloat, cuts: ClipTracker?) -> (title: String?, body: NSMutableAttributedString) {
        let body = NSMutableAttributedString()
        guard let data = output.data(using: .utf8), let result = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            if !output.isEmpty {
                body.append(NSAttributedString(string: output, font: Font.regular(12.0), textColor: textColor))
            }
            return (nil, body)
        }
        let summaryFont = Font.regular(12.0)
        func summary(_ text: String) {
            body.append(NSAttributedString(string: text, font: summaryFont, textColor: textColor))
        }
        if name == searchName {
            let hits = result.objects("hits")
            let total = result.int("total") ?? hits.count
            let floor = result.bool("complete") == false
            summary(total == 0 ? "No results" : "\(total)\(floor ? "+" : "") \(total == 1 ? "result" : "results")")
            // In one chat, the line says the part's kind; across chats, the chat.
            let chats = Set(hits.compactMap { $0.object("chat")?.string("link") })
            let shown = isExpanded ? Array(hits.prefix(limit)) : Array(hits.prefix(3))
            for hit in shown {
                body.append(NSAttributedString(string: "\n"))
                let label = chats.count <= 1 && hits.count > 1 ? kindLabel(hit.string("kind")) : (hit.object("chat")?.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled")
                let time = hit.string("time").flatMap { ISO8601DateFormatter().date(from: $0) }.map(chatListDateString) ?? ""
                body.append(line(name: label, marked: hit.string("text") ?? "", time: time, link: hit.string("link").map { highlightLink($0, text: hit.string("text") ?? "") }, textColor: textColor, titleColor: titleColor, maxWidth: maxWidth))
            }
            let more = total - shown.count
            if more > 0 {
                if isExpanded {
                    cuts?.clipped = true
                }
                body.append(NSAttributedString(string: "\n\(more)\(floor ? "+" : "") more", font: summaryFont, textColor: textColor))
            }
            return (nil, body)
        }
        // A read: a line per part, the newest at the bottom.
        let chat = result.object("chat")
        let chatLink = chat?.string("link")
        var lines: [(name: String, text: String, link: String?)] = []
        for entry in result.objects("entries") {
            let link = chatLink.flatMap { link in entry.int("id").map { "\(link)/\($0)" } }
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
                lines.append((partName(part), text, link))
            }
        }
        let messages = result.objects("entries").count
        summary(messages == 0 ? "No messages" : "\(messages) \(messages == 1 ? "message" : "messages")")
        let shown = isExpanded ? Array(lines.suffix(limit)) : Array(lines.suffix(3))
        if shown.count < lines.count {
            if isExpanded {
                cuts?.clipped = true
            }
            body.append(NSAttributedString(string: "\n\(lines.count - shown.count) earlier", font: summaryFont, textColor: textColor))
        }
        for item in shown {
            body.append(NSAttributedString(string: "\n"))
            body.append(line(name: item.name, marked: item.text, time: "", link: item.link, textColor: textColor, titleColor: titleColor, maxWidth: maxWidth))
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

    /// A hit's link with its matched words, so the chat opens at it with them marked (docs/links.md).
    private static func highlightLink(_ link: String, text: String) -> String {
        let words = marks(text).map { $0.text }
        guard !words.isEmpty, var components = URLComponents(string: link) else {
            return link
        }
        components.queryItems = [URLQueryItem(name: "q", value: Array(NSOrderedSet(array: words)).compactMap { $0 as? String }.joined(separator: " "))]
        return components.url?.absoluteString ?? link
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

    /// One line: its name in semibold 12, the text in monospace 12 with its matched words bright, cut to fit, and the
    /// time at the right in the dim color.
    private static func line(name: String, marked: String, time: String, link: String?, textColor: UIColor, titleColor: UIColor, maxWidth: CGFloat) -> NSAttributedString {
        let nameFont = Font.semibold(12.0)
        let codeFont = Font.monospace(12.0)
        let flat = marked.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        let matches = marks(flat)
        let plain = flat.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
        let timeFont = Font.regular(12.0)
        let space = NSAttributedString(string: " ", font: timeFont).size().width
        // The time and at least 8 points before it.
        let timeWidth = time.isEmpty ? 0.0 : ceil(NSAttributedString(string: time, font: timeFont).size().width) + 8.0 + space + 2.0
        func build(_ count: Int) -> NSMutableAttributedString {
            let line = NSMutableAttributedString(string: name, font: nameFont, textColor: titleColor)
            let shown = (plain as NSString).length > count ? (plain as NSString).substring(to: count) + "…" : plain
            let text = NSMutableAttributedString(string: "  " + shown, font: codeFont, textColor: textColor)
            for match in matches where match.range.location + match.range.length <= count {
                text.addAttribute(.foregroundColor, value: titleColor, range: NSRange(location: match.range.location + 2, length: match.range.length))
            }
            line.append(text)
            return line
        }
        var low = 0
        var high = (plain as NSString).length
        if build(high).size().width > maxWidth - timeWidth {
            while low < high {
                let middle = (low + high + 1) / 2
                if build(middle).size().width <= maxWidth - timeWidth {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            high = low
        }
        let line = build(high)
        if !time.isEmpty {
            // At the right: a space stretched by its kerning to the time's place, as the text node has no tab stops.
            let gap = max(8.0, floor(maxWidth - (timeWidth - 10.0 - space) - line.size().width - space - 1.0))
            line.append(NSAttributedString(string: " ", attributes: [.font: timeFont, .kern: gap]))
            line.append(NSAttributedString(string: time, font: timeFont, textColor: textColor.withAlphaComponent(0.7)))
        }
        if let link {
            line.addAttribute(MarkdownText.urlKey, value: link, range: NSRange(location: 0, length: line.length))
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
