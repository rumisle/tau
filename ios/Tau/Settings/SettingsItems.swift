import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AppBundle

// Grouped list rows in Telegram's iOS 26 ItemList style (ItemListUI, `ItemListSystemStyle.glass`): sections inset 16 pt
// with 26 pt corners, 15 pt vertical padding, 30 pt rounded icons, 17 pt text.

private let sectionCornerRadius: CGFloat = 26.0
private let sectionSideInset: CGFloat = 16.0
private let separatorHeight = 1.0 / UIScreen.main.scale
private let titleFont = Font.regular(17.0)
private let headerFont = Font.regular(13.0)

private let colorRed = UIColor(rgb: 0xFF453A)
private let colorGreen = UIColor(rgb: 0x34C759)
private let colorBlue = UIColor(rgb: 0x0079ff)
private let colorLightBlue = UIColor(rgb: 0x32ADE6)
private let colorOrange = UIColor(rgb: 0xFF9F0A)
private let colorPurple = UIColor(rgb: 0xAF52DE)
private let colorGray = UIColor(rgb: 0x8E8E93)

enum SettingsIcon {
    static let server = renderSettingsIcon(name: "Item List/Icons/Proxy", backgroundColors: [colorGreen])
    static let model = renderSettingsIcon(name: "Item List/Icons/AITools", backgroundColors: [colorPurple])
    static let projects = renderSettingsIcon(name: "Item List/Icons/Folder", backgroundColors: [colorLightBlue])
    static let appearance = renderSettingsIcon(name: "Item List/Icons/Appearance", backgroundColors: [colorLightBlue])
    static let notifications = renderSettingsIcon(name: "Item List/Icons/Notifications", backgroundColors: [colorRed])
    static let data = renderSettingsIcon(name: "Item List/Icons/Data", backgroundColors: [colorGreen])
    static let privacy = renderSettingsIcon(name: "Item List/Icons/Privacy", backgroundColors: [colorGray])
    static let about = renderSettingsIcon(name: "Item List/Icons/Faq", backgroundColors: [colorOrange])
    static let blue = colorBlue
    static let repository = renderSettingsIcon(name: "Item List/Icons/Folder", backgroundColors: [colorOrange])

    private static var projectIcons: [String: UIImage] = [:]

    /// A project's folder icon, in a color derived from its name so each project keeps one.
    static func projectIcon(for path: String) -> UIImage? {
        if let icon = self.projectIcons[path] {
            return icon
        }
        let colors = [colorLightBlue, colorGreen, colorOrange, colorPurple, colorRed, colorBlue]
        let index = abs(path.hashValue) % colors.count
        let icon = renderSettingsIcon(name: "Item List/Icons/Folder", backgroundColors: [colors[index]])
        self.projectIcons[path] = icon
        return icon
    }
}

/// Copied from Telegram-iOS TelegramPresentationData/Sources/Resources/PresentationResourcesSettings.swift.
func renderSettingsIcon(name: String, scaleFactor: CGFloat = 1.0, backgroundColors: [UIColor]? = nil) -> UIImage? {
    let gradientImage = UIImage(bundleImageName: "Item List/Icons/Gradient")
    let backdropImage = UIImage(bundleImageName: "Item List/Icons/Backdrop")
    return generateImage(CGSize(width: 30.0, height: 30.0), contextGenerator: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)

        if let backgroundColors {
            var locations: [CGFloat] = [0.0, 1.0]
            let colors: [CGColor] = backgroundColors.map(\.cgColor)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: &locations)!
            context.drawLinearGradient(gradient, start: CGPoint(x: size.width, y: size.height), end: CGPoint(x: 0.0, y: 0.0), options: CGGradientDrawingOptions())

            if let gradientImage, let cgImage = gradientImage.cgImage {
                context.setBlendMode(.plusLighter)
                context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            }
            if let backdropImage, let cgImage = backdropImage.cgImage {
                context.setBlendMode(.overlay)
                context.draw(cgImage, in: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: size))
            }
            context.setBlendMode(.normal)

            if let image = UIImage(bundleImageName: name), let maskImage = image.cgImage {
                let imageSize = CGSize(width: image.size.width * scaleFactor, height: image.size.height * scaleFactor)
                let imageRect = CGRect(origin: CGPoint(x: (bounds.width - imageSize.width) * 0.5, y: (bounds.height - imageSize.height) * 0.5), size: imageSize)
                context.saveGState()
                context.clip(to: imageRect, mask: maskImage)
                context.setFillColor(UIColor.white.cgColor)
                context.fill(imageRect)
                context.restoreGState()
            }

            let outerPath = UIBezierPath(rect: CGRect(origin: .zero, size: size))
            let innerPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8.0)
            outerPath.append(innerPath)
            context.saveGState()
            outerPath.usesEvenOddFillRule = true
            context.addPath(outerPath.cgPath)
            context.clip(using: .evenOdd)
            context.setBlendMode(.clear)
            context.fill(CGRect(origin: .zero, size: size))
            context.restoreGState()
        }
    })
}

