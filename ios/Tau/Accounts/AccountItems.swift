import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

// The Accounts tab's rows, in the grouped list style of Settings (SettingsItems.swift): an account with its usage in
// small bars, a limit with a large one, a sign-in code, and a line with an activity indicator.

// Settings' metrics and colors (SettingsItems.swift).
private let sectionCornerRadius: CGFloat = 26.0
private let sectionSideInset: CGFloat = 16.0
private let separatorHeight = 1.0 / UIScreen.main.scale
private let colorRed = UIColor(rgb: 0xFF453A)
private let colorOrange = UIColor(rgb: 0xFF9F0A)

/// A bar's color: the accent while usage keeps pace with the time going, orange ahead of it, red near and at the end.
func usageColor(_ level: UsageLevel, theme: TauTheme) -> UIColor {
    switch level {
    case .normal:
        return theme.list.itemAccentColor
    case .ahead:
        return colorOrange
    case .high, .out:
        return colorRed
    }
}

/// "42%", whole numbers, but never 100% before it is all used.
func usagePercentText(_ value: Double) -> String {
    let rounded = value >= 100 ? 100 : min(99, Int(value.rounded()))
    return "\(rounded)%"
}

/// "2h 14m", "3d 5h", "12m": how long until `date`.
func durationText(until date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(now)))
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3_600
    let minutes = seconds % 3_600 / 60
    if days > 0 {
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }
    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    return "\(max(1, minutes))m"
}

/// "5-Hour Limit", "Weekly Limit", "Opus Weekly Limit".
func usageWindowTitle(_ window: UsageWindow) -> String {
    let seconds = window.seconds ?? 0
    let span: String
    if abs(seconds - 604_800) < 3_600 {
        span = "Weekly"
    } else if seconds > 0, Int(seconds) % 86_400 == 0 {
        span = "\(Int(seconds) / 86_400)-Day"
    } else if seconds > 0 {
        span = "\(Int((seconds / 3_600).rounded()))-Hour"
    } else {
        span = window.label
    }
    switch window.id {
    case "5h", "week", "primary", "secondary":
        return "\(span) Limit"
    default:
        let name = window.label.components(separatedBy: " ").first ?? window.label
        return "\(name) \(span) Limit"
    }
}

/// The track, the used part, and a tick where an even pace would be now.
final class UsageBarNode: ASDisplayNode {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let paceLayer = CALayer()

    override init() {
        super.init()
        self.isLayerBacked = true
        self.layer.addSublayer(self.trackLayer)
        self.layer.addSublayer(self.fillLayer)
        self.layer.addSublayer(self.paceLayer)
    }

    func update(size: CGSize, fraction: Double, pace: Double?, color: UIColor, trackColor: UIColor, paceColor: UIColor, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        let radius = size.height / 2.0
        self.trackLayer.frame = CGRect(origin: CGPoint(), size: size)
        self.trackLayer.cornerRadius = radius
        self.trackLayer.backgroundColor = trackColor.cgColor
        let width = size.width * CGFloat(min(1.0, max(0.0, fraction)))
        self.fillLayer.frame = CGRect(x: 0.0, y: 0.0, width: fraction > 0 ? max(size.height, width) : 0.0, height: size.height)
        self.fillLayer.cornerRadius = radius
        self.fillLayer.backgroundColor = color.cgColor
        if let pace, pace > 0.0, pace < 1.0 {
            let tickWidth: CGFloat = max(1.5, UIScreenPixel * 3.0)
            let tickHeight = size.height + 6.0
            self.paceLayer.isHidden = false
            self.paceLayer.frame = CGRect(x: floor(size.width * CGFloat(pace) - tickWidth / 2.0), y: -3.0, width: tickWidth, height: tickHeight)
            self.paceLayer.cornerRadius = tickWidth / 2.0
            self.paceLayer.backgroundColor = paceColor.cgColor
        } else {
            self.paceLayer.isHidden = true
        }
        CATransaction.commit()
    }
}

/// The section background of a row: its outer corners rounded where it begins or ends a section, and a highlight.
private final class SectionBackground {
    let backgroundNode = ASDisplayNode()
    let highlightNode = ASDisplayNode()
    let separatorNode = ASDisplayNode()

    init(in node: ASDisplayNode) {
        for each in [self.backgroundNode, self.highlightNode, self.separatorNode] {
            each.isLayerBacked = true
        }
        self.highlightNode.alpha = 0.0
        node.addSubnode(self.backgroundNode)
        node.addSubnode(self.highlightNode)
        node.addSubnode(self.separatorNode)
    }

