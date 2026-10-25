import UIKit
import AsyncDisplayKit
import Display
import InteractiveTextComponent

struct ChatTableStyle {
    var borderColor: UIColor
    var headerBackgroundColor: UIColor
}

/// A Markdown table in an assistant message: a bordered grid with a tinted header row that scrolls sideways when it is
/// wider than the message. Layout is measured off the main thread, like every other row content.
final class ChatTableNode: ASDisplayNode {
    private static let cellInsets = UIEdgeInsets(top: 8.0, left: 12.0, bottom: 8.0, right: 12.0)
    private static let minColumnWidth: CGFloat = 44.0
    private static let maxColumnWidth: CGFloat = 240.0
    private static let cornerRadius: CGFloat = 12.0

    private var scrollView: UIScrollView?
    private let contentNode = ASDisplayNode()
    /// InteractiveTextNode, as the answer's text: it draws formulas (text attachments), which TextNode does not.
    private var cellNodes: [InteractiveTextNode] = []
    private var lineNodes: [ASDisplayNode] = []
    private let headerBackgroundNode = ASDisplayNode()

    override init() {
        super.init()
        self.contentNode.addSubnode(self.headerBackgroundNode)
    }

    override func didLoad() {
        super.didLoad()
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.scrollsToTop = false
        scrollView.layer.cornerRadius = ChatTableNode.cornerRadius
        scrollView.layer.cornerCurve = .continuous
        scrollView.clipsToBounds = true
        // As the code blocks' scrollers: only an edge swipe goes back over a table, and none once it is scrolled.
        scrollView.disablesInteractiveTransitionGestureRecognizer = true
        scrollView.disablesInteractiveTransitionGestureRecognizerNow = { [weak scrollView] in
            return (scrollView?.contentOffset.x ?? 0.0) > 0.0
        }
        scrollView.addSubview(self.contentNode.view)
        self.view.addSubview(scrollView)
        self.scrollView = scrollView
    }

    /// What the cells were last laid out for: the same again changes nothing.
    private struct Applied {
        var table: MarkdownTable
        var maxWidth: CGFloat
        var borderColor: UIColor
        var headerBackgroundColor: UIColor
        var size: CGSize
    }

    private var applied: Applied?

