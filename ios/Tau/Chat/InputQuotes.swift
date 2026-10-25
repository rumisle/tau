import UIKit
import Display
import AppBundle
import MessageInlineBlockBackgroundView

/// A quote in the field: every character of it carries the same one.
final class InputQuoteMark: NSObject {
    /// Lines of their own, or a few words in a line.
    let isBlock: Bool

    init(isBlock: Bool) {
        self.isBlock = isBlock
    }
}

/// Quotes in the composer (docs/quotes.md), as Telegram's input field shows a quote (ChatInputTextView): a block is
/// Telegram's quote, its bar and its mark in the corner, set in from the field's edges with 8 pt above and below; a few
/// words are on a tint, as in a message. The field's text has none of `<tau:quote>`: its quotes are marked characters,
/// which `text(of:)` writes out and `attributed(_:)` reads back.
///
/// - A quote goes in where the cursor is: on a line of its own, or in a line when a line's words are quoted in its
///   middle; the cursor after it, for the reply.
/// - Backspace right after a few quoted words, or at the start of the line after a block, takes the quote whole.
/// - Typing inside a quote edits it; Return at a block's end leaves it.
final class InputQuotes {
    static let key = NSAttributedString.Key("tau.inputQuote")
    /// The text's inset in a block from its bar, and from the field's end for its mark, as Telegram's (9 + 7 + 18).
    private static let blockIndent: CGFloat = 10.0
    private static let blockTrailing: CGFloat = 24.0
    private static let blockSpacing: CGFloat = 8.0

    private weak var textView: UITextView?
    var font: UIFont
    var textColor: UIColor
    var accentColor: UIColor {
        didSet {
            if !self.accentColor.isEqual(oldValue) {
                self.updateDecorations()
            }
        }
    }
    private var blockViews: [ObjectIdentifier: InputQuoteBlockView] = [:]
    private var inlineViews: [ObjectIdentifier: [UIView]] = [:]

    init(textView: UITextView, font: UIFont, textColor: UIColor, accentColor: UIColor) {
        self.textView = textView
        self.font = font
        self.textColor = textColor
        self.accentColor = accentColor
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        return [.font: self.font, .foregroundColor: self.textColor, .paragraphStyle: NSParagraphStyle.default]
    }

    private func attributes(_ mark: InputQuoteMark?) -> [NSAttributedString.Key: Any] {
        var attributes = self.baseAttributes
        if let mark {
            attributes[InputQuotes.key] = mark
            if mark.isBlock {
                attributes[.paragraphStyle] = InputQuotes.blockStyle(first: true, last: true)
            }
        }
        return attributes
    }

    private static func blockStyle(first: Bool, last: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = self.blockIndent
        style.headIndent = self.blockIndent
        style.tailIndent = -self.blockTrailing
        style.paragraphSpacingBefore = first ? self.blockSpacing : 0.0
        style.paragraphSpacing = last ? self.blockSpacing : 0.0
        return style
    }

    // MARK: - Text

    /// The field's text for a message's: its quotes marked.
    func attributed(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in TauQuote.parse(text) {
            switch piece {
            case let .text(value):
                result.append(NSAttributedString(string: value, attributes: self.baseAttributes))
            case let .block(value):
                result.append(NSAttributedString(string: value, attributes: self.attributes(InputQuoteMark(isBlock: true))))
            case let .inline(value):
                result.append(NSAttributedString(string: value, attributes: self.attributes(InputQuoteMark(isBlock: false))))
            }
        }
        InputQuotes.restyle(result)
        return result
    }