    func update(theme: TauTheme, frame: CGRect, position: SettingsRowPosition, separatorLeft: CGFloat) {
        self.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.highlightNode.backgroundColor = theme.list.itemHighlightedBackgroundColor
        self.backgroundNode.frame = frame
        self.highlightNode.frame = frame
        var corners: CACornerMask = []
        if position.isFirst {
            corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner])
        }
        if position.isLast {
            corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        }
        for node in [self.backgroundNode, self.highlightNode] {
            node.layer.cornerRadius = corners.isEmpty ? 0.0 : sectionCornerRadius
            node.layer.maskedCorners = corners
            node.layer.cornerCurve = .continuous
        }
        self.separatorNode.backgroundColor = theme.list.itemBlocksSeparatorColor
        self.separatorNode.isHidden = position.isLast
        self.separatorNode.frame = CGRect(x: separatorLeft, y: frame.maxY - separatorHeight, width: frame.maxX - separatorLeft, height: separatorHeight)
    }

    func setHighlighted(_ highlighted: Bool, animated: Bool) {
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
}

/// A row laid out on the main queue, for the rows below: few, and simple.
class SyncListItem: ListViewItem {
    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return false
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
    }

    func makeNode() -> SyncListItemNode {
        fatalError("makeNode")
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = self.makeNode()
            let layout = node.update(item: self, params: params, animated: false)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { return (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? SyncListItemNode else {
                return
            }
            let layout = nodeValue.update(item: self, params: params, animated: true)
            completion(layout, { _ in })
        }
    }
}

class SyncListItemNode: ListViewItemNode {
    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
    }

    func update(item: SyncListItem, params: ListViewItemLayoutParams, animated: Bool) -> ListViewItemNodeLayout {
        fatalError("update")
    }
}

private func textSize(_ text: NSAttributedString, width: CGFloat) -> CGSize {
    let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    return CGSize(width: ceil(rect.width), height: ceil(rect.height))
}

// MARK: - An account

/// A letter avatar: the initial of the account's name or email, or of its provider for a key; its color stays with
/// the account.
func accountAvatar(_ account: ProviderAccount, diameter: CGFloat) -> UIImage? {
    let name = account.label ?? account.email ?? account.providerName
    let color = account.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
    return Avatar.image(letters: Avatar.letters(name), colorIndex: color, diameter: diameter)
}

/// An account: who it is, its plan, its usage in small bars or why it has none; a check on the one in use.
final class AccountRowItem: SyncListItem {
    let theme: TauTheme
    let account: ProviderAccount
    let position: SettingsRowPosition
    let action: () -> Void

    init(theme: TauTheme, account: ProviderAccount, position: SettingsRowPosition, action: @escaping () -> Void) {
        self.theme = theme
        self.account = account
        self.position = position
        self.action = action
    }

    override var selectable: Bool {
        return true
    }

    override func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action()
    }

    override func makeNode() -> SyncListItemNode {
        return AccountRowItemNode()
    }
}

final class AccountRowItemNode: SyncListItemNode {
    private var background: SectionBackground!
    private let avatarNode = ASImageNode()
    private let titleNode = ImmediateTextNode()
    private let planNode = ImmediateTextNode()
    private let detailNode = ImmediateTextNode()
    private let checkNode = ASImageNode()
    private var windowNodes: [(label: ImmediateTextNode, bar: UsageBarNode, value: ImmediateTextNode)] = []

    override init() {
        super.init()
        self.background = SectionBackground(in: self)
        self.avatarNode.displaysAsynchronously = false
        self.checkNode.displaysAsynchronously = false
        for node in [self.avatarNode, self.titleNode, self.planNode, self.detailNode, self.checkNode] as [ASDisplayNode] {
            self.addSubnode(node)
        }
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        self.background.setHighlighted(highlighted, animated: animated)
    }