/// Where a row sits in its section, for its corners and separator.
struct SettingsRowPosition: Equatable {
    var isFirst: Bool
    var isLast: Bool
}

// MARK: - Row

final class SettingsRowItem: ListViewItem {
    enum Accessory: Equatable {
        case none
        case disclosure(label: String)
        case checkmark(Bool)
    }

    let theme: TauTheme
    let icon: UIImage?
    let title: String
    /// A second line, as LocalizationListItem's localized name under a language.
    let subtitle: String?
    let titleColor: UIColor?
    let accessory: Accessory
    let position: SettingsRowPosition
    let action: (() -> Void)?

    init(theme: TauTheme, icon: UIImage?, title: String, subtitle: String? = nil, titleColor: UIColor? = nil, accessory: Accessory, position: SettingsRowPosition, action: (() -> Void)?) {
        self.theme = theme
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.accessory = accessory
        self.position = position
        self.action = action
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return self.action != nil
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action?()
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = SettingsRowItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { return (nil, { _ in apply(.None) }) })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? SettingsRowItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params)
                Queue.mainQueue().async {
                    completion(layout, { _ in apply(animation) })
                }
            }
        }
    }
}

final class SettingsRowItemNode: ListViewItemNode {
    private let backgroundNode = ASDisplayNode()
    private let highlightNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private let iconNode = ASImageNode()
    private let titleNode = TextNode()
    private let subtitleNode = TextNode()
    private let labelNode = TextNode()
    private let arrowNode = ASImageNode()
    private let separatorNode = ASDisplayNode()

