import UIKit
import Display

/// Styles for one surface: a bubble, or the assistant's bubble-less text on the wallpaper.
struct MarkdownStyle {
    var fontSize: CGFloat
    var textColor: UIColor
    var linkColor: UIColor
    var accentColor: UIColor
}

/// Markdown to the attributed strings Telegram's InteractiveTextNode renders: fenced code and block quotes become
/// `Attribute__Blockquote` ranges carrying `TextNodeBlockQuoteData`, as Telegram's `pre` and `blockquote` entities do
/// (TextFormat/Sources/StringWithAppliedEntities.swift). Parsing is Foundation's CommonMark parser, which tolerates the
/// unclosed constructs of a half-streamed answer.
enum MarkdownText {
    static let blockQuoteKey = NSAttributedString.Key("Attribute__Blockquote")
    static let urlKey = NSAttributedString.Key("Attribute__Url")

    static func render(_ text: String, style: MarkdownStyle) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, font: Font.regular(style.fontSize), textColor: style.textColor)
        }

        let result = NSMutableAttributedString()
        let regular = Font.regular(style.fontSize)
        let bold = Font.semibold(style.fontSize)
        let italic = Font.italic(style.fontSize)
        let boldItalic = Font.semiboldItalic(style.fontSize)
        let monospace = Font.monospace(style.fontSize)

        var previousBlock: PresentationIntent?
        var blockStart = 0
        var currentBlockQuote: (kind: TextNodeBlockQuoteData.Kind, start: Int, identity: Int)?

        func closeBlockQuote() {
            guard let quote = currentBlockQuote else {
                return
            }
            currentBlockQuote = nil
            // A block must not end with a newline, or the renderer draws an empty line inside it.
            var end = result.length
            while end > quote.start, (result.string as NSString).character(at: end - 1) == 0x0a {
                end -= 1
            }
            guard end > quote.start else {
                return
            }
            let data = TextNodeBlockQuoteData(
                kind: quote.kind,
                title: nil,
                color: style.accentColor,
                secondaryColor: nil,
                tertiaryColor: nil,
                backgroundColor: style.accentColor.withMultipliedAlpha(0.1),
                isCollapsible: false
            )
            result.addAttribute(blockQuoteKey, value: data, range: NSRange(location: quote.start, length: end - quote.start))
        }

        for run in parsed.runs {
            let intent = run.presentationIntent
            if intent != previousBlock {
                let blockQuote = blockQuoteKind(intent)
                if let current = currentBlockQuote, blockQuote?.identity != current.identity {
                    closeBlockQuote()
                }
                if result.length > 0 {
                    let separator = separatorBetween(previousBlock, intent)
                    result.append(NSAttributedString(string: separator, font: regular, textColor: style.textColor))
                }
                if let blockQuote, currentBlockQuote == nil {
                    currentBlockQuote = (blockQuote.kind, result.length, blockQuote.identity)
                }
                blockStart = result.length
                result.append(NSAttributedString(string: listPrefix(intent), font: regular, textColor: style.textColor))
                previousBlock = intent
            }

            var runText = String(parsed[run.range].characters)
            var font = regular
            var color = style.textColor
            var attributes: [NSAttributedString.Key: Any] = [:]

            if isCodeBlock(intent) {
                font = monospace
                if runText.hasSuffix("\n") {
                    runText.removeLast()
                }
            } else if let level = headerLevel(intent) {
                font = Font.semibold(style.fontSize + max(0.0, 4.0 - CGFloat(level)))
            } else if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    font = monospace
                } else if inline.contains(.stronglyEmphasized) && inline.contains(.emphasized) {
                    font = boldItalic
                } else if inline.contains(.stronglyEmphasized) {
                    font = bold
                } else if inline.contains(.emphasized) {
                    font = italic
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
            result.append(NSAttributedString(string: runText, attributes: attributes))
        }
        _ = blockStart
        closeBlockQuote()
        return result
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