    override func update(item: SyncListItem, params: ListViewItemLayoutParams, animated: Bool) -> ListViewItemNodeLayout {
        guard let item = item as? AccountRowItem else {
            return ListViewItemNodeLayout(contentSize: CGSize(), insets: UIEdgeInsets())
        }
        let theme = item.theme
        let account = item.account
        let sectionLeft = params.leftInset + sectionSideInset
        let sectionWidth = params.width - params.leftInset - params.rightInset - sectionSideInset * 2.0
        let avatarSize: CGFloat = 40.0
        let contentLeft = sectionLeft + 16.0 + avatarSize + 12.0
        let right = sectionLeft + sectionWidth - 16.0
        // The same for every row, so that the bars of the rows line up.
        let checkWidth: CGFloat = 30.0

        self.avatarNode.image = accountAvatar(account, diameter: avatarSize)

        self.planNode.attributedText = account.plan.map { NSAttributedString(string: $0, font: Font.medium(theme.scaled(13.0)), textColor: theme.list.itemSecondaryTextColor) }
        let planSize = self.planNode.updateLayout(CGSize(width: 100.0, height: 30.0))
        self.titleNode.attributedText = NSAttributedString(string: account.title, font: Font.regular(theme.scaled(17.0)), textColor: theme.list.itemPrimaryTextColor)
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.truncationType = .end
        let titleSize = self.titleNode.updateLayout(CGSize(width: right - checkWidth - contentLeft - (planSize.width > 0 ? planSize.width + 8.0 : 0.0), height: 40.0))

        let windows = Array((account.usage?.windows ?? []).prefix(2))
        var detail: String?
        var detailColor = theme.list.itemSecondaryTextColor
        if let problem = account.problem {
            detail = "Sign in again: \(problem)"
            detailColor = colorRed
        } else if windows.isEmpty {
            if let hint = account.keyHint {
                detail = account.label != nil ? "Key ending \(hint)" : "API key"
            } else if account.type == "api_key" {
                detail = "API key"
            } else if let error = account.usage?.error {
                detail = "Usage unavailable: \(error)"
            } else if account.label != nil, let email = account.email {
                detail = email
            } else {
                detail = account.usage == nil && account.provider != "anthropic" && account.provider != "openai-codex" ? "No usage from this provider" : "Usage loading"
            }
        }
        let verticalInset: CGFloat = 11.0
        var y = verticalInset
        let titleY = y
        y += titleSize.height + 4.0
        var height: CGFloat
        if let detail {
            self.detailNode.isHidden = false
            self.detailNode.attributedText = NSAttributedString(string: detail, font: Font.regular(theme.scaled(14.0)), textColor: detailColor)
            self.detailNode.maximumNumberOfLines = 1
            self.detailNode.truncationType = .end
            let size = self.detailNode.updateLayout(CGSize(width: right - checkWidth - contentLeft, height: 40.0))
            self.detailNode.frame = CGRect(origin: CGPoint(x: contentLeft, y: y), size: size)
            y += size.height
        } else {
            self.detailNode.isHidden = true
        }
        // Each window: its label, a bar, its percentage, side by side in two columns.
        while self.windowNodes.count < windows.count {
            let entry = (label: ImmediateTextNode(), bar: UsageBarNode(), value: ImmediateTextNode())
            self.addSubnode(entry.label)
            self.addSubnode(entry.bar)
            self.addSubnode(entry.value)
            self.windowNodes.append(entry)
        }
        let showsWindows = detail == nil
        let columnWidth = floor((right - checkWidth - contentLeft - 14.0) / 2.0)
        // The labels' column as wide as the widest, so that the bars start and end alike.
        let labelFont = Font.regular(theme.scaled(13.0))
        let labelWidth = windows.map { ceil(NSAttributedString(string: $0.label, font: labelFont, textColor: .black).size().width) }.max() ?? 0.0
        for (index, entry) in self.windowNodes.enumerated() {
            let hidden = !showsWindows || index >= windows.count
            entry.label.isHidden = hidden
            entry.bar.isHidden = hidden
            entry.value.isHidden = hidden
            guard !hidden else {
                continue
            }
            let window = windows[index]
            let level = window.level()
            let font = Font.regular(theme.scaled(13.0))
            entry.label.attributedText = NSAttributedString(string: window.label, font: font, textColor: theme.list.itemSecondaryTextColor)
            entry.value.attributedText = NSAttributedString(string: usagePercentText(window.usedPercent), font: Font.with(size: theme.scaled(13.0), design: .regular, weight: .medium, traits: [.monospacedNumbers]), textColor: level == .normal ? theme.list.itemSecondaryTextColor : usageColor(level, theme: theme))
            let labelSize = entry.label.updateLayout(CGSize(width: 80.0, height: 20.0))
            let valueSize = entry.value.updateLayout(CGSize(width: 60.0, height: 20.0))
            let x = contentLeft + CGFloat(index) * (columnWidth + 14.0)
            let lineHeight = max(labelSize.height, valueSize.height)
            entry.label.frame = CGRect(origin: CGPoint(x: x, y: y), size: labelSize)
            let valueWidth = max(valueSize.width, 34.0)
            entry.value.frame = CGRect(origin: CGPoint(x: x + columnWidth - valueSize.width, y: y), size: valueSize)
            let barX = x + labelWidth + 6.0
            let barWidth = max(16.0, columnWidth - labelWidth - 6.0 - valueWidth - 6.0)
            entry.bar.frame = CGRect(x: barX, y: y + floor((lineHeight - 4.0) / 2.0), width: barWidth, height: 4.0)
            entry.bar.update(size: CGSize(width: barWidth, height: 4.0), fraction: window.usedPercent / 100.0, pace: window.elapsed(), color: usageColor(level, theme: theme), trackColor: theme.list.itemSecondaryTextColor.withAlphaComponent(0.18), paceColor: theme.list.itemSecondaryTextColor.withAlphaComponent(0.6), animated: animated)
        }
        if showsWindows && !windows.isEmpty {
            y += 18.0
        }
        height = max(y + verticalInset, avatarSize + 20.0)
        let sectionFrame = CGRect(x: sectionLeft, y: 0.0, width: sectionWidth, height: height)
        self.background.update(theme: theme, frame: sectionFrame, position: item.position, separatorLeft: contentLeft)
        self.avatarNode.frame = CGRect(x: sectionLeft + 16.0, y: floor((height - avatarSize) / 2.0), width: avatarSize, height: avatarSize)
        self.titleNode.frame = CGRect(origin: CGPoint(x: contentLeft, y: titleY), size: titleSize)
        self.planNode.frame = CGRect(origin: CGPoint(x: contentLeft + titleSize.width + 8.0, y: titleY + floor((titleSize.height - planSize.height) / 2.0) + 1.0), size: planSize)
        if account.active {
            self.checkNode.image = generateTintedImage(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16.0, weight: .semibold)), color: theme.list.itemAccentColor)
            if let image = self.checkNode.image {
                self.checkNode.frame = CGRect(x: right - image.size.width, y: floor((height - image.size.height) / 2.0), width: image.size.width, height: image.size.height)
            }
            self.checkNode.isHidden = false
        } else {
            self.checkNode.isHidden = true
        }
        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "account"
        self.accessibilityLabel = account.title
        self.accessibilityValue = ([account.active ? "In use" : nil, account.plan, detail] + windows.map { "\($0.label) \(usagePercentText($0.usedPercent))" }).compactMap { $0 }.joined(separator: ", ")
        self.accessibilityTraits = .button
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }
}

