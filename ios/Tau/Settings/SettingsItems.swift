import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AppBundle
import ComponentFlow
import LottieComponent

// Grouped list rows in Telegram's iOS 26 ItemList style (ItemListUI, `ItemListSystemStyle.glass`): sections inset 16 pt
// with 26 pt corners, 15 pt vertical padding, 30 pt rounded icons, 17 pt text.

private let sectionCornerRadius: CGFloat = 26.0
private let sectionSideInset: CGFloat = 16.0
private let separatorHeight = 1.0 / UIScreen.main.scale
private let titleFont = Font.regular(17.0)

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
    static let thinking = renderSettingsIcon(name: "Item List/Icons/Tips", backgroundColors: [colorOrange])
    static let cache = renderSettingsIcon(name: "Item List/Icons/Speed", backgroundColors: [colorRed])
    static let dictation = renderSettingsIcon(name: "Chat/Input/Text/IconMicrophone", scaleFactor: 0.75, backgroundColors: [colorPurple])
    static let compaction = renderSettingsIcon(name: "Item List/Icons/Data", backgroundColors: [colorOrange])
    static let storage = renderSettingsIcon(name: "Item List/Icons/Pie", backgroundColors: [colorGreen])
    static let network = renderSettingsIcon(name: "Item List/Icons/Stats", backgroundColors: [colorBlue])
    static let usage = renderSettingsIcon(name: "Item List/Icons/Stats", backgroundColors: [colorPurple])
    /// PresentationResourcesSettings.chatFolders.
    static let chatFolders = renderSettingsIcon(name: "Item List/Icons/Folder", backgroundColors: [colorLightBlue])
    static let appearance = renderSettingsIcon(name: "Item List/Icons/Appearance", backgroundColors: [colorLightBlue])
    static let notifications = renderSettingsIcon(name: "Item List/Icons/Notifications", backgroundColors: [colorRed])
    static let data = renderSettingsIcon(name: "Item List/Icons/Data", backgroundColors: [colorGreen])
    static let privacy = renderSettingsIcon(name: "Item List/Icons/Privacy", backgroundColors: [colorGray])
    static let about = renderSettingsIcon(name: "Item List/Icons/Faq", backgroundColors: [colorOrange])
    static let blue = colorBlue
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
        /// A value on the right without the arrow, as ItemListDisclosureItem with `disclosureStyle: .none`.
        case value(String)
        case checkmark(Bool)
        /// Telegram's switch (Display's SwitchNode, as ItemListSwitchItem has); `toggled` gets the new value.
        case toggle(Bool)
        /// A small accent pill, as the Add of ChatListFilterPresetListSuggestedItem; the row's action is its tap.
        case button(String)
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
    let toggled: ((Bool) -> Void)?

    /// The second line's color: Telegram's proxy list shows a connected server's status in the accent color.
    var subtitleColor: UIColor?

    init(theme: TauTheme, icon: UIImage?, title: String, subtitle: String? = nil, subtitleColor: UIColor? = nil, titleColor: UIColor? = nil, accessory: Accessory, position: SettingsRowPosition, action: (() -> Void)?, toggled: ((Bool) -> Void)? = nil) {
        self.subtitleColor = subtitleColor
        self.toggled = toggled
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
    private let pillNode = ASImageNode()
    private let separatorNode = ASDisplayNode()
    private var switchNode: SwitchNode?

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
        self.pillNode.isLayerBacked = true
        self.pillNode.displaysAsynchronously = false
        self.addSubnode(self.pillNode)
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
            var toggleValue: Bool?
            var pillTitle: String?
            switch item.accessory {
            case let .button(title):
                pillTitle = title
            case let .toggle(value):
                toggleValue = value
            case .none:
                break
            case let .disclosure(label):
                labelText = label
                showsArrow = true
            case let .value(label):
                labelText = label
            case let .checkmark(value):
                showsCheck = value
            }
            let pillImage = pillTitle.map { title -> UIImage? in
                let text = NSAttributedString(string: title, font: Font.semibold(15.0), textColor: item.theme.presentationTheme.list.itemCheckColors.foregroundColor)
                let textSize = text.boundingRect(with: CGSize(width: 200.0, height: 40.0), options: .usesLineFragmentOrigin, context: nil).size
                let size = CGSize(width: ceil(textSize.width) + 24.0, height: 28.0)
                return generateImage(size, rotatedContext: { size, context in
                    context.clear(CGRect(origin: CGPoint(), size: size))
                    context.setFillColor(item.theme.presentationTheme.list.itemCheckColors.fillColor.cgColor)
                    context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: size.height / 2.0).cgPath)
                    context.fillPath()
                    UIGraphicsPushContext(context)
                    text.draw(at: CGPoint(x: 12.0, y: floor((size.height - textSize.height) / 2.0)))
                    UIGraphicsPopContext()
                })
            } ?? nil
            let accessoryWidth: CGFloat = toggleValue != nil ? 51.0 : (showsArrow || showsCheck ? 22.0 : (pillImage.map { $0.size.width + 8.0 } ?? 0.0))
            let (labelLayout, labelApply) = makeLabelLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: labelText, font: Font.regular(item.theme.scaled(17.0)), textColor: theme.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: sectionWidth * 0.5, height: .greatestFiniteMagnitude)))
            let maxTitleWidth = sectionLeft + sectionWidth - rightInset - accessoryWidth - labelLayout.size.width - 10.0 - contentLeft
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: Font.regular(item.theme.scaled(17.0)), textColor: item.titleColor ?? theme.itemPrimaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(20.0, maxTitleWidth), height: .greatestFiniteMagnitude)))

            let (subtitleLayout, subtitleApply) = makeSubtitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.subtitle ?? "", font: Font.regular(item.theme.scaled(14.0)), textColor: item.subtitleColor ?? theme.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(20.0, maxTitleWidth), height: .greatestFiniteMagnitude)))
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
                // VoiceOver reads the second line after the title.
                self.accessibilityValue = item.subtitle
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
                self.pillNode.image = pillImage
                self.pillNode.isHidden = pillImage == nil
                if let pillImage {
                    self.pillNode.frame = CGRect(x: accessoryX - pillImage.size.width + 4.0, y: floor((height - pillImage.size.height) / 2.0), width: pillImage.size.width, height: pillImage.size.height)
                }
                if let image = self.arrowNode.image {
                    self.arrowNode.frame = CGRect(x: accessoryX - image.size.width, y: floor((height - image.size.height) / 2.0), width: image.size.width, height: image.size.height)
                }
                if let toggleValue {
                    let switchNode: SwitchNode
                    if let current = self.switchNode {
                        switchNode = current
                    } else {
                        switchNode = SwitchNode()
                        switchNode.valueUpdated = { [weak self] value in
                            self?.item?.toggled?(value)
                        }
                        self.switchNode = switchNode
                        self.addSubnode(switchNode)
                    }
                    let colors = item.theme.presentationTheme.list.itemSwitchColors
                    switchNode.frameColor = colors.frameColor
                    switchNode.contentColor = colors.contentColor
                    switchNode.handleColor = colors.handleColor
                    if let switchView = switchNode.view as? UISwitch {
                        if switchNode.bounds.size.width.isZero {
                            switchView.sizeToFit()
                        }
                        let switchSize = switchView.bounds.size
                        switchNode.frame = CGRect(x: accessoryX - switchSize.width + 4.0, y: floor((height - switchSize.height) / 2.0), width: switchSize.width, height: switchSize.height)
                        if switchView.isOn != toggleValue {
                            switchView.setOn(toggleValue, animated: true)
                        }
                    }
                    switchNode.isHidden = false
                } else {
                    self.switchNode?.isHidden = true
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
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: text, font: Font.regular(item.theme.scaled(13.0)), textColor: color), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: width, height: .greatestFiniteMagnitude)))
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

