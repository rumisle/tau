import Foundation

/// What a message quotes from the chat, in its text as the model reads it (docs/quotes.md): `<tau:quote>` around the
/// words, on lines of their own for a block, in a line for a few words. Nothing else marks them: the chat they were
/// said in is the model's context.
///
///     <tau:quote>
///     because users may type it themselves
///     </tau:quote>
///
///     ha, and what is <tau:quote>not Markdown's</tau:quote> about?
///
/// Tags inside code (a fence, a backtick span) are code; a tag never closed is text.
enum TauQuote {
    static let open = "<tau:quote>"
    static let close = "</tau:quote>"

    enum Piece: Equatable {
        case text(String)
        /// Quoted lines, on lines of their own.
        case block(String)
        /// Quoted words, in a line.
        case inline(String)
    }

    /// The quotes' words as written in a tag: a closing tag in them would end it.
    static func escape(_ text: String) -> String {
        return text.replacingOccurrences(of: self.close, with: "&lt;/tau:quote>")
    }

    static func unescape(_ text: String) -> String {
        return text.replacingOccurrences(of: "&lt;/tau:quote>", with: self.close)
    }

    /// Whether the text might hold a quote, before parsing it.
    static func mayContain(_ text: String) -> Bool {
        return text.contains(self.open)
    }

    /// The text's pieces, in order: what joins them back is `serialize`.
    static func parse(_ text: String) -> [Piece] {
        guard self.mayContain(text) else {
            return [.text(text)]
        }
        var pieces: [Piece] = []
        var pending = ""
        func flush() {
            if !pending.isEmpty {
                pieces.append(.text(pending))
                pending = ""
            }
        }
        let lines = text.components(separatedBy: "\n")
        var fence: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isLast = index == lines.count - 1
            if let current = fence {
                if trimmed.hasPrefix(current) {
                    fence = nil
                }
                pending += line + (isLast ? "" : "\n")
                index += 1
                continue
            }
            if let marker = self.fenceMarker(trimmed) {
                fence = marker
                pending += line + (isLast ? "" : "\n")
                index += 1
                continue
            }
            if trimmed == self.open, let end = self.blockEnd(lines, from: index + 1) {
                flush()
                pieces.append(.block(self.unescape(lines[(index + 1) ..< end].joined(separator: "\n"))))
                // The line break after the closing tag stays with the text after it.
                if end < lines.count - 1 {
                    pending = "\n"
                }
                index = end + 1
                continue
            }
            for piece in self.inlinePieces(line) {
                switch piece {
                case let .text(value):
                    pending += value
                default:
                    flush()
                    pieces.append(piece)
                }
            }
            if !isLast {
                pending += "\n"
            }
            index += 1
        }
        flush()
        return pieces
    }

    /// The text the pieces make; a block gets lines of its own when what is beside it does not end or begin one.
    static func serialize(_ pieces: [Piece]) -> String {
        var result = ""
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case let .text(value):
                if index > 0, case .block = pieces[index - 1], !value.hasPrefix("\n") {
                    result += "\n"
                }
                result += value
            case let .block(value):
                if !result.isEmpty, !result.hasSuffix("\n") {
                    result += "\n"
                }
                if index > 0, case .block = pieces[index - 1] {
                    result += "\n"
                }
                result += self.open + "\n" + self.escape(value) + "\n" + self.close
            case let .inline(value):
                result += self.open + self.escape(value) + self.close
            }
        }
        return result
    }

    /// For a one-line preview: the message's own words, a block left out (unless it is all there is), a few quoted
    /// words as they are.
    static func withoutQuotes(_ text: String) -> String {
        let pieces = self.parse(text)
        guard pieces.contains(where: { if case .text = $0 { return false } else { return true } }) else {
            return text
        }
        var own = ""
        var quoted = ""
        for piece in pieces {
            switch piece {
            case let .text(value):
                own += value
            case let .inline(value):
                own += value
            case let .block(value):
                quoted += (quoted.isEmpty ? "" : "\n") + value
            }
        }
        return own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? quoted : own
    }

    /// As Markdown, for copying the message somewhere else: a block as `>` lines, a few words in quotation marks.
    static func markdown(_ text: String) -> String {
        let pieces = self.parse(text)
        guard pieces.contains(where: { if case .text = $0 { return false } else { return true } }) else {
            return text
        }
        return self.serialize(pieces.map { piece in
            switch piece {
            case .text:
                return piece
            case let .block(value):
                return .text(value.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
            case let .inline(value):
                return .text("“\(value)”")
            }
        }).replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") {
            return "```"
        }
        if trimmed.hasPrefix("~~~") {
            return "~~~"
        }
        return nil
    }

    /// The line of the closing tag of a block opened just before `start`, outside any code in it.
    private static func blockEnd(_ lines: [String], from start: Int) -> Int? {
        var fence: String?
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if trimmed.hasPrefix(current) {
                    fence = nil
                }
            } else if let marker = self.fenceMarker(trimmed) {
                fence = marker
            } else if trimmed == self.close {
                return index
            }
            index += 1
        }
        return nil
    }

    /// A line's few quoted words, outside backtick spans.
    private static func inlinePieces(_ line: String) -> [Piece] {
        guard line.contains(self.open) else {
            return [.text(line)]
        }
        var pieces: [Piece] = []
        var text = ""
        var rest = Substring(line)
        var inCode = false
        while !rest.isEmpty {
            if !inCode, rest.hasPrefix(self.open), let end = rest.range(of: self.close), !rest[rest.index(rest.startIndex, offsetBy: self.open.count) ..< end.lowerBound].contains("`") {
                let value = String(rest[rest.index(rest.startIndex, offsetBy: self.open.count) ..< end.lowerBound])
                if !text.isEmpty {
                    pieces.append(.text(text))
                    text = ""
                }
                pieces.append(.inline(self.unescape(value)))
                rest = rest[end.upperBound...]
                continue
            }
            let character = rest.removeFirst()
            if character == "`" {
                inCode.toggle()
            }
            text.append(character)
        }
        if !text.isEmpty {
            pieces.append(.text(text))
        }
        return pieces
    }
}