// MARK: - A limit

/// A limit of the account's plan: its name and how much is used, a bar with the pace tick, then when it resets and,
/// ahead of pace, how much a day or an hour lasts until then.
final class UsageWindowItem: SyncListItem {
    let theme: TauTheme
    let window: UsageWindow
    let position: SettingsRowPosition

    init(theme: TauTheme, window: UsageWindow, position: SettingsRowPosition) {
        self.theme = theme
        self.window = window
        self.position = position
    }

    override func makeNode() -> SyncListItemNode {
        return UsageWindowItemNode()
    }
}

final class UsageWindowItemNode: SyncListItemNode {
    private var background: SectionBackground!
    private let titleNode = ImmediateTextNode()
    private let valueNode = ImmediateTextNode()
    private let barNode = UsageBarNode()
    private let resetNode = ImmediateTextNode()
    private let paceNode = ImmediateTextNode()

    override init() {
        super.init()
        self.background = SectionBackground(in: self)
        for node in [self.titleNode, self.valueNode, self.barNode, self.resetNode, self.paceNode] as [ASDisplayNode] {
            self.addSubnode(node)
        }
    }

    override func update(item: SyncListItem, params: ListViewItemLayoutParams, animated: Bool) -> ListViewItemNodeLayout {
        guard let item = item as? UsageWindowItem else {
            return ListViewItemNodeLayout(contentSize: CGSize(), insets: UIEdgeInsets())
        }
        let theme = item.theme
        let window = item.window
        let level = window.level()
        let now = Date()
        let sectionLeft = params.leftInset + sectionSideInset
        let sectionWidth = params.width - params.leftInset - params.rightInset - sectionSideInset * 2.0
        let left = sectionLeft + 20.0
        let right = sectionLeft + sectionWidth - 20.0
        let width = right - left

        self.titleNode.attributedText = NSAttributedString(string: usageWindowTitle(window), font: Font.regular(theme.scaled(17.0)), textColor: theme.list.itemPrimaryTextColor)
        self.valueNode.attributedText = NSAttributedString(string: usagePercentText(window.usedPercent), font: Font.with(size: theme.scaled(17.0), design: .regular, weight: .semibold, traits: [.monospacedNumbers]), textColor: level == .normal ? theme.list.itemPrimaryTextColor : usageColor(level, theme: theme))
        let valueSize = self.valueNode.updateLayout(CGSize(width: 100.0, height: 30.0))
        let titleSize = self.titleNode.updateLayout(CGSize(width: width - valueSize.width - 10.0, height: 30.0))

        var y: CGFloat = 13.0
        self.titleNode.frame = CGRect(origin: CGPoint(x: left, y: y), size: titleSize)
        self.valueNode.frame = CGRect(origin: CGPoint(x: right - valueSize.width, y: y), size: valueSize)
        y += max(titleSize.height, valueSize.height) + 10.0
        self.barNode.frame = CGRect(x: left, y: y, width: width, height: 8.0)
        self.barNode.update(size: CGSize(width: width, height: 8.0), fraction: window.usedPercent / 100.0, pace: window.elapsed(now: now), color: usageColor(level, theme: theme), trackColor: theme.list.itemSecondaryTextColor.withAlphaComponent(0.18), paceColor: theme.list.itemSecondaryTextColor.withAlphaComponent(0.7), animated: animated)
        y += 8.0 + 9.0

        let small = Font.regular(theme.scaled(14.0))
        let reset: String
        if let resetsAt = window.resetsAt {
            reset = resetsAt <= now ? "Resets now" : "Resets in \(durationText(until: resetsAt, now: now))"
        } else {
            reset = window.usedPercent > 0 ? "Resets when the window ends" : "Not started"
        }
        self.resetNode.attributedText = NSAttributedString(string: reset, font: small, textColor: theme.list.itemSecondaryTextColor)
        let resetSize = self.resetNode.updateLayout(CGSize(width: width, height: 30.0))
        self.resetNode.frame = CGRect(origin: CGPoint(x: left, y: y), size: resetSize)
        y += resetSize.height

        // Ahead of pace or near the end: what lasts until it resets, as the usage monitor says it.
        var pace: String?
        if level != .normal, level != .out, let resetsAt = window.resetsAt, resetsAt > now {
            let left = max(0.0, 100.0 - window.usedPercent)
            let remaining = resetsAt.timeIntervalSince(now)
            if (window.seconds ?? 0) > 86_400 && remaining > 86_400 {
                pace = "About \(Int((left / (remaining / 86_400)).rounded()))% a day lasts until then"
            } else {
                pace = "About \(Int((left / max(remaining / 3_600, 0.1)).rounded()))% an hour lasts until then"
            }
        } else if level == .out {
            pace = "Used up"
        }
        if let pace {
            self.paceNode.isHidden = false
            self.paceNode.attributedText = NSAttributedString(string: pace, font: small, textColor: usageColor(level, theme: theme))
            let size = self.paceNode.updateLayout(CGSize(width: width, height: 40.0))
            self.paceNode.frame = CGRect(origin: CGPoint(x: left, y: y + 2.0), size: size)
            y += size.height + 2.0
        } else {
            self.paceNode.isHidden = true
        }
        let height = y + 13.0
        self.background.update(theme: theme, frame: CGRect(x: sectionLeft, y: 0.0, width: sectionWidth, height: height), position: item.position, separatorLeft: left)
        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "usageWindow"
        self.accessibilityLabel = usageWindowTitle(window)
        self.accessibilityValue = [usagePercentText(window.usedPercent), reset, pace].compactMap { $0 }.joined(separator: ", ")
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }
}