// MARK: - Text field row

/// A row that is a text field, as Telegram's ItemListSingleLineInputItem (and the folder name's
/// ItemListFilterTitleInputItem): the placeholder in the secondary color, the text as it is typed.
final class SettingsInputItem: ListViewItem {
    let theme: TauTheme
    let text: String
    let placeholder: String
    let position: SettingsRowPosition
    let maxLength: Int
    let changed: (String) -> Void

    init(theme: TauTheme, text: String, placeholder: String, position: SettingsRowPosition = SettingsRowPosition(isFirst: true, isLast: true), maxLength: Int = 64, changed: @escaping (String) -> Void) {
        self.theme = theme
        self.text = text
        self.placeholder = placeholder
        self.position = position
        self.maxLength = maxLength
        self.changed = changed
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return false
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = SettingsInputItemNode()
            let layout = node.update(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { return (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? SettingsInputItemNode else {
                return
            }
            let layout = nodeValue.update(item: self, params: params)
            completion(layout, { _ in })
        }
    }
}

final class SettingsInputItemNode: ListViewItemNode, UITextFieldDelegate {
    private let backgroundNode = ASDisplayNode()
    private var textField: UITextField?
    private var item: SettingsInputItem?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.backgroundNode.isLayerBacked = true
        self.addSubnode(self.backgroundNode)
    }

    func focus() {
        self.textField?.becomeFirstResponder()
    }

    func update(item: SettingsInputItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        self.item = item
        let theme = item.theme.list
        let sectionLeft = params.leftInset + sectionSideInset
        let sectionWidth = params.width - params.leftInset - params.rightInset - sectionSideInset * 2.0
        let height: CGFloat = 52.0
        let frame = CGRect(x: sectionLeft, y: 0.0, width: sectionWidth, height: height)
        self.backgroundNode.backgroundColor = theme.itemBlocksBackgroundColor
        self.backgroundNode.frame = frame
        var corners: CACornerMask = []
        if item.position.isFirst {
            corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner])
        }
        if item.position.isLast {
            corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        }
        self.backgroundNode.layer.cornerRadius = corners.isEmpty ? 0.0 : sectionCornerRadius
        self.backgroundNode.layer.maskedCorners = corners
        self.backgroundNode.layer.cornerCurve = .continuous
        let textField: UITextField
        if let current = self.textField {
            textField = current
        } else {
            textField = UITextField()
            textField.delegate = self
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
            textField.addTarget(self, action: #selector(self.textChanged), for: .editingChanged)
            self.textField = textField
            self.view.addSubview(textField)
        }
        textField.font = titleFont
        textField.textColor = theme.itemPrimaryTextColor
        textField.tintColor = theme.itemAccentColor
        textField.keyboardAppearance = item.theme.presentationTheme.rootController.keyboardColor.keyboardAppearance
        textField.attributedPlaceholder = NSAttributedString(string: item.placeholder, font: titleFont, textColor: item.theme.presentationTheme.list.itemPlaceholderTextColor)
        if textField.text != item.text {
            textField.text = item.text
        }
        textField.accessibilityIdentifier = item.placeholder
        textField.frame = CGRect(x: sectionLeft + 20.0, y: 0.0, width: sectionWidth - 28.0, height: height)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }

