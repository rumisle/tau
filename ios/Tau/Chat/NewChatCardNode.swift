import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData

/// The card in an empty new chat, after Telegram's ChatEmptyNode: on the service-message fill over the wallpaper,
/// which server the chat will be on (while there are several) and with which model, each a row to change it. A new chat
/// needs no screen before it.
final class NewChatCardNode: ASDisplayNode {
    struct Content: Equatable {
        /// The server's name and address; nil with one server.
        var server: (name: String, address: String)?
        var model: String
        var modelDetail: String

        static func == (lhs: Content, rhs: Content) -> Bool {
            return lhs.server?.name == rhs.server?.name && lhs.server?.address == rhs.server?.address && lhs.model == rhs.model && lhs.modelDetail == rhs.modelDetail
        }
    }

    private final class Row {
        let button = HighlightTrackingButtonNode()
        let caption = ImmediateTextNode()
        let value = ImmediateTextNode()
        let detail = ImmediateTextNode()
        let arrow = ASImageNode()
        let icon = ASImageNode()
    }

    private let backgroundNode = NavigationBackgroundNode(color: .clear)
    private let titleNode = ImmediateTextNode()
    private let footerNode = ImmediateTextNode()
    private let separatorNode = ASDisplayNode()
    private let rows = [Row(), Row()]
    /// The server row, with the row's view to anchor a menu.
    var serverTapped: ((UIView) -> Void)?
    var modelTapped: (() -> Void)?
    private var content: Content?
    private var theme: TauTheme?

    override init() {
        super.init()
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.footerNode)
        self.titleNode.textAlignment = .center
        self.footerNode.textAlignment = .center
        self.footerNode.maximumNumberOfLines = 2
        for (index, row) in self.rows.enumerated() {
            row.value.maximumNumberOfLines = 1
            row.value.truncationType = .middle
            row.detail.maximumNumberOfLines = 1
            row.detail.truncationType = .middle
            row.arrow.displaysAsynchronously = false
            row.icon.displaysAsynchronously = false
            self.addSubnode(row.button)
            for node in [row.icon, row.caption, row.value, row.detail, row.arrow] as [ASDisplayNode] {
                node.isUserInteractionEnabled = false
                row.button.addSubnode(node)
            }
            row.button.highligthedChanged = { [weak row] highlighted in
                guard let row else {
                    return
                }
                if highlighted {
                    row.button.layer.removeAnimation(forKey: "opacity")
                    row.button.alpha = 0.55
                } else {
                    row.button.alpha = 1.0
                    row.button.layer.animateAlpha(from: 0.55, to: 1.0, duration: 0.2)
                }
            }
            row.button.addTarget(self, action: index == 0 ? #selector(self.serverPressed) : #selector(self.modelPressed), forControlEvents: .touchUpInside)
            row.button.isAccessibilityElement = true
            row.button.accessibilityIdentifier = index == 0 ? "newChatServer" : "newChatModel"
            row.button.accessibilityTraits = .button
        }
    }

    @objc private func serverPressed() {
        self.serverTapped?(self.rows[0].button.view)
    }

    @objc private func modelPressed() {
        self.modelTapped?()
    }