    private var item: SettingsRowItem?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.backgroundNode.isLayerBacked = true
        self.highlightNode.isLayerBacked = true
        self.highlightNode.alpha = 0.0
        self.iconNode.isLayerBacked = true
        self.iconNode.displaysAsynchronously = false
        self.arrowNode.isLayerBacked = true
        self.arrowNode.displaysAsynchronously = false
        self.separatorNode.isLayerBacked = true
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.highlightNode)
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.iconNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
        self.addSubnode(self.labelNode)
        self.addSubnode(self.arrowNode)
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        if highlighted {
            self.highlightNode.layer.removeAllAnimations()
            self.highlightNode.alpha = 1.0
        } else {
            self.highlightNode.alpha = 0.0
            if animated {
                self.highlightNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3)
            }
        }
    }

    func asyncLayout() -> (_ item: SettingsRowItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeSubtitleLayout = TextNode.asyncLayout(self.subtitleNode)
        let makeLabelLayout = TextNode.asyncLayout(self.labelNode)

        return { [weak self] item, params in
            let theme = item.theme.list
            let sectionLeft = params.leftInset + sectionSideInset
            let sectionWidth = params.width - params.leftInset - params.rightInset - sectionSideInset * 2.0
            let contentLeft = sectionLeft + (item.icon != nil ? 62.0 : 20.0)
            let rightInset: CGFloat = 20.0

            var labelText = ""
            var showsArrow = false
            var showsCheck = false
            switch item.accessory {
            case .none:
                break
            case let .disclosure(label):
                labelText = label
                showsArrow = true
            case let .checkmark(value):
                showsCheck = value
            }
            let accessoryWidth: CGFloat = showsArrow || showsCheck ? 22.0 : 0.0
            let (labelLayout, labelApply) = makeLabelLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: labelText, font: titleFont, textColor: theme.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: sectionWidth * 0.5, height: 30.0)))
            let maxTitleWidth = sectionLeft + sectionWidth - rightInset - accessoryWidth - labelLayout.size.width - 10.0 - contentLeft
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: titleFont, textColor: item.titleColor ?? theme.itemPrimaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(20.0, maxTitleWidth), height: 30.0)))

            let (subtitleLayout, subtitleApply) = makeSubtitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.subtitle ?? "", font: Font.regular(14.0), textColor: theme.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(20.0, maxTitleWidth), height: 30.0)))
            let hasSubtitle = !(item.subtitle ?? "").isEmpty
            // ItemListCheckboxItem's two-line metrics: 11 pt insets and 1 pt between the lines.
            let verticalInset: CGFloat = hasSubtitle ? 11.0 : 15.0
            let height = verticalInset * 2.0 + titleLayout.size.height + (hasSubtitle ? subtitleLayout.size.height + 1.0 : 0.0)
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())

            return (layout, { _ in
                guard let self else {
                    return
                }
                self.item = item
                self.isAccessibilityElement = true
                self.accessibilityLabel = item.title
                self.accessibilityIdentifier = item.title
                self.accessibilityTraits = item.action == nil ? [] : .button
                let _ = titleApply()
                let _ = subtitleApply()
                let _ = labelApply()

                let sectionFrame = CGRect(x: sectionLeft, y: 0.0, width: sectionWidth, height: height)
                self.backgroundNode.backgroundColor = theme.itemBlocksBackgroundColor
                self.backgroundNode.frame = sectionFrame
                self.highlightNode.backgroundColor = theme.itemHighlightedBackgroundColor
                self.highlightNode.frame = sectionFrame
                // Round only the section's outer corners.
                var corners: CACornerMask = []
                if item.position.isFirst {
                    corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner])
                }
                if item.position.isLast {
                    corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
                }
                for node in [self.backgroundNode, self.highlightNode] {
                    node.layer.cornerRadius = corners.isEmpty ? 0.0 : sectionCornerRadius
                    node.layer.maskedCorners = corners
                    node.layer.cornerCurve = .continuous
                }

                if let icon = item.icon {
                    self.iconNode.image = icon
                    self.iconNode.isHidden = false
                    self.iconNode.frame = CGRect(x: sectionLeft + 16.0, y: floor((height - 30.0) / 2.0), width: 30.0, height: 30.0)
                } else {
                    self.iconNode.isHidden = true
                }
                if hasSubtitle {
                    self.titleNode.frame = CGRect(origin: CGPoint(x: contentLeft, y: verticalInset), size: titleLayout.size)
                    self.subtitleNode.frame = CGRect(origin: CGPoint(x: contentLeft, y: verticalInset + titleLayout.size.height + 1.0), size: subtitleLayout.size)
                } else {
                    self.titleNode.frame = CGRect(origin: CGPoint(x: contentLeft, y: floor((height - titleLayout.size.height) / 2.0)), size: titleLayout.size)
                }
                self.subtitleNode.isHidden = !hasSubtitle

                let accessoryX = sectionFrame.maxX - rightInset
                if showsArrow {
                    self.arrowNode.image = generateTintedImage(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold)), color: theme.disclosureArrowColor)
                } else if showsCheck {
                    self.arrowNode.image = generateTintedImage(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16.0, weight: .semibold)), color: theme.itemAccentColor)
                }
                self.arrowNode.isHidden = !(showsArrow || showsCheck)
                if let image = self.arrowNode.image {
                    self.arrowNode.frame = CGRect(x: accessoryX - image.size.width, y: floor((height - image.size.height) / 2.0), width: image.size.width, height: image.size.height)
                }
                let labelRight = accessoryX - (showsArrow ? 22.0 : 0.0)
                self.labelNode.frame = CGRect(origin: CGPoint(x: labelRight - labelLayout.size.width, y: floor((height - labelLayout.size.height) / 2.0)), size: labelLayout.size)

                self.separatorNode.backgroundColor = theme.itemBlocksSeparatorColor
                self.separatorNode.isHidden = item.position.isLast
                self.separatorNode.frame = CGRect(x: contentLeft, y: height - separatorHeight, width: sectionFrame.maxX - contentLeft, height: separatorHeight)
            })
        }
    }
}