    @objc private func textChanged() {
        guard let item = self.item, let textField = self.textField else {
            return
        }
        var text = textField.text ?? ""
        if text.count > item.maxLength {
            text = String(text.prefix(item.maxLength))
            textField.text = text
        }
        item.changed(text)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }
}

// MARK: - Accent colors

/// A row of color swatches, as Telegram's ThemeSettingsAccentColorItem: each a ring around a fill; the fill covers the
/// ring until chosen, then shrinks inside it. Scrolls sideways when the colors do not fit.
final class SettingsAccentColorsItem: ListViewItem {
    let theme: TauTheme
    let colors: [(id: String, color: UIColor)]
    let selected: String
    let position: SettingsRowPosition
    let select: (String) -> Void

    init(theme: TauTheme, colors: [(id: String, color: UIColor)], selected: String, position: SettingsRowPosition = SettingsRowPosition(isFirst: true, isLast: true), select: @escaping (String) -> Void) {
        self.theme = theme
        self.colors = colors
        self.selected = selected
        self.position = position
        self.select = select
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return false
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = SettingsAccentColorsItemNode()
            let layout = node.update(item: self, params: params, animated: false)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { return (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? SettingsAccentColorsItemNode else {
                return
            }
            let layout = nodeValue.update(item: self, params: params, animated: true)
            completion(layout, { _ in })
        }
    }
}

final class SettingsAccentColorsItemNode: ListViewItemNode {
    /// Telegram's swatch, in a cell a little narrower than its 60 pt, so a last one peeks out where they scroll.
    private static let cellSize = CGSize(width: 56.0, height: 58.0)
    private static let swatchSize = CGSize(width: 40.0, height: 40.0)

    private final class Swatch {
        let id: String
        let button = UIButton(type: .custom)
        let ring = UIImageView()
        let fill = UIImageView()
        var color: UIColor?
        var isSelected: Bool?