    /// The message the field's text makes, its quotes in tags.
    static func text(of storage: NSAttributedString) -> String {
        guard storage.length > 0 else {
            return ""
        }
        var pieces: [TauQuote.Piece] = []
        func appendText(_ value: String) {
            if case let .text(previous)? = pieces.last {
                pieces[pieces.count - 1] = .text(previous + value)
            } else if !value.isEmpty {
                pieces.append(.text(value))
            }
        }
        let string = storage.string as NSString
        storage.enumerateAttribute(self.key, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            let part = string.substring(with: range)
            guard let mark = value as? InputQuoteMark else {
                appendText(part)
                return
            }
            // A break typed at a block's end is the text's, after it.
            var content = part
            var trailing = ""
            while content.hasSuffix("\n") {
                content.removeLast()
                trailing += "\n"
            }
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendText(part)
                return
            }
            pieces.append(mark.isBlock ? .block(content) : .inline(content))
            appendText(trailing)
        }
        return TauQuote.serialize(pieces)
    }

    /// Each paragraph's style: a block's with its spacing at its ends, the default elsewhere.
    static func restyle(_ storage: NSMutableAttributedString) {
        let string = storage.string as NSString
        var paragraphs: [(NSRange, InputQuoteMark?)] = []
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var mark: InputQuoteMark?
            storage.enumerateAttribute(self.key, in: paragraph, options: []) { value, range, stop in
                if let value = value as? InputQuoteMark, value.isBlock, string.substring(with: range).contains(where: { $0 != "\n" }) {
                    mark = value
                    stop.pointee = true
                }
            }
            paragraphs.append((paragraph, mark))
            location = paragraph.upperBound
        }
        storage.beginEditing()
        for (index, (range, mark)) in paragraphs.enumerated() {
            let style: NSParagraphStyle
            if let mark {
                let first = index == 0 || paragraphs[index - 1].1 !== mark
                let last = index == paragraphs.count - 1 || paragraphs[index + 1].1 !== mark
                style = self.blockStyle(first: first, last: last)
            } else {
                style = NSParagraphStyle.default
            }
            if (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) != style {
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        storage.endEditing()
    }

    private func quote(at index: Int) -> (InputQuoteMark, NSRange)? {
        guard let storage = self.textView?.textStorage, index >= 0, index < storage.length else {
            return nil
        }
        var range = NSRange()
        guard let mark = storage.attribute(InputQuotes.key, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? InputQuoteMark else {
            return nil
        }
        return (mark, range)
    }

    // MARK: - Editing

    /// Puts `quote` in where the cursor is, the cursor after it.
    func insert(_ quote: String) {
        guard let textView = self.textView else {
            return
        }
        let content = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return
        }
        let storage = textView.textStorage
        let string = storage.string as NSString
        var location = textView.isFirstResponder ? textView.selectedRange.upperBound : string.length
        location = min(location, string.length)
        // Not into another quote: after it.
        if location > 0, location < string.length, let (before, range) = self.quote(at: location - 1), let (after, _) = self.quote(at: location), before === after {
            location = range.upperBound
        }
        let previous: unichar? = location > 0 ? string.character(at: location - 1) : nil
        let next: unichar? = location < string.length ? string.character(at: location) : nil
        let atLineStart = previous == nil || previous == 0x0a
        let insertion = NSMutableAttributedString()
        let caret: Int
        if content.contains("\n") || atLineStart {
            if !atLineStart {
                insertion.append(NSAttributedString(string: "\n", attributes: self.baseAttributes))
            }
            insertion.append(NSAttributedString(string: content, attributes: self.attributes(InputQuoteMark(isBlock: true))))
            insertion.append(NSAttributedString(string: "\n", attributes: self.baseAttributes))
            caret = insertion.length
            if let next, next != 0x0a {
                insertion.append(NSAttributedString(string: "\n", attributes: self.baseAttributes))
            }
        } else {
            if let previous, previous != 0x20 {
                insertion.append(NSAttributedString(string: " ", attributes: self.baseAttributes))
            }
            insertion.append(NSAttributedString(string: content, attributes: self.attributes(InputQuoteMark(isBlock: false))))
            if next != 0x20 {
                insertion.append(NSAttributedString(string: " ", attributes: self.baseAttributes))
            }
            caret = insertion.length + (next == 0x20 ? 1 : 0)
        }
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: insertion)
        InputQuotes.restyle(storage)
        textView.selectedRange = NSRange(location: min(storage.length, location + caret), length: 0)
        textView.typingAttributes = self.typingAttributes(at: textView.selectedRange.location)
    }

    /// What a backspace over `range` takes instead: the whole quote, from just after a few quoted words or the start
    /// of the line after a block.
    func deletion(for range: NSRange, replacement: String) -> NSRange? {
        guard replacement.isEmpty, range.length > 0, let storage = self.textView?.textStorage, range.upperBound <= storage.length else {
            return nil
        }
        let string = storage.string as NSString
        let last = range.upperBound - 1
        if let (mark, quoteRange) = self.quote(at: last), !mark.isBlock, quoteRange.upperBound == range.upperBound, range.location > quoteRange.location {
            return quoteRange
        }
        if range.length == 1, string.character(at: range.location) == 0x0a, self.quote(at: range.location) == nil, let (mark, quoteRange) = self.quote(at: range.location - 1), mark.isBlock {
            return NSRange(location: quoteRange.location, length: range.upperBound - quoteRange.location)
        }
        return nil
    }

    /// What typing at `location` writes: into a block from inside it or the start of its line, into a few words
    /// from between two of them; else the text's own.
    func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        guard let storage = self.textView?.textStorage else {
            return self.baseAttributes
        }
        let string = storage.string as NSString
        if location > 0, let (mark, _) = self.quote(at: location - 1), mark.isBlock, string.character(at: location - 1) != 0x0a {
            var attributes = storage.attributes(at: location - 1, effectiveRange: nil)
            attributes[.font] = self.font
            return attributes
        }
        if location < storage.length, let (mark, _) = self.quote(at: location), mark.isBlock, location == 0 || string.character(at: location - 1) == 0x0a {
            var attributes = storage.attributes(at: location, effectiveRange: nil)
            attributes[.font] = self.font
            return attributes
        }
        if location > 0, location < storage.length, let (before, _) = self.quote(at: location - 1), let (after, _) = self.quote(at: location), before === after, !before.isBlock {
            return self.attributes(before)
        }
        return self.baseAttributes
    }

    // MARK: - Drawing

    /// The quotes' backgrounds behind the text, where the layout put their lines.
    func updateDecorations() {
        guard let textView = self.textView else {
            return
        }
        let storage = textView.textStorage
        var ranges: [ObjectIdentifier: (InputQuoteMark, NSRange)] = [:]
        storage.enumerateAttribute(InputQuotes.key, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let mark = value as? InputQuoteMark else {
                return
            }
            let id = ObjectIdentifier(mark)
            ranges[id] = (mark, ranges[id].map { NSUnionRange($0.1, range) } ?? range)
        }
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        let inset = textView.textContainerInset
        if !ranges.isEmpty {
            layoutManager.ensureLayout(for: container)
        }
        var blocks: [ObjectIdentifier: CGRect] = [:]
        var inlines: [ObjectIdentifier: [CGRect]] = [:]
        for (id, (mark, range)) in ranges {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if mark.isBlock {
                var union: CGRect?
                layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, lineGlyphs, _ in
                    // Lines of the quote's own characters, not its break's empty one.
                    let characters = layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                    guard NSIntersectionRange(characters, range).length > 0 else {
                        return
                    }
                    union = union.map { $0.union(usedRect) } ?? usedRect
                }
                if let union {
                    blocks[id] = CGRect(x: inset.left, y: inset.top + union.minY - 3.0, width: container.size.width, height: union.height + 6.0)
                }
            } else {
                var rects: [CGRect] = []
                layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                    if rect.width > 0.5 {
                        rects.append(rect.offsetBy(dx: inset.left, dy: inset.top).insetBy(dx: -2.0, dy: 0.0))
                    }
                }
                inlines[id] = rects
            }
        }
        for (id, view) in self.blockViews where blocks[id] == nil {
            view.removeFromSuperview()
        }
        self.blockViews = self.blockViews.filter { blocks[$0.key] != nil }
        for (id, frame) in blocks {
            let view: InputQuoteBlockView
            if let current = self.blockViews[id] {
                view = current
            } else {
                view = InputQuoteBlockView()
                view.isUserInteractionEnabled = false
                self.blockViews[id] = view
                textView.insertSubview(view, at: 0)
            }
            view.frame = frame
            view.update(size: frame.size, color: self.accentColor)
        }
        for (id, views) in self.inlineViews where inlines[id] == nil {
            views.forEach { $0.removeFromSuperview() }
        }
        self.inlineViews = self.inlineViews.filter { inlines[$0.key] != nil }
        for (id, rects) in inlines {
            var views = self.inlineViews[id] ?? []
            while views.count > rects.count {
                views.removeLast().removeFromSuperview()
            }
            while views.count < rects.count {
                let view = UIView()
                view.isUserInteractionEnabled = false
                view.layer.cornerRadius = 4.0
                textView.insertSubview(view, at: 0)
                views.append(view)
            }
            for (view, rect) in zip(views, rects) {
                view.frame = rect
                view.backgroundColor = self.accentColor.withMultipliedAlpha(0.16)
            }
            self.inlineViews[id] = views
        }
    }
}

/// Telegram's quote behind a block in the field (ChatInputTextNode's QuoteBackgroundView): its bar and tint, and the
/// quote mark in its corner.
private final class InputQuoteBlockView: UIView {
    private let backgroundView = MessageInlineBlockBackgroundView()
    private let iconView = UIImageView(image: UIImage(bundleImageName: "Chat/Message/ReplyQuoteIcon")?.precomposed().withRenderingMode(.alwaysTemplate))

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.backgroundView)
        self.addSubview(self.iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(size: CGSize, color: UIColor) {
        self.backgroundView.frame = CGRect(origin: CGPoint(), size: size)
        self.backgroundView.update(size: size, isTransparent: false, primaryColor: color, secondaryColor: nil, thirdColor: nil, backgroundColor: nil, pattern: nil, animation: .None)
        self.iconView.tintColor = color
        if let image = self.iconView.image {
            self.iconView.frame = CGRect(origin: CGPoint(x: size.width - 4.0 - image.size.width, y: 4.0), size: image.size)
        }
    }
}