// MARK: - Section header and footer text

final class SettingsTextItem: ListViewItem {
    enum Kind {
        case header
        case footer
    }

    let theme: TauTheme
    let text: String
    let kind: Kind

    init(theme: TauTheme, text: String, kind: Kind) {
        self.theme = theme
        self.text = text
        self.kind = kind
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = SettingsTextItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { return (nil, { _ in apply() }) })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? SettingsTextItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params)
                Queue.mainQueue().async {
                    completion(layout, { _ in apply() })
                }
            }
        }
    }
}

final class SettingsTextItemNode: ListViewItemNode {
    private let textNode = TextNode()

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.addSubnode(self.textNode)
    }

    func asyncLayout() -> (_ item: SettingsTextItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        return { [weak self] item, params in
            let theme = item.theme.list
            let left = params.leftInset + sectionSideInset + 20.0
            let width = params.width - left - params.rightInset - sectionSideInset - 20.0
            let text = item.kind == .header ? item.text.uppercased() : item.text
            let color = item.kind == .header ? theme.sectionHeaderTextColor : theme.freeTextColor
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: text, font: headerFont, textColor: color), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: width, height: .greatestFiniteMagnitude)))
            let insets = item.kind == .header ? UIEdgeInsets(top: 22.0, left: 0.0, bottom: 7.0, right: 0.0) : UIEdgeInsets(top: 7.0, left: 0.0, bottom: 0.0, right: 0.0)
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: textLayout.size.height), insets: insets)
            return (layout, {
                guard let self else {
                    return
                }
                let _ = textApply()
                self.textNode.frame = CGRect(origin: CGPoint(x: left, y: 0.0), size: textLayout.size)
            })
        }
    }
}

// MARK: - Profile header

/// The top of Settings: a large avatar, a name and a status line, as Telegram's own settings screen.
final class SettingsProfileItem: ListViewItem {
    let theme: TauTheme
    let title: String
    let subtitle: String

    init(theme: TauTheme, title: String, subtitle: String) {
        self.theme = theme
        self.title = title
        self.subtitle = subtitle
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = SettingsProfileItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { return (nil, { _ in apply() }) })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? SettingsProfileItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params)
                Queue.mainQueue().async {
                    completion(layout, { _ in apply() })
                }
            }
        }
    }
}

final class SettingsProfileItemNode: ListViewItemNode {
    private let avatarNode = ASImageNode()
    private let titleNode = TextNode()
    private let subtitleNode = TextNode()

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.avatarNode.displaysAsynchronously = false
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
    }

    func asyncLayout() -> (_ item: SettingsProfileItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeSubtitleLayout = TextNode.asyncLayout(self.subtitleNode)
        return { [weak self] item, params in
            let avatarSize: CGFloat = 100.0
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: Font.semibold(28.0), textColor: item.theme.list.itemPrimaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: params.width - 40.0, height: 40.0)))
            let (subtitleLayout, subtitleApply) = makeSubtitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.subtitle, font: Font.regular(17.0), textColor: item.theme.list.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: params.width - 40.0, height: 30.0)))
            let height = avatarSize + 14.0 + titleLayout.size.height + 2.0 + subtitleLayout.size.height
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets(top: 8.0, left: 0.0, bottom: 4.0, right: 0.0))
            let avatar = Avatar.image(letters: "τ", colorIndex: 5, diameter: avatarSize)
            return (layout, {
                guard let self else {
                    return
                }
                let _ = titleApply()
                let _ = subtitleApply()
                self.avatarNode.image = avatar
                self.avatarNode.frame = CGRect(x: floor((params.width - avatarSize) / 2.0), y: 0.0, width: avatarSize, height: avatarSize)
                self.titleNode.frame = CGRect(origin: CGPoint(x: floor((params.width - titleLayout.size.width) / 2.0), y: avatarSize + 14.0), size: titleLayout.size)
                self.subtitleNode.frame = CGRect(origin: CGPoint(x: floor((params.width - subtitleLayout.size.width) / 2.0), y: self.titleNode.frame.maxY + 2.0), size: subtitleLayout.size)
            })
        }
    }
}
