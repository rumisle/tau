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

    /// Light text: a dark theme.
    var isDark: Bool {
        var white: CGFloat = 0.0
        self.textColor.getWhite(&white, alpha: nil)
        return white > 0.5
    }
}

/// A rendered table: header cells, then body rows, each cell already styled.
struct MarkdownTable {
    var header: [NSAttributedString]
    var rows: [[NSAttributedString]]

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

    var characterCount: Int {
        switch self {
        case let .text(string):
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

    /// The whole message as one attributed string, tables included as plain rows.
    static func render(_ text: String, style: MarkdownStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in self.blocks(text, style: style) {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n", font: Font.regular(style.fontSize), textColor: style.textColor))
            }
            switch block {
            case let .text(string):
                result.append(string)
            case let .table(table):
                for (index, row) in ([table.header] + table.rows).enumerated() {
                    if index > 0 {
                        result.append(NSAttributedString(string: "\n"))
                    }
                    let line = NSMutableAttributedString()
                    for (cellIndex, cell) in row.enumerated() {
                        if cellIndex > 0 {
                            line.append(NSAttributedString(string: " · ", font: Font.regular(style.fontSize), textColor: style.textColor))
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

    static func blocks(_ text: String, style: MarkdownStyle) -> [MarkdownBlock] {
        let key = "\(style.fontSize)|\(style.textColor.argb)|\(style.linkColor.argb)|\(style.accentColor.argb)|\(style.maxWidth)|\(style.math)|\(text)"
        self.cacheLock.lock()
        if let cached = self.cache[key] {
            self.cacheLock.unlock()
            return cached
        }
        self.cacheLock.unlock()
        let result = self.parseBlocks(text, style: style)
        self.cacheLock.lock()
        self.cache[key] = result
        self.cacheOrder.append(key)
        if self.cacheOrder.count > 400 {
            self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
        }
        self.cacheLock.unlock()
        return result
    }

    private static func parseBlocks(_ rawText: String, style: MarkdownStyle) -> [MarkdownBlock] {
        let (text, formulas) = style.math ? MathText.extract(rawText) : (rawText, [])
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [.text(NSAttributedString(string: text, font: Font.regular(style.fontSize), textColor: style.textColor))]
        }
        let fonts = Fonts(size: style.fontSize)

        var blocks: [MarkdownBlock] = []
        var current = NSMutableAttributedString()
        var table: (identity: Int, header: [NSMutableAttributedString], rows: [[NSMutableAttributedString]])?
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
                if let language, !language.isEmpty {
                    title = NSAttributedString(string: language.capitalized, font: fonts.bold.withSize(round(fonts.bold.pointSize * 0.8235294117647058)), textColor: style.accentColor)
                }
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
                keepIndentation(current, range: range)
            }
        }

        func flushText() {
            closeBlockQuote()
            if current.length > 0 {
                blocks.append(.text(current))
            }
            current = NSMutableAttributedString()
        }

        func flushTable() {
            guard let value = table else {
                return
            }
            table = nil
            blocks.append(.table(MarkdownTable(header: value.header, rows: value.rows)))
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
                    table = (cell.tableIdentity, [], [])
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
                let blockQuote = blockQuoteKind(intent)
                if let quote = currentBlockQuote, blockQuote?.identity != quote.identity {
                    closeBlockQuote()
                }
                if current.length > 0 {
                    current.append(NSAttributedString(string: separatorBetween(previousBlock, intent), font: fonts.regular, textColor: style.textColor))
                }
                if let blockQuote, currentBlockQuote == nil {
                    currentBlockQuote = (blockQuote.kind, current.length, blockQuote.identity)
                }
                current.append(NSAttributedString(string: listPrefix(intent), font: fonts.regular, textColor: style.textColor))
                previousBlock = intent
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

    /// InteractiveTextNode drops the spaces a line starts with, which in code is indentation. No-break spaces in their
    /// place keep it; spaces inside a line stay, so long lines still wrap between words.
    private static func keepIndentation(_ string: NSMutableAttributedString, range: NSRange) {
        let text = string.string as NSString
        var atLineStart = true
        for index in range.location ..< range.location + range.length {
            let character = text.character(at: index)
            if character == 0x0a {
                atLineStart = true
            } else if atLineStart && character == 0x20 {
                string.replaceCharacters(in: NSRange(location: index, length: 1), with: "\u{00A0}")
            } else {
                atLineStart = false
            }
        }
    }

    private struct Fonts {
        let regular: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
        let monospace: UIFont

        init(size: CGFloat) {
            self.regular = Font.regular(size)
            self.bold = Font.semibold(size)
            self.italic = Font.italic(size)
            self.boldItalic = Font.semiboldItalic(size)
            self.monospace = Font.monospace(size)
        }
    }

    private static func inlineAttributes(run: AttributedString.Runs.Run, intent: PresentationIntent?, style: MarkdownStyle, fonts: Fonts) -> [NSAttributedString.Key: Any] {
        var font = fonts.regular
        var color = style.textColor
        var attributes: [NSAttributedString.Key: Any] = [:]
        if isCodeBlock(intent) {
            font = fonts.monospace
        } else if let level = headerLevel(intent) {
            font = Font.semibold(style.fontSize + max(0.0, 4.0 - CGFloat(level)))
        } else if let inline = run.inlinePresentationIntent {
            if inline.contains(.code) {
                font = fonts.monospace
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
    private static func tableCell(_ intent: PresentationIntent?) -> (tableIdentity: Int, row: Int?, column: Int)? {
        guard let components = intent?.components else {
            return nil
        }
        var column: Int?
        var row: Int?
        var isHeader = false
        var tableIdentity: Int?
        for component in components {
            switch component.kind {
            case let .tableCell(columnIndex):
                column = columnIndex
            case let .tableRow(rowIndex):
                row = rowIndex
            case .tableHeaderRow:
                isHeader = true
            case .table:
                tableIdentity = component.identity
            default:
                break
            }
        }
        guard let tableIdentity, let column else {
            return nil
        }
        // Body rows are numbered from 1; the header has its own kind.
        return (tableIdentity, isHeader ? nil : max(0, (row ?? 1) - 1), column)
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

    /// "• " or "3. " for the first run of a list item.
    private static func listPrefix(_ intent: PresentationIntent?) -> String {
        guard let components = intent?.components else {
            return ""
        }
        var ordinal: Int?
        var ordered = false
        var depth = 0
        for component in components {
            switch component.kind {
            case let .listItem(value):
                if ordinal == nil {
                    ordinal = value
                }
            case .orderedList:
                if depth == 0 {
                    ordered = true
                }
                depth += 1
            case .unorderedList:
                depth += 1
            default:
                break
            }
        }
        guard let ordinal else {
            return ""
        }
        let indent = String(repeating: "    ", count: max(0, depth - 1))
        return indent + (ordered ? "\(ordinal). " : "• ")
    }

    /// Paragraph-level blocks are separated by a blank line, items of one list by a single newline.
    private static func separatorBetween(_ previous: PresentationIntent?, _ next: PresentationIntent?) -> String {
        let previousList = previous?.components.contains(where: { if case .listItem = $0.kind { return true } else { return false } }) ?? false
        let nextList = next?.components.contains(where: { if case .listItem = $0.kind { return true } else { return false } }) ?? false
        if previousList && nextList {
            return "\n"
        }
        if isCodeBlock(previous) && isCodeBlock(next), blockQuoteKind(previous)?.identity == blockQuoteKind(next)?.identity {
            return "\n"
        }
        return "\n\n"
    }
}