    /// The table as text, for a selection that takes it in: a row a line, cells a tab apart, as a spreadsheet pastes.
    var plainText: String? {
        guard let table = self.applied?.table else {
            return nil
        }
        return ([table.header] + table.rows).map { row in row.map { MarkdownText.copiedText($0) }.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// Measures `table` within `maxWidth`; the returned apply lays the cells out (main thread). Call it on the main
    /// thread, as Telegram's asyncLayout: it takes the cells there are now, and the returned closure may run anywhere.
    /// A table laid out again unchanged (as every streaming step of the answer around it does) keeps its cells, drawn;
    /// one that changed keeps the cells whose text did not, so only what is new is drawn again.
    static func asyncLayout(_ node: ChatTableNode) -> (_ table: MarkdownTable, _ style: ChatTableStyle, _ maxWidth: CGFloat) -> (CGSize, () -> Void) {
        let existingCells = node.cellNodes
        let applied = node.applied
        return { [weak node] table, style, maxWidth in
            if let applied, applied.table == table, applied.maxWidth == maxWidth, applied.borderColor.isEqual(style.borderColor), applied.headerBackgroundColor.isEqual(style.headerBackgroundColor) {
                return (applied.size, {})
            }
            let columnCount = max(1, table.columnCount)
            let rows = [table.header] + table.rows
            let insets = ChatTableNode.cellInsets
            // Natural widths, clamped; then each row's height at those widths.
            var columnWidths = Array(repeating: ChatTableNode.minColumnWidth, count: columnCount)
            for row in rows {
                for (column, cell) in row.enumerated() where column < columnCount {
                    // Measured by Core Text, as drawn: a formula is a run delegate, which `boundingRect` cannot measure (it
                    // raises on the attachment).
                    let (natural, _) = InteractiveTextNode.asyncLayout(nil)(InteractiveTextNodeLayoutArguments(attributedString: cell, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: ChatTableNode.maxColumnWidth, height: .greatestFiniteMagnitude)))
                    columnWidths[column] = min(ChatTableNode.maxColumnWidth, max(columnWidths[column], ceil(natural.size.width) + insets.left + insets.right))
                }
            }
            // A narrow table stretches its columns to the message width.
            let naturalWidth = columnWidths.reduce(0.0, +)
            if naturalWidth < maxWidth {
                let extra = (maxWidth - naturalWidth) / CGFloat(columnCount)
                columnWidths = columnWidths.map { floor($0 + extra) }
            }
            var cells: [(frame: CGRect, apply: (InteractiveTextNode.ApplyArguments) -> InteractiveTextNode)] = []
            var rowFrames: [CGRect] = []
            var y: CGFloat = 0.0
            for row in rows {
                var x: CGFloat = 0.0
                var rowHeight: CGFloat = 0.0
                var rowCells: [(CGFloat, CGFloat, InteractiveTextNodeLayout, (InteractiveTextNode.ApplyArguments) -> InteractiveTextNode)] = []
                for column in 0 ..< columnCount {
                    let cell = column < row.count ? row[column] : NSAttributedString()
                    let width = columnWidths[column]
                    // The cell in this place last time, kept with its drawing when its text is the same.
                    let existing = cells.count + rowCells.count < existingCells.count ? existingCells[cells.count + rowCells.count] : nil
                    let (layout, apply) = InteractiveTextNode.asyncLayout(existing)(InteractiveTextNodeLayoutArguments(attributedString: cell, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: width - insets.left - insets.right, height: .greatestFiniteMagnitude)))
                    rowHeight = max(rowHeight, layout.size.height + insets.top + insets.bottom)
                    rowCells.append((x, width, layout, apply))
                    x += width
                }
                for (column, (cellX, width, layout, apply)) in rowCells.enumerated() {
                    // As the column's delimiter says: a right-aligned column's cells end at its right inset.
                    var x = cellX + insets.left
                    let free = max(0.0, width - insets.left - insets.right - layout.size.width)
                    switch column < table.alignments.count ? table.alignments[column] : .left {
                    case .right:
                        x += free
                    case .center:
                        x += floor(free / 2.0)
                    default:
                        break
                    }
                    cells.append((CGRect(origin: CGPoint(x: x, y: y + insets.top), size: layout.size), apply))
                }
                rowFrames.append(CGRect(x: 0.0, y: y, width: x, height: rowHeight))
                y += rowHeight
            }
            let contentSize = CGSize(width: columnWidths.reduce(0.0, +), height: y)
            let size = CGSize(width: min(maxWidth, contentSize.width), height: contentSize.height)
            return (size, {
                guard let node else {
                    return
                }
                // Apply runs on the main thread; the scroll view exists once the node has loaded.
                let _ = node.view
                let cellNodes = cells.map { cell -> InteractiveTextNode in
                    let textNode = cell.apply(InteractiveTextNode.ApplyArguments(animation: .None, spoilerTextColor: .label, spoilerEffectColor: .label, areContentAnimationsEnabled: false, spoilerExpandRect: nil))
                    textNode.isUserInteractionEnabled = false
                    textNode.frame = cell.frame
                    if textNode.supernode !== node.contentNode {
                        node.contentNode.addSubnode(textNode)
                    }
                    return textNode
                }
                for cellNode in node.cellNodes where !cellNodes.contains(where: { $0 === cellNode }) {
                    cellNode.removeFromSupernode()
                }
                node.cellNodes = cellNodes
                let lineWidth = 1.0 / UIScreen.main.scale
                var lines: [CGRect] = []
                for frame in rowFrames.dropLast() {
                    lines.append(CGRect(x: 0.0, y: frame.maxY - lineWidth / 2.0, width: contentSize.width, height: lineWidth))
                }
                var x: CGFloat = 0.0
                for width in columnWidths.dropLast() {
                    x += width
                    lines.append(CGRect(x: x - lineWidth / 2.0, y: 0.0, width: lineWidth, height: contentSize.height))
                }
                for (index, frame) in lines.enumerated() {
                    let line: ASDisplayNode
                    if index < node.lineNodes.count {
                        line = node.lineNodes[index]
                    } else {
                        line = ASDisplayNode()
                        line.isLayerBacked = true
                        node.contentNode.addSubnode(line)
                        node.lineNodes.append(line)
                    }
                    line.backgroundColor = style.borderColor
                    line.frame = frame
                }
                while node.lineNodes.count > lines.count {
                    node.lineNodes.removeLast().removeFromSupernode()
                }
                node.headerBackgroundNode.backgroundColor = style.headerBackgroundColor
                node.headerBackgroundNode.frame = rowFrames.first ?? CGRect()
                node.contentNode.frame = CGRect(origin: CGPoint(), size: contentSize)
                if let scrollView = node.scrollView {
                    scrollView.frame = CGRect(origin: CGPoint(), size: size)
                    scrollView.contentSize = contentSize
                    scrollView.layer.borderWidth = lineWidth
                    scrollView.layer.borderColor = style.borderColor.cgColor
                }
                node.applied = Applied(table: table, maxWidth: maxWidth, borderColor: style.borderColor, headerBackgroundColor: style.headerBackgroundColor, size: size)
            })
        }
    }
}
