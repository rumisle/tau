import UIKit
import libprisma
import Display

/// Styles for one surface: a bubble, or the assistant's bubble-less text.
struct MarkdownStyle {
    var fontSize: CGFloat
    var textColor: UIColor
    var linkColor: UIColor
    var accentColor: UIColor
    /// The text column, which display formulas shrink to fit.
    var maxWidth: CGFloat = 0.0
    /// Typeset `$...$` LaTeX: in answers, not in what the user writes.
    var math: Bool = true
    /// The line spacing InteractiveTextNode lays the text out with, a fraction of each line's height: the space between
    /// paragraphs is sized for it.
    var lineSpacing: CGFloat = 0.12
    /// Answers: a line and a half (InteractiveTextNode's 0.12 makes 1.32 em of the system font, close for Latin, tight for
    /// Han, whose square characters fill their em box).
    static let answerLineSpacing: CGFloat = 0.231

    /// Light text: a dark theme.
    var isDark: Bool {
        var white: CGFloat = 0.0
        self.textColor.getWhite(&white, alpha: nil)
        return white > 0.5
    }
}

/// A rendered table: header cells, then body rows, each cell already styled.
struct MarkdownTable: Equatable {
    var header: [NSAttributedString]
    var rows: [[NSAttributedString]]
    /// Each column's, as the delimiter row has it (`---:` right): numbers line up at their ends.
    var alignments: [NSTextAlignment] = []

    var columnCount: Int {
        return max(self.header.count, self.rows.map(\.count).max() ?? 0)
    }

    /// Characters the table contributes to a streaming reveal count.
    var characterCount: Int {
        return (self.header + self.rows.flatMap { $0 }).reduce(0) { $0 + $1.length }
    }
}

enum MarkdownBlock {
    case text(NSAttributedString)
    case table(MarkdownTable)
    /// A code block on its own, laid out without wrapping: with code wrapping off, it scrolls sideways.
    case code(NSAttributedString)

    var characterCount: Int {
        switch self {
        case let .text(string), let .code(string):
            return string.length
        case let .table(table):
            return table.characterCount
        }
    }
}

/// Markdown to what Telegram's InteractiveTextNode renders: fenced code and block quotes become `Attribute__Blockquote`
/// ranges carrying `TextNodeBlockQuoteData`, as Telegram's `pre` and `blockquote` entities do
/// (TextFormat/Sources/StringWithAppliedEntities.swift). Tables, which InteractiveTextNode cannot draw, come out as their
/// own blocks. Parsing is Foundation's CommonMark parser, which tolerates the unclosed constructs of a half-streamed
/// answer.
enum MarkdownText {
    static let blockQuoteKey = NSAttributedString.Key("Attribute__Blockquote")
    static let urlKey = NSAttributedString.Key("Attribute__Url")
    /// Inline code's text, which a tap copies (Telegram's TelegramTextAttributes.Code).
    static let inlineCodeKey = NSAttributedString.Key("TelegramCode")
    /// A list item's hanging indent, which InteractiveTextNode lays its lines out with (tau's patch): NSValue of a CGSize,
    /// the first line's offset and the other lines'.
    static let indentKey = NSAttributedString.Key("Attribute__Indent")
    /// Paragraphs that do not end on a line with one Han character (InteractiveTextNode, tau's patch).
    static let avoidsOrphansKey = NSAttributedString.Key("Attribute__AvoidsOrphans")
    /// A heading's level, on its text: the space around it.
    static let headingKey = NSAttributedString.Key("tau.heading")
    /// What a character typeset in place of another was (a curly quote, a centered ellipsis): copying gives it back.
    static let originalKey = NSAttributedString.Key("tau.original")