        init(id: String) {
            self.id = id
            self.ring.isUserInteractionEnabled = false
            self.fill.isUserInteractionEnabled = false
            self.button.addSubview(self.ring)
            self.button.addSubview(self.fill)
            self.button.isAccessibilityElement = true
            self.button.accessibilityIdentifier = "accent-\(id)"
            self.button.accessibilityLabel = id.capitalized
        }
    }

    private let backgroundNode = ASDisplayNode()
    private let scrollView = UIScrollView()
    private var swatches: [Swatch] = []
    private var item: SettingsAccentColorsItem?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.backgroundNode.isLayerBacked = true
        self.addSubnode(self.backgroundNode)
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.alwaysBounceHorizontal = false
        self.view.addSubview(self.scrollView)
    }

    func update(item: SettingsAccentColorsItem, params: ListViewItemLayoutParams, animated: Bool) -> ListViewItemNodeLayout {
        let previous = self.item
        self.item = item
        let theme = item.theme.list
        let sectionLeft = params.leftInset + sectionSideInset
        let sectionWidth = params.width - params.leftInset - params.rightInset - sectionSideInset * 2.0
        let height: CGFloat = SettingsAccentColorsItemNode.cellSize.height + 16.0
        let frame = CGRect(x: sectionLeft, y: 0.0, width: sectionWidth, height: height)
        self.backgroundNode.backgroundColor = theme.itemBlocksBackgroundColor
        self.backgroundNode.frame = frame
        var corners: CACornerMask = []
        if item.position.isFirst {
            corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner])
        }
        if item.position.isLast {
            corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        }
        self.backgroundNode.layer.cornerRadius = corners.isEmpty ? 0.0 : sectionCornerRadius
        self.backgroundNode.layer.maskedCorners = corners
        self.backgroundNode.layer.cornerCurve = .continuous
        self.scrollView.frame = frame
        self.scrollView.layer.cornerRadius = self.backgroundNode.layer.cornerRadius
        self.scrollView.layer.maskedCorners = corners
        self.scrollView.layer.cornerCurve = .continuous

        if previous.map({ $0.colors.map(\.id) }) != item.colors.map(\.id) {
            for swatch in self.swatches {
                swatch.button.removeFromSuperview()
            }
            self.swatches = item.colors.map { color in
                let swatch = Swatch(id: color.id)
                swatch.button.addTarget(self, action: #selector(self.tapped(_:)), for: .touchUpInside)
                self.scrollView.addSubview(swatch.button)
                return swatch
            }
        }
        let cell = SettingsAccentColorsItemNode.cellSize
        // Spread over the row when they fit, as Telegram's; otherwise side by side from an inset, scrolling.
        let sideInset: CGFloat = 6.0
        let fits = CGFloat(self.swatches.count) * cell.width + sideInset * 2.0 <= sectionWidth
        let spacing = fits && self.swatches.count > 1 ? (sectionWidth - sideInset * 2.0 - CGFloat(self.swatches.count) * cell.width) / CGFloat(self.swatches.count - 1) : 0.0
        let swatchSize = SettingsAccentColorsItemNode.swatchSize
        for (index, swatch) in self.swatches.enumerated() {
            let color = item.colors[index].color
            let isSelected = swatch.id == item.selected
            swatch.button.frame = CGRect(x: sideInset + CGFloat(index) * (cell.width + spacing), y: 8.0, width: cell.width, height: cell.height)
            let swatchFrame = CGRect(x: floor((cell.width - swatchSize.width) / 2.0), y: floor((cell.height - swatchSize.height) / 2.0), width: swatchSize.width, height: swatchSize.height)
            if swatch.color != color {
                swatch.color = color
                // On a list of nearly the same color, a hairline keeps white on a light theme and black on a dark one.
                let edge = color.argb == theme.itemBlocksBackgroundColor.argb || (color.lightness > 0.9 && !item.theme.overallDarkAppearance) || (color.lightness < 0.1 && item.theme.overallDarkAppearance)
                swatch.ring.image = accentRingImage(color: edge ? theme.itemSecondaryTextColor.withMultipliedAlpha(0.5) : color)
                swatch.fill.image = accentFillImage(color: color, stroke: edge ? theme.itemSecondaryTextColor.withMultipliedAlpha(0.3) : nil)
            }
            swatch.ring.bounds = CGRect(origin: CGPoint(), size: swatchFrame.size)
            swatch.ring.center = CGPoint(x: swatchFrame.midX, y: swatchFrame.midY)
            swatch.fill.bounds = CGRect(origin: CGPoint(), size: swatchFrame.size)
            swatch.fill.center = CGPoint(x: swatchFrame.midX, y: swatchFrame.midY)
            if swatch.isSelected != isSelected {
                let transition: ContainedViewLayoutTransition = animated && swatch.isSelected != nil ? .animated(duration: 0.3, curve: .easeInOut) : .immediate
                swatch.isSelected = isSelected
                transition.updateTransformScale(layer: swatch.fill.layer, scale: isSelected ? 1.0 : 1.2)
            }
            swatch.button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
        let contentWidth = CGFloat(self.swatches.count) * (cell.width + spacing) - spacing + sideInset * 2.0
        self.scrollView.contentSize = CGSize(width: max(contentWidth, sectionWidth), height: height)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }

    @objc private func tapped(_ button: UIButton) {
        guard let swatch = self.swatches.first(where: { $0.button === button }) else {
            return
        }
        self.item?.select(swatch.id)
    }
}