    /// Lays the card out for `content` and returns its size.
    func update(content: Content, theme: TauTheme, width: CGFloat) -> CGSize {
        let presentationTheme = theme.presentationTheme
        let serviceColor = presentationTheme.chat.serviceMessage.components.withDefaultWallpaper
        let textColor = serviceColor.primaryText
        if self.theme !== theme {
            self.theme = theme
            self.backgroundNode.updateColor(color: selectDateFillStaticColor(theme: presentationTheme, wallpaper: theme.wallpaper), enableBlur: dateFillNeedsBlur(theme: presentationTheme, wallpaper: theme.wallpaper), transition: .immediate)
            self.separatorNode.backgroundColor = textColor.withAlphaComponent(0.2)
            let arrow = generateTintedImage(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)), color: textColor.withAlphaComponent(0.6))
            for (index, row) in self.rows.enumerated() {
                row.arrow.image = arrow
                row.icon.image = generateTintedImage(image: UIImage(bundleImageName: index == 0 ? "Chat/Context Menu/Message" : "Chat/Context Menu/Settings"), color: textColor)
            }
        }
        self.content = content
        // ChatEmptyNode's metrics: 15 pt insets, 270 pt at most, a 15 pt semibold title over 13 pt text.
        let insets = UIEdgeInsets(top: 15.0, left: 15.0, bottom: 15.0, right: 15.0)
        let maxWidth = min(270.0, width - 32.0)
        let innerWidth = maxWidth - insets.left - insets.right

        self.titleNode.attributedText = NSAttributedString(string: "New Chat", font: Font.semibold(15.0), textColor: textColor)
        self.footerNode.attributedText = NSAttributedString(string: "Send a message to start.", font: Font.regular(13.0), textColor: textColor.withAlphaComponent(0.7))
        let titleSize = self.titleNode.updateLayout(CGSize(width: innerWidth, height: 40.0))
        let footerSize = self.footerNode.updateLayout(CGSize(width: innerWidth, height: 40.0))

        let values: [(String, String, String)?] = [content.server.map { ("Server", $0.name, $0.address) }, ("Model", content.model, content.modelDetail)]
        var y = insets.top + titleSize.height + 12.0
        var rowFrames: [CGRect] = []
        for (index, row) in self.rows.enumerated() {
            row.button.isHidden = values[index] == nil
            guard let (caption, value, detail) = values[index] else {
                continue
            }
            row.caption.attributedText = NSAttributedString(string: caption.uppercased(), font: Font.medium(11.0), textColor: textColor.withAlphaComponent(0.6))
            row.value.attributedText = NSAttributedString(string: value, font: Font.semibold(15.0), textColor: textColor)
            row.detail.attributedText = NSAttributedString(string: detail, font: Font.regular(13.0), textColor: textColor.withAlphaComponent(0.7))
            let iconInset: CGFloat = 34.0
            let textWidth = innerWidth - 18.0 - iconInset
            let captionSize = row.caption.updateLayout(CGSize(width: textWidth, height: 20.0))
            let valueSize = row.value.updateLayout(CGSize(width: textWidth, height: 24.0))
            let detailSize = row.detail.updateLayout(CGSize(width: textWidth, height: 20.0))
            let rowHeight = 8.0 + captionSize.height + 2.0 + valueSize.height + (detail.isEmpty ? 0.0 : 1.0 + detailSize.height) + 8.0
            let rowFrame = CGRect(x: insets.left - 8.0, y: y, width: innerWidth + 16.0, height: rowHeight)
            row.button.frame = rowFrame
            var textY: CGFloat = 8.0
            let textX = 8.0 + iconInset
            if let image = row.icon.image {
                row.icon.frame = CGRect(x: 8.0 + floor((iconInset - 8.0 - image.size.width) / 2.0), y: floor((rowHeight - image.size.height) / 2.0), width: image.size.width, height: image.size.height)
            }
            row.caption.frame = CGRect(origin: CGPoint(x: textX, y: textY), size: captionSize)
            textY += captionSize.height + 2.0
            row.value.frame = CGRect(origin: CGPoint(x: textX, y: textY), size: valueSize)
            textY += valueSize.height + 1.0
            row.detail.frame = CGRect(origin: CGPoint(x: textX, y: textY), size: detailSize)
            row.detail.isHidden = detail.isEmpty
            if let image = row.arrow.image {
                row.arrow.frame = CGRect(x: rowFrame.width - 8.0 - image.size.width, y: floor((rowHeight - image.size.height) / 2.0), width: image.size.width, height: image.size.height)
            }
            rowFrames.append(rowFrame)
            y += rowHeight
            if index == 0 {
                y += 1.0
            }
        }
        self.separatorNode.isHidden = rowFrames.count < 2
        self.separatorNode.frame = CGRect(x: insets.left + 34.0, y: rowFrames.first?.maxY ?? 0.0, width: innerWidth - 34.0, height: UIScreenPixel)
        y += 10.0
        let size = CGSize(width: maxWidth, height: y + footerSize.height + insets.bottom)
        self.titleNode.frame = CGRect(origin: CGPoint(x: floor((size.width - titleSize.width) / 2.0), y: insets.top), size: titleSize)
        self.footerNode.frame = CGRect(origin: CGPoint(x: floor((size.width - footerSize.width) / 2.0), y: y), size: footerSize)
        self.backgroundNode.frame = CGRect(origin: CGPoint(), size: size)
        self.backgroundNode.update(size: size, cornerRadius: 20.0, transition: .immediate)
        return size
    }
}