    /// A tau link's card (docs/links.md), as Telegram quotes a message: the chat's title over its words, in a quote
    /// block, all of it the link.
    static func reference(_ reference: LinkReference, style: MarkdownStyle) -> NSAttributedString {
        var text = reference.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if text.count > 140 {
            text = String(text.prefix(140)).trimmingCharacters(in: .whitespaces) + "…"
        }
        let fontSize = floor(style.fontSize * 15.0 / 17.0)
        let string = NSMutableAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: Font.regular(fontSize), .foregroundColor: style.textColor])
        let title = NSAttributedString(string: reference.title, font: Font.semibold(fontSize), textColor: style.accentColor)
        let data = TextNodeBlockQuoteData(kind: .quote, title: title, color: style.accentColor, secondaryColor: nil, tertiaryColor: nil, backgroundColor: style.accentColor.withMultipliedAlpha(0.1), isCollapsible: false)
        let range = NSRange(location: 0, length: string.length)
        string.addAttribute(self.blockQuoteKey, value: data, range: range)
        string.addAttribute(self.urlKey, value: reference.url, range: range)
        return string
    }

    /// The whole message as one attributed string, tables included as plain rows.
    static func render(_ text: String, style: MarkdownStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in self.blocks(text, style: style) {
            if result.length > 0 {
                result.append(self.gap(style.fontSize * Spacing.paragraph, style: style))
            }
            switch block {
            case let .text(string), let .code(string):
                result.append(string)
            case let .table(table):
                for (index, row) in ([table.header] + table.rows).enumerated() {
                    if index > 0 {
                        result.append(NSAttributedString(string: "\n"))
                    }
                    let line = NSMutableAttributedString()
                    for (cellIndex, cell) in row.enumerated() {
                        if cellIndex > 0 {
                            line.append(NSAttributedString(string: " | ", font: Font.regular(style.fontSize), textColor: style.textColor))
                        }
                        line.append(cell)
                    }
                    result.append(line)
                }
            }
        }
        return result
    }

    /// Parsed messages, keyed by text and style. Foundation's Markdown parser is slow, and a row lays out again on every
    /// streaming step, selection change and theme change. Layout runs on background queues, hence the lock.
    private static let cacheLock = NSLock()
    private static var cache: [String: [MarkdownBlock]] = [:]
    private static var cacheOrder: [String] = []

    /// The message's blocks. A long message is parsed in chunks split at paragraph breaks that cannot change how
    /// either side reads: while an answer streams only its last chunk is new, so each step parses and lays out one
    /// chunk, not the whole answer, and the finished chunks keep their cached parse and layout.
    static func blocks(_ text: String, style: MarkdownStyle, wrapCode: Bool = true) -> [MarkdownBlock] {
        let chunks = self.chunks(text)
        let blocks = chunks.count == 1 ? self.chunkBlocks(text, style: style) : chunks.flatMap { self.chunkBlocks($0, style: style) }
        return wrapCode ? blocks : blocks.flatMap(self.separateCode)
    }

    /// A text block split around its code blocks, each of which becomes a `.code` block. The newlines between the
    /// pieces go; the blocks' own spacing replaces them.
    private static func separateCode(_ block: MarkdownBlock) -> [MarkdownBlock] {
        guard case let .text(string) = block else {
            return [block]
        }
        var codeRanges: [NSRange] = []
        string.enumerateAttribute(blockQuoteKey, in: NSRange(location: 0, length: string.length), options: []) { value, range, _ in
            if let data = value as? TextNodeBlockQuoteData, case .code = data.kind {
                codeRanges.append(range)
            }
        }
        guard !codeRanges.isEmpty else {
            return [block]
        }
        let nsString = string.string as NSString
        var result: [MarkdownBlock] = []
        func appendText(_ range: NSRange) {
            var start = range.location
            var end = range.location + range.length
            while start < end, nsString.character(at: start) == 0x0a {
                start += 1
            }
            while end > start, nsString.character(at: end - 1) == 0x0a {
                end -= 1
            }
            if end > start {
                result.append(.text(string.attributedSubstring(from: NSRange(location: start, length: end - start))))
            }
        }
        var cursor = 0
        for range in codeRanges {
            appendText(NSRange(location: cursor, length: range.location - cursor))
            result.append(.code(string.attributedSubstring(from: range)))
            cursor = range.location + range.length
        }
        appendText(NSRange(location: cursor, length: string.length - cursor))
        return result
    }

    /// Chunks of about `chunkLength` characters or more. A break is a blank line outside a code fence whose next line
    /// starts a heading, a fence or a plain paragraph: not a list item, quote, table row or indented line, which may
    /// continue what came before (a list's numbering, a quote, a table).
    private static let chunkLength = 1200

    static func chunks(_ text: String) -> [String] {
        let utf16 = text.utf16
        guard utf16.count > chunkLength * 2 else {
            return [text]
        }
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var current: [String] = []
        var currentLength = 0
        var inFence = false
        var previousBlank = false
        func startsSafely(_ line: String) -> Bool {
            guard let first = line.first else {
                return false
            }
            if line.hasPrefix("#") || line.hasPrefix("```") || line.hasPrefix("~~~") {
                return true
            }
            if first == " " || first == "\t" || first == ">" || first == "|" || first == "-" || first == "*" || first == "+" || first == "$" || first == "\\" {
                return false
            }
            // "1." or "1)" starts an ordered list item.
            let digits = line.prefix(while: { $0.isNumber })
            if !digits.isEmpty, let next = line.dropFirst(digits.count).first, next == "." || next == ")" {
                return false
            }
            return true
        }
        for line in lines {
            let isFence = line.hasPrefix("```") || line.hasPrefix("~~~")
            if !inFence && previousBlank && currentLength >= chunkLength && startsSafely(line) {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentLength = 0
            }
            current.append(line)
            currentLength += line.utf16.count + 1
            if isFence {
                inFence.toggle()
            }
            previousBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }

    private static func chunkBlocks(_ text: String, style: MarkdownStyle) -> [MarkdownBlock] {
        let key = "\(style.fontSize)|\(style.textColor.argb)|\(style.linkColor.argb)|\(style.accentColor.argb)|\(style.maxWidth)|\(style.math)|\(style.lineSpacing)|\(text)"
        self.cacheLock.lock()
        if let cached = self.cache[key] {
            self.cacheLock.unlock()
            return cached
        }
        self.cacheLock.unlock()
        let result = self.parseBlocks(text, style: style).map { self.linkified($0, style: style) }
        self.cacheLock.lock()
        self.cache[key] = result
        self.cacheOrder.append(key)
        if self.cacheOrder.count > 400 {
            self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
        }
        self.cacheLock.unlock()
        return result
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Addresses written out, which CommonMark leaves as text, as links, as Telegram finds them in a message's text: those
    /// with a scheme or `www.`, and mail. A file's name that reads like a domain (`README.md`) stays text, and code
    /// keeps what it says.
    private static func linkified(_ block: MarkdownBlock, style: MarkdownStyle) -> MarkdownBlock {
        guard case let .text(string) = block, let detector = self.linkDetector else {
            return block
        }
        let text = string.string as NSString
        guard text.range(of: "://").location != NSNotFound || text.range(of: "www.").location != NSNotFound || text.range(of: "@").location != NSNotFound else {
            return block
        }
        var result: NSMutableAttributedString?
        // tau's own links too (docs/links.md), which the detector does not know.
        let found: [(NSRange, URL)] = detector.matches(in: string.string, range: NSRange(location: 0, length: text.length)).compactMap { match in
            match.url.map { (match.range, $0) }
        } + LinkReferenceResolver.links(in: string.string).compactMap { link in
            URL(string: link).map { (text.range(of: link), $0) }
        }
        for (range, url) in found {
            guard let scheme = url.scheme?.lowercased() else {
                continue
            }
            let written = text.substring(with: range).lowercased()
            let isMail = scheme == "mailto"
            guard isMail || scheme == "tau" || ((scheme == "http" || scheme == "https") && (written.contains("://") || written.hasPrefix("www."))) else {
                continue
            }
            let match = (range: range, url: url)
            var taken = false
            string.enumerateAttributes(in: match.range, options: []) { attributes, _, stop in
                if attributes[self.urlKey] != nil || attributes[self.inlineCodeKey] != nil {
                    taken = true
                } else if let quote = attributes[self.blockQuoteKey] as? TextNodeBlockQuoteData, case .code = quote.kind {
                    taken = true
                }
                if taken {
                    stop.pointee = true
                }
            }
            if taken {
                continue
            }
            let mutable = result ?? NSMutableAttributedString(attributedString: string)
            mutable.addAttribute(self.urlKey, value: url.absoluteString, range: match.range)
            mutable.addAttribute(.foregroundColor, value: style.linkColor, range: match.range)
            result = mutable
        }
        return result.map { .text($0) } ?? block
    }

    /// GitHub's task list items, `- [ ]` and `- [x]`, which CommonMark reads as text: boxes in their place.
    private static let taskPattern = try! NSRegularExpression(pattern: "^(\\s*[-*+] )\\[([ xX])\\] ", options: [.anchorsMatchLines])

    private static func taskBoxes(_ text: String) -> String {
        guard text.contains("] ") else {
            return text
        }
        let mutable = NSMutableString(string: text)
        for match in self.taskPattern.matches(in: text, range: NSRange(location: 0, length: mutable.length)).reversed() {
            let checked = (text as NSString).substring(with: match.range(at: 2)) != " "
            let prefix = (text as NSString).substring(with: match.range(at: 1))
            mutable.replaceCharacters(in: match.range, with: prefix + (checked ? "☑︎ " : "☐ "))
        }
        return mutable as String
    }

    private static func parseBlocks(_ rawText: String, style: MarkdownStyle) -> [MarkdownBlock] {
        let (text, formulas) = style.math ? MathText.extract(self.taskBoxes(rawText)) : (self.taskBoxes(rawText), [])
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [.text(NSAttributedString(string: text, font: Font.regular(style.fontSize), textColor: style.textColor))]
        }
        let fonts = Fonts(size: style.fontSize)

        var blocks: [MarkdownBlock] = []
        var current = NSMutableAttributedString()
        var table: (identity: Int, header: [NSMutableAttributedString], rows: [[NSMutableAttributedString]], alignments: [NSTextAlignment])?
        let listMarkers = self.listMarkerWidths(parsed, fonts: fonts)
        /// The list item paragraph being built: where it starts, and its indent.
        var currentIndent: (start: Int, value: CGSize)?
        /// List items given their marker, so a later paragraph of the same item hangs without one.
        var markedItems = Set<Int>()

        func closeIndent() {
            guard let indent = currentIndent else {
                return
            }
            currentIndent = nil
            if current.length > indent.start {
                current.addAttribute(indentKey, value: NSValue(cgSize: indent.value), range: NSRange(location: indent.start, length: current.length - indent.start))
            }
        }
        var previousBlock: PresentationIntent?
        var currentBlockQuote: (kind: TextNodeBlockQuoteData.Kind, start: Int, identity: Int)?

        func closeBlockQuote() {
            guard let quote = currentBlockQuote else {
                return
            }
            currentBlockQuote = nil
            // A block must not end with a newline, or the renderer draws an empty line inside it.
            var end = current.length
            while end > quote.start, (current.string as NSString).character(at: end - 1) == 0x0a {
                end -= 1
            }
            guard end > quote.start else {
                return
            }
            // StringWithAppliedEntities.swift: a code block is titled with its language; colors as
            // ChatMessageTextBubbleContentNode gives an incoming message's blocks.
            var title: NSAttributedString?
            var backgroundColor = style.accentColor.withMultipliedAlpha(0.1)
            if case let .code(language) = quote.kind {
                // Every block says what it is; one without a language is plain text.
                let name = language.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
                title = NSAttributedString(string: name.map(self.languageName) ?? "Plain", font: fonts.bold.withSize(round(fonts.bold.pointSize * 0.8235294117647058)), textColor: style.accentColor)
                backgroundColor = style.isDark ? UIColor(white: 0.0, alpha: 0.65) : UIColor(white: 0.0, alpha: 0.05)
            }
            let data = TextNodeBlockQuoteData(
                kind: quote.kind,
                title: title,
                color: style.accentColor,
                secondaryColor: nil,
                tertiaryColor: nil,
                backgroundColor: backgroundColor,
                isCollapsible: false
            )
            let range = NSRange(location: quote.start, length: end - quote.start)
            current.addAttribute(blockQuoteKey, value: data, range: range)
            if case let .code(language) = quote.kind {
                if let language {
                    highlight(current, range: range, language: language, style: style, fonts: fonts)
                }
                let isDiff = language.map { ["diff", "patch"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) } ?? false
                let grown = keepIndentation(current, range: range, diff: isDiff)
                if grown > 0 {
                    // The block's attribute over its tabs' spaces too.
                    current.addAttribute(blockQuoteKey, value: data, range: NSRange(location: range.location, length: range.length + grown))
                }
                if isDiff {
                    self.markDiffLines(current, range: NSRange(location: range.location, length: range.length + grown), dark: style.isDark)
                }
            }
        }

        func flushText() {
            closeIndent()
            closeBlockQuote()
            if current.length > 0 {
                self.typeset(current, style: style)
                blocks.append(.text(current))
            }
            current = NSMutableAttributedString()
        }

        func flushTable() {
            guard let value = table else {
                return
            }
            table = nil
            for cell in value.header + value.rows.flatMap({ $0 }) {
                self.typeset(cell, style: style, orphans: false)
                // Figures of one width, so a column's numbers line up.
                cell.enumerateAttribute(.font, in: NSRange(location: 0, length: cell.length), options: []) { font, range, _ in
                    if let font = font as? UIFont {
                        cell.addAttribute(.font, value: self.tabularFigures(font), range: range)
                    }
                }
            }
            blocks.append(.table(MarkdownTable(header: value.header, rows: value.rows, alignments: value.alignments)))
        }

        /// A run's text, with formulas back in place of their placeholders.
        func styled(_ string: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
            guard !formulas.isEmpty else {
                return NSAttributedString(string: string, attributes: attributes)
            }
            let result = NSMutableAttributedString()
            let units = Array(string.utf16)
            var start = 0
            for (offset, unit) in units.enumerated() {
                guard let index = MathText.placeholderIndex(unit), index < formulas.count else {
                    continue
                }
                if offset > start {
                    result.append(NSAttributedString(string: String(utf16CodeUnits: Array(units[start ..< offset]), count: offset - start), attributes: attributes))
                }
                let formula = formulas[index]
                if let attachment = MathText.attachment(formula, fontSize: style.fontSize, attributes: attributes, maxWidth: style.maxWidth) {
                    result.append(attachment)
                } else {
                    // What SwiftMath cannot typeset shows as written.
                    let delimiter = formula.display ? "$$" : "$"
                    result.append(NSAttributedString(string: delimiter + formula.latex + delimiter, attributes: attributes))
                }
                start = offset + 1
            }
            if start < units.count {
                result.append(NSAttributedString(string: String(utf16CodeUnits: Array(units[start...]), count: units.count - start), attributes: attributes))
            }
            return result
        }

        for run in parsed.runs {
            let intent = run.presentationIntent
            let attributes = self.inlineAttributes(run: run, intent: intent, style: style, fonts: fonts)
            var runText = String(parsed[run.range].characters)

            if let cell = tableCell(intent) {
                if table?.identity != cell.tableIdentity {
                    flushTable()
                    flushText()
                    previousBlock = nil
                    table = (cell.tableIdentity, [], [], cell.alignments)
                }
                let string = styled(runText, attributes: attributes)
                if cell.row == nil {
                    while table!.header.count <= cell.column {
                        table!.header.append(NSMutableAttributedString())
                    }
                    table!.header[cell.column].append(string)
                    table!.header[cell.column].addAttribute(.font, value: fonts.bold, range: NSRange(location: 0, length: table!.header[cell.column].length))
                } else if let row = cell.row {
                    while table!.rows.count <= row {
                        table!.rows.append([])
                    }
                    while table!.rows[row].count <= cell.column {
                        table!.rows[row].append(NSMutableAttributedString())
                    }
                    table!.rows[row][cell.column].append(string)
                }
                continue
            }
            if table != nil {
                flushTable()
            }

            if intent != previousBlock {
                closeIndent()
                let blockQuote = blockQuoteKind(intent)
                if let quote = currentBlockQuote, blockQuote?.identity != quote.identity {
                    closeBlockQuote()
                }
                if current.length > 0 {
                    current.append(self.separator(between: previousBlock, and: intent, style: style))
                }
                if let blockQuote, currentBlockQuote == nil {
                    currentBlockQuote = (blockQuote.kind, current.length, blockQuote.identity)
                }
                previousBlock = intent
                if isThematicBreak(intent) {
                    // `---`: a hairline across the column, instead of the parser's "⸻".
                    current.append(self.rule(style: style))
                    continue
                }
                if let item = self.listItem(intent, markers: listMarkers, fonts: fonts) {
                    if let marker = item.marker, !markedItems.contains(item.identity) {
                        markedItems.insert(item.identity)
                        current.append(NSAttributedString(string: marker, font: fonts.regular, textColor: style.textColor))
                        currentIndent = (current.length - (marker as NSString).length, CGSize(width: item.first, height: item.rest))
                    } else {
                        currentIndent = (current.length, CGSize(width: item.rest, height: item.rest))
                    }
                }
            } else if isThematicBreak(intent) {
                continue
            }
            if isCodeBlock(intent), runText.hasSuffix("\n") {
                runText.removeLast()
            }
            current.append(styled(runText, attributes: attributes))
        }
        flushTable()
        flushText()
        return blocks
    }

    /// Telegram's code block highlighting: libprisma (copied), Prism's grammars in C++, colors a fenced block by its
    /// language, as StringWithAppliedEntities.swift applies its `MessageSyntaxHighlight` entities.
    private static let syntaxer = Syntaxer()
    private static let syntaxerLock = NSLock()

    private static func highlight(_ string: NSMutableAttributedString, range: NSRange, language: String, style: MarkdownStyle, fonts: Fonts) {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !language.isEmpty, let syntaxer = self.syntaxer else {
            return
        }
        let code = (string.string as NSString).substring(with: range)
        let theme = SyntaxterTheme(dark: style.isDark, textColor: style.textColor, textFont: fonts.monospace, italicFont: fonts.monospace, mediumFont: fonts.monospace)
        self.syntaxerLock.lock()
        let highlighted = syntaxer.syntax(code, language: language, theme: theme)
        self.syntaxerLock.unlock()
        guard let highlighted, highlighted.length == range.length else {
            return
        }
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length), using: { value, subRange, _ in
            if let color = value as? UIColor {
                string.addAttribute(.foregroundColor, value: color, range: NSRange(location: range.location + subRange.location, length: subRange.length))
            }
        })
    }

    static let lineBackgroundKey = NSAttributedString.Key("Attribute__LineBackground")

    /// A diff's added lines on green and removed ones on red, as GitHub shows them; its headers (`+++`, `---`) plain.
    private static func markDiffLines(_ string: NSMutableAttributedString, range: NSRange, dark: Bool) {
        let added = UIColor(rgb: 0x34C759).withAlphaComponent(dark ? 0.18 : 0.16)
        let removed = UIColor(rgb: 0xFF3B30).withAlphaComponent(dark ? 0.18 : 0.13)
        let text = string.string as NSString
        var start = range.location
        let end = range.location + range.length
        while start < end {
            var lineEnd = start
            while lineEnd < end, text.character(at: lineEnd) != 0x0a {
                lineEnd += 1
            }
            // Without the word joiner after a line's mark (keepIndentation).
            let line = text.substring(with: NSRange(location: start, length: lineEnd - start)).replacingOccurrences(of: "\u{2060}", with: "")
            var color: UIColor?
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                color = added
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                color = removed
            }
            if let color, lineEnd > start {
                string.addAttribute(lineBackgroundKey, value: color, range: NSRange(location: start, length: lineEnd - start))
            }
            start = lineEnd + 1
        }
    }

    /// A code block's title: its language as written in its name.
    private static func languageName(_ language: String) -> String {
        let names: [String: String] = [
            "json": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "xml": "XML", "html": "HTML", "css": "CSS",
            "sql": "SQL", "js": "JavaScript", "javascript": "JavaScript", "jsx": "JSX", "ts": "TypeScript",
            "typescript": "TypeScript", "tsx": "TSX", "sh": "Shell", "shell": "Shell", "zsh": "Zsh", "bash": "Bash",
            "cpp": "C++", "c++": "C++", "cs": "C#", "csharp": "C#", "objc": "Objective-C", "objectivec": "Objective-C",
            "objective-c": "Objective-C", "py": "Python", "python": "Python", "rb": "Ruby", "md": "Markdown",
            "graphql": "GraphQL", "php": "PHP", "ini": "INI", "csv": "CSV", "latex": "LaTeX", "tex": "TeX",
            "nix": "Nix", "lua": "Lua", "go": "Go", "rust": "Rust", "swift": "Swift", "kotlin": "Kotlin", "java": "Java",
            "diff": "Diff", "dockerfile": "Dockerfile", "makefile": "Makefile", "c": "C", "text": "Text", "txt": "Text",
        ]
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return names[key] ?? (key.count <= 3 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst())
    }

    /// Prism's language for a file, by its extension.
    static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" {
            return "docker"
        }
        if name == "makefile" {
            return "makefile"
        }
        switch (name as NSString).pathExtension {
        case "swift": return "swift"
        case "py": return "python"
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "tsx"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "jsx"
        case "json": return "json"
        case "md": return "markdown"
        case "sh", "bash", "zsh": return "bash"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp", "mm": return "cpp"
        case "m": return "objectivec"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "rb": return "ruby"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "html", "xml", "plist", "svg": return "markup"
        case "css": return "css"
        case "sql": return "sql"
        case "lua": return "lua"
        case "nix": return "nix"
        default: return nil
        }
    }

    /// Code in one font and color, highlighted as `language` when libprisma knows it, indentation kept.
    static func code(_ code: String, language: String?, font: UIFont, textColor: UIColor) -> NSAttributedString {
        let string = NSMutableAttributedString(string: code, font: font, textColor: textColor)
        let range = NSRange(location: 0, length: string.length)
        if let language {
            let style = MarkdownStyle(fontSize: font.pointSize, textColor: textColor, linkColor: textColor, accentColor: textColor)
            highlight(string, range: range, language: language, style: style, fonts: Fonts(size: font.pointSize, monospace: font))
        }
        keepIndentation(string, range: range)
        return string
    }

    /// InteractiveTextNode drops the spaces a line starts with, which in code is indentation. No-break spaces in their
    /// place keep it, a tab four of them (copied as the tab); spaces inside a line stay, so long lines still wrap
    /// between words. A line that wraps goes on two characters further in than it starts, as editors wrap code.
    /// Returns the change in length.
    /// In a diff, a line's first character is its mark (`+`, `-`, a space), and its indentation comes after it.
    @discardableResult
    private static func keepIndentation(_ string: NSMutableAttributedString, range: NSRange, diff: Bool = false) -> Int {
        let text = string.string as NSString
        var lines: [(start: Int, indent: Int)] = []
        /// Characters that become more: a tab four spaces (copied as the tab), a diff's `+` or `-` itself and a word
        /// joiner (copied as nothing), which keeps the line from breaking after its mark.
        var expansions: [(index: Int, grows: Int)] = []
        var atLineStart = true
        var lineStart = range.location
        var indent = 0
        for index in range.location ..< range.location + range.length {
            let character = text.character(at: index)
            if character == 0x0a {
                lines.append((lineStart, indent))
                atLineStart = true
                lineStart = index + 1
                indent = 0
            } else if diff && index == lineStart && (character == 0x2b || character == 0x2d || character == 0x20) {
                if character == 0x20 {
                    string.replaceCharacters(in: NSRange(location: index, length: 1), with: "\u{00A0}")
                } else {
                    expansions.append((index, 1))
                }
                indent += 1
            } else if atLineStart && character == 0x20 {
                string.replaceCharacters(in: NSRange(location: index, length: 1), with: "\u{00A0}")
                indent += 1
            } else if atLineStart && character == 0x09 {
                expansions.append((index, 3))
                indent += 4
            } else {
                atLineStart = false
            }
        }
        lines.append((lineStart, indent))
        // From the end, so the indices before stay.
        for expansion in expansions.reversed() {
            var attributes = string.attributes(at: expansion.index, effectiveRange: nil)
            let character = (string.string as NSString).substring(with: NSRange(location: expansion.index, length: 1))
            let replacement: NSMutableAttributedString
            if character == "\t" {
                attributes[originalKey] = "\t"
                replacement = NSMutableAttributedString(string: "\u{00A0}", attributes: attributes)
                attributes[originalKey] = ""
                replacement.append(NSAttributedString(string: "\u{00A0}\u{00A0}\u{00A0}", attributes: attributes))
            } else {
                replacement = NSMutableAttributedString(string: character, attributes: attributes)
                attributes[originalKey] = ""
                replacement.append(NSAttributedString(string: "\u{2060}", attributes: attributes))
            }
            string.replaceCharacters(in: NSRange(location: expansion.index, length: 1), with: replacement)
        }
        var shift = 0
        var cursor = 0
        for line in lines {
            while cursor < expansions.count, expansions[cursor].index < line.start {
                shift += expansions[cursor].grows
                cursor += 1
            }
            let start = line.start + shift
            let font = (start < string.length ? string.attribute(.font, at: start, effectiveRange: nil) as? UIFont : nil) ?? Font.monospace(15.0)
            let column = self.width("0", font: font)
            var end = start
            let current = string.string as NSString
            while end < current.length, current.character(at: end) != 0x0a {
                end += 1
            }
            if end > start {
                string.addAttribute(indentKey, value: NSValue(cgSize: CGSize(width: 0.0, height: CGFloat(line.indent + 2) * column)), range: NSRange(location: start, length: end - start))
            }
        }
        return expansions.reduce(0) { $0 + $1.grows }
    }

    private struct Fonts {
        let regular: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
        let monospace: UIFont
        let inlineCode: UIFont

        init(size: CGFloat, monospace: UIFont? = nil) {
            self.regular = Font.regular(size)
            self.bold = Font.semibold(size)
            self.italic = Font.italic(size)
            self.boldItalic = Font.semiboldItalic(size)
            // Code a little smaller than the text: monospace looks larger at the same size. Inline, 16 at 17, to sit with
            // the text; in blocks 15, so a line fits more of it.
            self.monospace = monospace ?? Font.monospace(round(size * 0.88))
            self.inlineCode = Font.monospace(round(size * 16.0 / 17.0))
        }
    }

    private static func inlineAttributes(run: AttributedString.Runs.Run, intent: PresentationIntent?, style: MarkdownStyle, fonts: Fonts) -> [NSAttributedString.Key: Any] {
        var font = fonts.regular
        var color = style.textColor
        var attributes: [NSAttributedString.Key: Any] = [:]
        if isCodeBlock(intent) {
            font = fonts.monospace
        } else if let level = headerLevel(intent) {
            // H1 24, H2 21, H3 19 at 17: apart from the text by size; H4 its size, H5 and H6 smaller, H6 dimmer.
            let scales: [CGFloat] = [24.0, 21.0, 19.0, 17.0, 15.0, 15.0]
            font = Font.semibold(round(style.fontSize * scales[min(max(level, 1), 6) - 1] / 17.0))
            attributes[headingKey] = level
            if level >= 6 {
                color = style.textColor.withMultipliedAlpha(0.6)
            }
        } else if let inline = run.inlinePresentationIntent {
            if inline.contains(.code) {
                // Monospace looks larger than the text at its size; a little smaller sits with it.
                font = fonts.inlineCode
                attributes[inlineCodeKey] = "code"
            } else if inline.contains(.stronglyEmphasized) && inline.contains(.emphasized) {
                font = fonts.boldItalic
            } else if inline.contains(.stronglyEmphasized) {
                font = fonts.bold
            } else if inline.contains(.emphasized) {
                font = fonts.italic
            }
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        if let link = run.link {
            color = style.linkColor
            attributes[urlKey] = link.absoluteString
        }
        attributes[.font] = font
        attributes[.foregroundColor] = color
        return attributes
    }

    /// The table cell a run belongs to: its table, its row (nil for the header) and its column.
    private static func tableCell(_ intent: PresentationIntent?) -> (tableIdentity: Int, row: Int?, column: Int, alignments: [NSTextAlignment])? {
        guard let components = intent?.components else {
            return nil
        }
        var column: Int?
        var row: Int?
        var isHeader = false
        var tableIdentity: Int?
        var alignments: [NSTextAlignment] = []
        for component in components {
            switch component.kind {
            case let .tableCell(columnIndex):
                column = columnIndex
            case let .tableRow(rowIndex):
                row = rowIndex
            case .tableHeaderRow:
                isHeader = true
            case let .table(columns):
                tableIdentity = component.identity
                alignments = columns.map { column -> NSTextAlignment in
                    switch column.alignment {
                    case .right:
                        return .right
                    case .center:
                        return .center
                    default:
                        return .left
                    }
                }
            default:
                break
            }
        }
        guard let tableIdentity, let column else {
            return nil
        }
        // Body rows are numbered from 1; the header has its own kind.
        return (tableIdentity, isHeader ? nil : max(0, (row ?? 1) - 1), column, alignments)
    }

    private static func blockQuoteKind(_ intent: PresentationIntent?) -> (kind: TextNodeBlockQuoteData.Kind, identity: Int)? {
        guard let intent else {
            return nil
        }
        for component in intent.components {
            switch component.kind {
            case let .codeBlock(languageHint):
                return (.code(language: languageHint), component.identity)
            case .blockQuote:
                return (.quote, component.identity)
            default:
                continue
            }
        }
        return nil
    }

    private static func isCodeBlock(_ intent: PresentationIntent?) -> Bool {
        return intent?.components.contains(where: { if case .codeBlock = $0.kind { return true } else { return false } }) ?? false
    }

    private static func headerLevel(_ intent: PresentationIntent?) -> Int? {
        for component in intent?.components ?? [] {
            if case let .header(level) = component.kind {
                return level
            }
        }
        return nil
    }

    /// Space between blocks, in ems of the text: a paragraph's is under a blank line (Butterick's 4–10 pt at 17), items of
    /// a list sit closer, and a heading is nearer the text it heads than the text before it.
    enum Spacing {
        static let paragraph: CGFloat = 0.7
        static let listItem: CGFloat = 0.25
        static let aboveHeading: CGFloat = 1.5
        static let belowHeading: CGFloat = 0.45
    }

    /// The line system font text of `size` takes, without line spacing, per point of size.
    private static let lineHeightPerPoint: CGFloat = {
        let font = Font.regular(100.0)
        return (font.ascender - font.descender) / 100.0
    }()

    /// A line break and then a blank line `height` tall as InteractiveTextNode lays it out: its newline's font makes its
    /// height, with the spacing before it.
    static func gap(_ height: CGFloat, style: MarkdownStyle) -> NSAttributedString {
        let size = max(1.0, height / (self.lineHeightPerPoint * (1.0 + style.lineSpacing)))
        let result = NSMutableAttributedString(string: "\n", font: Font.regular(style.fontSize), textColor: style.textColor)
        result.append(NSAttributedString(string: "\n", font: Font.regular(size), textColor: style.textColor))
        return result
    }

    /// Between two blocks of one text: lines of one code block follow each other; list items are a little apart,
    /// paragraphs more, and a heading is closer to what follows it than to what came before.
    private static func separator(between previous: PresentationIntent?, and next: PresentationIntent?, style: MarkdownStyle) -> NSAttributedString {
        if isCodeBlock(previous) && isCodeBlock(next), blockQuoteKind(previous)?.identity == blockQuoteKind(next)?.identity {
            return NSAttributedString(string: "\n", font: Font.regular(style.fontSize), textColor: style.textColor)
        }
        let previousList = previous?.components.contains(where: { if case .listItem = $0.kind { return true } else { return false } }) ?? false
        let nextList = next?.components.contains(where: { if case .listItem = $0.kind { return true } else { return false } }) ?? false
        let ems: CGFloat
        if headerLevel(next) != nil {
            ems = Spacing.aboveHeading
        } else if headerLevel(previous) != nil {
            ems = Spacing.belowHeading
        } else if previousList && nextList {
            ems = Spacing.listItem
        } else {
            ems = Spacing.paragraph
        }
        return self.gap(style.fontSize * ems, style: style)
    }

    /// The space between two blocks laid out apart (a table, a code block that scrolls, the next chunk of a long
    /// answer), as within a text.
    static func spacing(between previous: MarkdownBlock, and next: MarkdownBlock, fontSize: CGFloat) -> CGFloat {
        if case let .text(string) = next, string.length > 0, string.attribute(headingKey, at: 0, effectiveRange: nil) != nil {
            return round(fontSize * Spacing.aboveHeading)
        }
        if case let .text(string) = previous, string.length > 0, string.attribute(headingKey, at: string.length - 1, effectiveRange: nil) != nil {
            return round(fontSize * Spacing.belowHeading)
        }
        return round(fontSize * Spacing.paragraph)
    }

    private static func isThematicBreak(_ intent: PresentationIntent?) -> Bool {
        return intent?.components.contains(where: { if case .thematicBreak = $0.kind { return true } else { return false } }) ?? false
    }

    /// `---`: a hairline the width of the column, as an attachment on a line of its own, in the text's color dimmed.
    private static func rule(style: MarkdownStyle) -> NSAttributedString {
        let width = max(1.0, floor(style.maxWidth > 0.0 ? style.maxWidth - 2.0 : 200.0))
        let thickness = UIScreenPixel
        let image = generateImage(CGSize(width: width, height: 1.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0.0, y: (size.height - thickness) / 2.0, width: size.width, height: thickness))
        })
        guard let image else {
            return NSAttributedString()
        }
        final class Metrics {
            let width: CGFloat
            let half: CGFloat
            init(width: CGFloat, half: CGFloat) {
                self.width = width
                self.half = half
            }
        }
        // A line as tall as the text, the rule across its middle.
        let metrics = Metrics(width: width, half: style.fontSize * 0.5)
        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { pointer in
            Unmanaged<Metrics>.fromOpaque(pointer).release()
        }, getAscent: { pointer in
            return Unmanaged<Metrics>.fromOpaque(pointer).takeUnretainedValue().half
        }, getDescent: { pointer in
            return Unmanaged<Metrics>.fromOpaque(pointer).takeUnretainedValue().half
        }, getWidth: { pointer in
            return Unmanaged<Metrics>.fromOpaque(pointer).takeUnretainedValue().width
        })
        guard let delegate = CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(metrics).toOpaque()) else {
            return NSAttributedString()
        }
        return NSAttributedString(string: "\u{FFFC}", attributes: [
            .font: Font.regular(style.fontSize),
            .foregroundColor: style.textColor.withMultipliedAlpha(0.22),
            .attachment: image,
            NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate,
            self.originalKey: "---",
        ])
    }

    /// Each ordered list's widest marker ("10. "), by the list's identity: its markers end where its text begins.
    private static func listMarkerWidths(_ parsed: AttributedString, fonts: Fonts) -> [Int: CGFloat] {
        var widths: [Int: CGFloat] = [:]
        for run in parsed.runs {
            guard let components = run.presentationIntent?.components else {
                continue
            }
            var ordinal: Int?
            for component in components {
                if case let .listItem(value) = component.kind, ordinal == nil {
                    ordinal = value
                } else if case .orderedList = component.kind, let value = ordinal {
                    widths[component.identity] = max(widths[component.identity] ?? 0.0, self.width("\(value). ", font: fonts.regular))
                    break
                } else if case .unorderedList = component.kind {
                    break
                }
            }
        }
        return widths
    }

    private static func width(_ string: String, font: UIFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Bullets by depth, as HTML's and Notion's lists: a disc, a circle, a square.
    private static let bullets = ["•", "◦", "▪\u{FE0E}"]

    /// A list item paragraph's marker (nil for a later paragraph of the item, which hangs without one) and its indent:
    /// the marker ends where the item's text begins, and a nested list begins where its parent's text does.
    private static func listItem(_ intent: PresentationIntent?, markers: [Int: CGFloat], fonts: Fonts) -> (identity: Int, marker: String?, first: CGFloat, rest: CGFloat)? {
        guard let components = intent?.components else {
            return nil
        }
        // Innermost first: each list with the item of it this text is in.
        var levels: [(list: Int, ordered: Bool, ordinal: Int, item: Int)] = []
        var item: (ordinal: Int, identity: Int)?
        for component in components {
            switch component.kind {
            case let .listItem(value):
                item = (value, component.identity)
            case .orderedList, .unorderedList:
                if let current = item {
                    let ordered: Bool
                    if case .orderedList = component.kind {
                        ordered = true
                    } else {
                        ordered = false
                    }
                    levels.append((component.identity, ordered, current.ordinal, current.identity))
                    item = nil
                }
            default:
                break
            }
        }
        guard let innermost = levels.first else {
            return nil
        }
        let bulletArea = self.width("• ", font: fonts.regular)
        func area(_ level: (list: Int, ordered: Bool, ordinal: Int, item: Int), depth: Int) -> CGFloat {
            if level.ordered {
                return markers[level.list] ?? self.width("\(level.ordinal). ", font: fonts.regular)
            }
            let bullet = self.bullets[min(depth, self.bullets.count - 1)] + " "
            return max(bulletArea, self.width(bullet, font: fonts.regular))
        }
        let depth = levels.count - 1
        var base: CGFloat = 0.0
        for (index, level) in levels.dropFirst().reversed().enumerated() {
            base += area(level, depth: index)
        }
        let marker = innermost.ordered ? "\(innermost.ordinal). " : self.bullets[min(depth, self.bullets.count - 1)] + " "
        let markerArea = area(innermost, depth: depth)
        let markerWidth = self.width(marker, font: fonts.regular)
        return (innermost.item, marker, base + max(0.0, markerArea - markerWidth), base + markerArea)
    }

    /// `font` with figures of one width (OpenType `tnum`), for table columns.
    private static func tabularFigures(_ font: UIFont) -> UIFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]],
        ])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    // MARK: Typesetting

    /// What typesetting does to a text outside its code and formulas: curly quotes for straight ones, a centered ellipsis
    /// in Chinese, and, unless `orphans` is false, no paragraph ending on a lone Han character. Each replaced
    /// character keeps what it was under `originalKey`, which copying gives back.
    static func typeset(_ string: NSMutableAttributedString, style: MarkdownStyle, orphans: Bool = true) {
        let text = string.string as NSString
        let length = text.length
        guard length > 0 else {
            return
        }
        var isCode = [Bool](repeating: false, count: length)
        string.enumerateAttributes(in: NSRange(location: 0, length: length), options: []) { attributes, range, _ in
            let code: Bool
            if attributes[inlineCodeKey] != nil || attributes[MathText.latexKey] != nil || attributes[.attachment] != nil {
                code = true
            } else if let quote = attributes[blockQuoteKey] as? TextNodeBlockQuoteData, case .code = quote.kind {
                code = true
            } else {
                code = false
            }
            if code {
                for index in range.location ..< range.location + range.length {
                    isCode[index] = true
                }
            }
        }
        func character(_ index: Int) -> unichar? {
            return index >= 0 && index < length && !isCode[index] ? text.character(at: index) : nil
        }
        var replacements: [(index: Int, with: String, original: String)] = []
        var kerns: [Int] = []
        // Quotes: by what is on either side, and where that cannot tell (between two Han characters), alternately.
        var doubleOpen = false
        var singleOpen = false
        var index = 0
        while index < length {
            guard !isCode[index] else {
                index += 1
                continue
            }
            let c = text.character(at: index)
            if c == 0x22 || c == 0x27 {
                let previous = character(index - 1)
                let next = character(index + 1)
                let before = Context(previous)
                let after = Context(next)
                var replacement: String?
                if c == 0x22 {
                    if before == .digit && !doubleOpen {
                        // 30": inches.
                    } else if before.opens && !after.closes {
                        replacement = "“"
                    } else if !before.opens && after.closes {
                        replacement = "”"
                    } else {
                        replacement = doubleOpen ? "”" : "“"
                    }
                    if let replacement {
                        doubleOpen = replacement == "“"
                    }
                } else {
                    if before == .digit && (after == .digit || after.closes) && !singleOpen {
                        // 5'10": feet.
                    } else if before.isWord && after.isWord {
                        // it's, don't
                        replacement = "’"
                    } else if before.opens && after == .digit {
                        // '90s
                        replacement = "’"
                    } else if before.opens && !after.closes {
                        replacement = "‘"
                        singleOpen = true
                    } else if !before.opens {
                        // A closing quote, or the possessive of a plural (the users').
                        replacement = "’"
                        singleOpen = false
                    }
                }
                if let replacement {
                    replacements.append((index, replacement, String(utf16CodeUnits: [c], count: 1)))
                }
            } else if c == 0x2026, character(index + 1) == 0x2026 {
                // GB/T 15834: Chinese's ellipsis is six dots across two characters, centered, and PingFang's sits on the
                // baseline. The midline ellipsis is centered; Core Text spaces it from Han as Western (1/8 em), which
                // a negative kern on either side takes back.
                var end = index
                while end < length, character(end) == 0x2026 {
                    replacements.append((end, "⋯", "…"))
                    end += 1
                }
                if let previous = character(index - 1), isHan(previous) {
                    kerns.append(index - 1)
                }
                if let next = character(end), isHan(next) {
                    kerns.append(end - 1)
                }
                index = end
                continue
            }
            index += 1
        }
        for replacement in replacements {
            let range = NSRange(location: replacement.index, length: 1)
            let attributes = string.attributes(at: replacement.index, effectiveRange: nil)
            var updated = attributes
            updated[originalKey] = replacement.original
            string.replaceCharacters(in: range, with: NSAttributedString(string: replacement.with, attributes: updated))
        }
        for kern in kerns {
            let size = (string.attribute(.font, at: kern, effectiveRange: nil) as? UIFont)?.pointSize ?? style.fontSize
            string.addAttribute(.kern, value: -size / 8.0, range: NSRange(location: kern, length: 1))
        }
        if orphans {
            var start = 0
            for index in 0 ... length {
                if index == length || isCode[index] {
                    if index > start {
                        string.addAttribute(avoidsOrphansKey, value: true, range: NSRange(location: start, length: index - start))
                    }
                    start = index + 1
                }
            }
        }
    }

    private static func isHan(_ c: unichar) -> Bool {
        return (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0xF900 && c <= 0xFAFF)
    }

    /// What is beside a quote: the start or end of the text, a space, a letter or digit, or punctuation that opens or
    /// closes.
    private enum Context: Equatable {
        case edge
        case space
        case digit
        case letter
        case opening
        case closing
        case other

        init(_ c: unichar?) {
            guard let c else {
                self = .edge
                return
            }
            if let scalar = Unicode.Scalar(c) {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    self = .space
                } else if CharacterSet.decimalDigits.contains(scalar) {
                    self = .digit
                } else if "([{“‘—–-/<（「『《【〈".unicodeScalars.contains(scalar) {
                    self = .opening
                } else if ".,;:!?)]}…”’>，。、：；！？）」』》】〉".unicodeScalars.contains(scalar) {
                    self = .closing
                } else if CharacterSet.letters.contains(scalar) {
                    self = .letter
                } else {
                    self = .other
                }
            } else {
                // Half of a surrogate pair: an emoji or a rare character, taken as a letter.
                self = .letter
            }
        }

        /// What an opening quote follows.
        var opens: Bool {
            return self == .edge || self == .space || self == .opening
        }

        /// What a closing quote precedes.
        var closes: Bool {
            return self == .edge || self == .space || self == .closing
        }

        var isWord: Bool {
            return self == .letter || self == .digit
        }
    }

    /// What copying a selection of the text gives: formulas as their LaTeX, typeset characters as written, kept
    /// indentation as plain spaces.
    static func copiedText(_ string: NSAttributedString) -> String {
        let plain = NSMutableString(string: string.string)
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length), options: [.reverse]) { attributes, range, _ in
            if let latex = attributes[MathText.latexKey] as? String {
                plain.replaceCharacters(in: range, with: "$\(latex)$")
            } else if let original = attributes[originalKey] as? String {
                // Each character was one; equal neighbours make one range.
                plain.replaceCharacters(in: range, with: String(repeating: original, count: range.length))
            }
        }
        return (plain as String).replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