/// Telegram's ring: a 2 pt stroke at the swatch's edge.
private func accentRingImage(color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 40.0, height: 40.0), rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2.0)
        context.strokeEllipse(in: bounds.insetBy(dx: 1.0, dy: 1.0))
    })
}

/// Telegram's fill: 4 pt inside the ring, which a scale of 1.2 covers.
private func accentFillImage(color: UIColor, stroke: UIColor?) -> UIImage? {
    return generateImage(CGSize(width: 40.0, height: 40.0), rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: bounds.insetBy(dx: 4.0, dy: 4.0))
        if let stroke {
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(1.0)
            context.strokeEllipse(in: bounds.insetBy(dx: 4.5, dy: 4.5))
        }
    })
}

// MARK: - Animated header

/// The animation and a line of help over a screen's rows, as Telegram's ChatListFilterSettingsHeaderItem; a tap plays it
/// again.
final class SettingsAnimationHeaderItem: ListViewItem {
    let theme: TauTheme
    let animation: String
    let text: String

    init(theme: TauTheme, animation: String, text: String) {
        self.theme = theme
        self.animation = animation
        self.text = text
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return false
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = SettingsAnimationHeaderItemNode()
            let layout = node.update(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { return (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? SettingsAnimationHeaderItemNode else {
                return
            }
            let layout = nodeValue.update(item: self, params: params)
            completion(layout, { _ in })
        }
    }
}

final class SettingsAnimationHeaderItemNode: ListViewItemNode {
    private let animation = ComponentView<Empty>()
    private let textNode = ImmediateTextNode()
    private var didPlay = false

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.textNode.textAlignment = .center
        self.textNode.maximumNumberOfLines = 0
        self.addSubnode(self.textNode)
    }

    override func didLoad() {
        super.didLoad()
        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.animationTapped)))
    }

    @objc private func animationTapped() {
        (self.animation.view as? LottieComponent.View)?.playOnce()
    }

    func update(item: SettingsAnimationHeaderItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        let size = CGSize(width: 96.0, height: 96.0)
        let _ = self.animation.update(transition: .immediate, component: AnyComponent(LottieComponent(content: LottieComponent.AppBundleContent(name: item.animation), startingPosition: .begin, size: size, lottieSettings: .noAccountFallback)), environment: {}, containerSize: size)
        if let view = self.animation.view {
            if view.superview == nil {
                self.view.addSubview(view)
            }
            view.frame = CGRect(origin: CGPoint(x: floor((params.width - size.width) / 2.0), y: 0.0), size: size)
            if !self.didPlay {
                self.didPlay = true
                (view as? LottieComponent.View)?.playOnce(delay: 0.2)
            }
        }
        self.textNode.attributedText = NSAttributedString(string: item.text, font: Font.regular(14.0), textColor: item.theme.list.freeTextColor)
        let textSize = self.textNode.updateLayout(CGSize(width: params.width - params.leftInset - params.rightInset - 64.0, height: 200.0))
        self.textNode.frame = CGRect(origin: CGPoint(x: floor((params.width - textSize.width) / 2.0), y: size.height + 10.0), size: textSize)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: size.height + 10.0 + textSize.height + 4.0), insets: UIEdgeInsets(top: 8.0, left: 0.0, bottom: 0.0, right: 0.0))
    }
}
