import UIKit
import AsyncDisplayKit
import Display
import InteractiveTextComponent

/// A message's text as one for Telegram's TextSelectionNode, which selects in a single text node: the message's text
/// nodes (a long answer is laid out in chunks, and code that scrolls in its own) and its tables, in order, so a
/// selection runs across them all. Characters are numbered through the parts, `separator` between two; a table counts
/// as its cells' text and is taken in whole or not at all.
final class MessageTextSurface: ASDisplayNode, TextNodeProtocol {
    enum Part {
        case text(InteractiveTextNode)
        case table(ChatTableNode, String)

        var node: ASDisplayNode {
            switch self {
            case let .text(node):
                return node
            case let .table(node, _):
                return node
            }
        }

        var text: NSAttributedString {
            switch self {
            case let .text(node):
                return node.cachedLayout?.attributedString ?? NSAttributedString()
            case let .table(_, text):
                return NSAttributedString(string: text)
            }
        }
    }

    /// Between two parts: a paragraph's break, as copying the message would have it.
    static let separator = "\n\n"

    private(set) var parts: [Part] = []
    private var offsets: [Int] = []
    private(set) var text = NSAttributedString()

    override init() {
        super.init()
        self.isUserInteractionEnabled = false
        self.isLayerBacked = false
    }

    /// The parts the selection runs through now; the text they make, which a selection made over other parts does
    /// not hold for.
    func update(parts: [Part]) {
        self.parts = parts
        (self.text, self.offsets) = MessageTextSurface.text(of: parts)
    }

    /// The text parts make, and where each begins in it.
    static func text(of parts: [Part]) -> (NSAttributedString, [Int]) {
        let text = NSMutableAttributedString()
        var offsets: [Int] = []
        for (index, part) in parts.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: MessageTextSurface.separator))
            }
            offsets.append(text.length)
            text.append(part.text)
        }
        return (text, offsets)
    }

    /// The part and the surface's index a character of a text node has.
    func index(of textNode: InteractiveTextNode, _ index: Int) -> Int? {
        for (partIndex, part) in self.parts.enumerated() {
            if case let .text(node) = part, node === textNode {
                return self.offsets[partIndex] + index
            }
        }
        return nil
    }

    var currentText: NSAttributedString? {
        return self.text
    }

    private func frame(of part: Part) -> CGRect {
        let node = part.node
        return node.view.convert(node.bounds, to: self.view)
    }

    private func length(_ partIndex: Int) -> Int {
        return self.parts[partIndex].text.length
    }

    func attributesAtPoint(_ point: CGPoint, orNearest: Bool) -> (Int, [NSAttributedString.Key: Any])? {
        guard !self.parts.isEmpty else {
            return nil
        }
        if !orNearest {
            // What a press begins on: a text's character; a table's cells select from a knob.
            for (partIndex, part) in self.parts.enumerated() {
                guard case let .text(node) = part else {
                    continue
                }
                let local = self.view.convert(point, to: node.view)
                if node.bounds.contains(local), let (index, attributes) = node.attributesAtPoint(local, orNearest: false) {
                    return (self.offsets[partIndex] + index, attributes)
                }
            }
            return nil
        }
        // A knob: the part the point is level with, else the nearest one above or below; there, the nearest boundary
        // between characters.
        var best: (index: Int, distance: CGFloat)?
        for (partIndex, part) in self.parts.enumerated() where self.length(partIndex) > 0 {
            let frame = self.frame(of: part)
            let distance = max(0.0, frame.minY - point.y, point.y - frame.maxY)
            if let best, best.distance <= distance {
                continue
            }
            best = (partIndex, distance)
        }
        guard let partIndex = best?.index else {
            return nil
        }
        let part = self.parts[partIndex]
        let offset = self.offsets[partIndex]
        switch part {
        case let .text(node):
            let local = self.view.convert(point, to: node.view)
            guard let index = node.caretIndex(at: local) else {
                return nil
            }
            return (offset + index, [:])
        case .table:
            let frame = self.frame(of: part)
            return (point.y < frame.midY ? offset : offset + self.length(partIndex), [:])
        }
    }

    func textRangeRects(in range: NSRange) -> (rects: [CGRect], start: TextRangeRectEdge, end: TextRangeRectEdge)? {
        guard range.length > 0 else {
            return nil
        }
        // What shows of it: from its first character that shows to its last, not a line break (a paragraph's gap is
        // made of them) nor what is between two parts; the knobs go there.
        let string = self.text.string as NSString
        func isBreak(_ index: Int) -> Bool {
            guard index >= 0, index < string.length else {
                return true
            }
            let character = string.character(at: index)
            return character == 0x0a || character == 0x2028 || self.partIndex(of: index) == nil
        }
        var start = range.location
        while start < range.upperBound - 1, isBreak(start) {
            start += 1
        }
        var end = range.upperBound
        while end > start + 1, isBreak(end - 1) {
            end -= 1
        }
        let shown = NSRange(location: start, length: end - start)
        var rects: [CGRect] = []
        for (partIndex, part) in self.parts.enumerated() {
            let partRange = NSRange(location: self.offsets[partIndex], length: self.length(partIndex))
            let shared = NSIntersectionRange(shown, partRange)
            guard shared.length > 0 else {
                continue
            }
            switch part {
            case let .text(node):
                let local = NSRange(location: shared.location - partRange.location, length: shared.length)
                if let result = node.textRangeRects(in: local) {
                    rects.append(contentsOf: result.rects.map { node.view.convert($0, to: self.view) })
                }
            case .table:
                rects.append(self.frame(of: part))
            }
        }
        guard !rects.isEmpty, let startEdge = self.edge(at: start, isEnd: false), let endEdge = self.edge(at: end - 1, isEnd: true) else {
            return nil
        }
        return (rects, startEdge, endEdge)
    }

    private func partIndex(of index: Int) -> Int? {
        for partIndex in self.parts.indices {
            let offset = self.offsets[partIndex]
            if index >= offset, index < offset + self.length(partIndex) {
                return partIndex
            }
        }
        return nil
    }

    /// The edge before the character at `index`, or after it for the end.
    private func edge(at index: Int, isEnd: Bool) -> TextRangeRectEdge? {
        guard let partIndex = self.partIndex(of: index) else {
            return nil
        }
        let part = self.parts[partIndex]
        switch part {
        case let .text(node):
            guard let result = node.textRangeRects(in: NSRange(location: index - self.offsets[partIndex], length: 1)) else {
                return nil
            }
            let edge = isEnd ? result.end : result.start
            let origin = node.view.convert(CGPoint(x: edge.x, y: edge.y), to: self.view)
            return TextRangeRectEdge(x: origin.x, y: origin.y, height: edge.height)
        case .table:
            let frame = self.frame(of: part)
            let height: CGFloat = 20.0
            return isEnd ? TextRangeRectEdge(x: frame.maxX, y: frame.maxY - height, height: height) : TextRangeRectEdge(x: frame.minX, y: frame.minY, height: height)
        }
    }
}