// MARK: - A sign-in code

/// The code to enter on the provider's page, large, letters spaced, tappable to copy.
final class LoginCodeItem: SyncListItem {
    let theme: TauTheme
    let code: String
    let action: () -> Void

    init(theme: TauTheme, code: String, action: @escaping () -> Void) {
        self.theme = theme
        self.code = code
        self.action = action
    }

    override var selectable: Bool {
        return true
    }

    override func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action()
    }

    override func makeNode() -> SyncListItemNode {
        return LoginCodeItemNode()
    }
}

final class LoginCodeItemNode: SyncListItemNode {
    private var background: SectionBackground!
    private let codeNode = ImmediateTextNode()
    private let hintNode = ImmediateTextNode()

    override init() {
        super.init()
        self.background = SectionBackground(in: self)
        self.addSubnode(self.codeNode)
        self.addSubnode(self.hintNode)
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        self.background.setHighlighted(highlighted, animated: animated)
    }

    override func update(item: SyncListItem, params: ListViewItemLayoutParams, animated: Bool) -> ListViewItemNodeLayout {
        guard let item = item as? LoginCodeItem else {
            return ListViewItemNodeLayout(contentSize: CGSize(), insets: UIEdgeInsets())
        }
        let theme = item.theme
        let sectionLeft = params.leftInset + sectionSideInset
        let sectionWidth = params.width - params.leftInset - params.rightInset - sectionSideInset * 2.0
        let code = NSMutableAttributedString(string: item.code, attributes: [.font: UIFont.monospacedSystemFont(ofSize: theme.scaled(34.0), weight: .semibold), .foregroundColor: theme.list.itemPrimaryTextColor, .kern: 3.0])
        self.codeNode.attributedText = code
        let codeSize = self.codeNode.updateLayout(CGSize(width: sectionWidth - 20.0, height: 60.0))
        self.hintNode.attributedText = NSAttributedString(string: "Tap to copy", font: Font.regular(theme.scaled(13.0)), textColor: theme.list.itemSecondaryTextColor)
        let hintSize = self.hintNode.updateLayout(CGSize(width: sectionWidth, height: 30.0))
        let height = 22.0 + codeSize.height + 6.0 + hintSize.height + 18.0
        self.codeNode.frame = CGRect(origin: CGPoint(x: sectionLeft + floor((sectionWidth - codeSize.width) / 2.0), y: 22.0), size: codeSize)
        self.hintNode.frame = CGRect(origin: CGPoint(x: sectionLeft + floor((sectionWidth - hintSize.width) / 2.0), y: self.codeNode.frame.maxY + 6.0), size: hintSize)
        self.background.update(theme: theme, frame: CGRect(x: sectionLeft, y: 0.0, width: sectionWidth, height: height), position: SettingsRowPosition(isFirst: true, isLast: true), separatorLeft: sectionLeft)
        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "loginCode"
        self.accessibilityLabel = item.code
        self.accessibilityTraits = .button
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }
}

