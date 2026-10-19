import UIKit
import AsyncDisplayKit
import Display

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
    private var cellNodes: [TextNode] = []
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
        scrollView.addSubview(self.contentNode.view)
        self.view.addSubview(scrollView)
        self.scrollView = scrollView
    }

    /// Measures `table` within `maxWidth`; the returned apply builds the cells (main thread).
    static func asyncLayout(_ node: ChatTableNode) -> (_ table: MarkdownTable, _ style: ChatTableStyle, _ maxWidth: CGFloat) -> (CGSize, () -> Void) {
        return { [weak node] table, style, maxWidth in
            let columnCount = max(1, table.columnCount)
            let rows = [table.header] + table.rows
            let insets = ChatTableNode.cellInsets

            // Natural widths, clamped; then each row's height at those widths.
            var columnWidths = Array(repeating: ChatTableNode.minColumnWidth, count: columnCount)
            for row in rows {
                for (column, cell) in row.enumerated() where column < columnCount {
                    let bounds = cell.boundingRect(with: CGSize(width: ChatTableNode.maxColumnWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
                    columnWidths[column] = min(ChatTableNode.maxColumnWidth, max(columnWidths[column], ceil(bounds.width) + insets.left + insets.right))
                }
            }
            // A narrow table stretches its columns to the message width.
            let naturalWidth = columnWidths.reduce(0.0, +)
            if naturalWidth < maxWidth {
                let extra = (maxWidth - naturalWidth) / CGFloat(columnCount)
                columnWidths = columnWidths.map { floor($0 + extra) }
            }

            var cells: [(frame: CGRect, apply: () -> TextNode)] = []
            var rowFrames: [CGRect] = []
            var y: CGFloat = 0.0
            for row in rows {
                var x: CGFloat = 0.0
                var rowHeight: CGFloat = 0.0
                var rowCells: [(CGFloat, CGFloat, TextNodeLayout, () -> TextNode)] = []
                for column in 0 ..< columnCount {
                    let cell = column < row.count ? row[column] : NSAttributedString()
                    let width = columnWidths[column]
                    let (layout, apply) = TextNode.asyncLayout(nil)(TextNodeLayoutArguments(attributedString: cell, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: width - insets.left - insets.right, height: .greatestFiniteMagnitude)))
                    rowHeight = max(rowHeight, layout.size.height + insets.top + insets.bottom)
                    rowCells.append((x, width, layout, apply))
                    x += width
                }
                for (cellX, _, layout, apply) in rowCells {
                    cells.append((CGRect(origin: CGPoint(x: cellX + insets.left, y: y + insets.top), size: layout.size), apply))
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
                for cellNode in node.cellNodes {
                    cellNode.removeFromSupernode()
                }
                for lineNode in node.lineNodes {
                    lineNode.removeFromSupernode()
                }
                node.cellNodes = cells.map { cell in
                    let textNode = cell.apply()
                    textNode.frame = cell.frame
                    node.contentNode.addSubnode(textNode)
                    return textNode
                }

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
                node.lineNodes = lines.map { frame in
                    let line = ASDisplayNode()
                    line.isLayerBacked = true
                    line.backgroundColor = style.borderColor
                    line.frame = frame
                    node.contentNode.addSubnode(line)
                    return line
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
            })
        }
    }
}