// MARK: - Waiting

/// A line with Telegram's activity indicator before it: what the login waits for.
final class ActivityRowItem: SyncListItem {
    let theme: TauTheme
    let text: String
    let position: SettingsRowPosition

    init(theme: TauTheme, text: String, position: SettingsRowPosition) {
        self.theme = theme
        self.text = text
        self.position = position
    }

    override func makeNode() -> SyncListItemNode {
        return ActivityRowItemNode()
    }
}

final class ActivityRowItemNode: SyncListItemNode {
    private var background: SectionBackground!
    private let textNode = ImmediateTextNode()
    private var indicator: UIActivityIndicatorView?

    override init() {
        super.init()
        self.background = SectionBackground(in: self)
        self.addSubnode(self.textNode)
    }

    override func update(item: SyncListItem, params: ListViewItemLayoutParams, animated: Bool) -> ListViewItemNodeLayout {
        guard let item = item as? ActivityRowItem else {
            return ListViewItemNodeLayout(contentSize: CGSize(), insets: UIEdgeInsets())
        }
        let theme = item.theme
        let sectionLeft = params.leftInset + sectionSideInset
        let sectionWidth = params.width - params.leftInset - params.rightInset - sectionSideInset * 2.0
        let left = sectionLeft + 52.0
        self.textNode.attributedText = NSAttributedString(string: item.text, font: Font.regular(theme.scaled(17.0)), textColor: theme.list.itemSecondaryTextColor)
        self.textNode.maximumNumberOfLines = 3
        let size = self.textNode.updateLayout(CGSize(width: sectionLeft + sectionWidth - 20.0 - left, height: 100.0))
        let height = max(52.0, size.height + 30.0)
        self.textNode.frame = CGRect(origin: CGPoint(x: left, y: floor((height - size.height) / 2.0)), size: size)
        let indicator: UIActivityIndicatorView
        if let current = self.indicator {
            indicator = current
        } else {
            indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            self.view.addSubview(indicator)
            self.indicator = indicator
        }
        indicator.color = theme.list.itemSecondaryTextColor
        indicator.center = CGPoint(x: sectionLeft + 26.0, y: height / 2.0)
        self.background.update(theme: theme, frame: CGRect(x: sectionLeft, y: 0.0, width: sectionWidth, height: height), position: item.position, separatorLeft: left)
        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "loginWaiting"
        self.accessibilityLabel = item.text
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }
}
