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

/// What an account's row says under its name: the service and plan, or what it is; with "in use" when the provider has
/// others; or why it needs signing in again.
func accountSubtitle(_ account: ProviderAccount, hasSiblings: Bool, showsProblem: Bool = true) -> (text: String, isProblem: Bool) {
    if showsProblem && account.problem != nil {
        return ("Sign in again", true)
    }
    var text: String
    if account.type == "api_key" {
        text = "\(account.providerName) API key"
        if account.label != nil, let hint = account.keyHint {
            text += " ending \(hint)"
        }
    } else {
        text = account.serviceName + (account.plan.map { " \($0)" } ?? "")
    }
    if hasSiblings && account.active {
        text += ", in use"
    }
    return (text, false)
}

/// A row of the accounts: the provider's logo, a name, what it is under it, and its usage at the right in two small
/// bars when its plan has any. Keys from the server's environment are rows of the same kind, without an action.
final class AccountRowItem: SyncListItem {
    let theme: TauTheme
    let icon: UIImage?
    let title: String
    let subtitle: String
    let isProblem: Bool
    let windows: [UsageWindow]
    let position: SettingsRowPosition
    let action: (() -> Void)?

    init(theme: TauTheme, icon: UIImage?, title: String, subtitle: String, isProblem: Bool = false, windows: [UsageWindow] = [], position: SettingsRowPosition, action: (() -> Void)?) {
        self.theme = theme
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isProblem = isProblem
        self.windows = windows
        self.position = position
        self.action = action
    }

    override var selectable: Bool {
        return self.action != nil
    }

    override func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action?()
    }

    override func makeNode() -> SyncListItemNode {
        return AccountRowItemNode()
    }
}

final class AccountRowItemNode: SyncListItemNode {
    private var background: SectionBackground!
    private let iconNode = ASImageNode()
    private let titleNode = ImmediateTextNode()
    private let subtitleNode = ImmediateTextNode()
    private var windowNodes: [(label: ImmediateTextNode, bar: UsageBarNode, value: ImmediateTextNode)] = []

    override init() {
        super.init()
        self.background = SectionBackground(in: self)
        self.iconNode.displaysAsynchronously = false
        for node in [self.iconNode, self.titleNode, self.subtitleNode] as [ASDisplayNode] {
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
        let sectionLeft = params.leftInset + sectionSideInset
        let sectionWidth = params.width - params.leftInset - params.rightInset - sectionSideInset * 2.0
        let iconSize: CGFloat = 36.0
        let contentLeft = sectionLeft + 16.0 + iconSize + 12.0
        let right = sectionLeft + sectionWidth - 16.0
        let windows = Array(item.windows.prefix(2))

        // The usage: each window a line of its label, a bar and its percentage, in columns shared by the lines.
        let small = Font.regular(theme.scaled(12.0))
        let numbers = Font.with(size: theme.scaled(12.0), design: .regular, weight: .medium, traits: [.monospacedNumbers])
        let labelWidth = windows.map { ceil(NSAttributedString(string: $0.label, font: small, textColor: .black).size().width) }.max() ?? 0.0
        let valueWidth = ceil(NSAttributedString(string: "100%", font: numbers, textColor: .black).size().width)
        let barWidth: CGFloat = 44.0
        let usageWidth = windows.isEmpty ? 0.0 : labelWidth + 6.0 + barWidth + 6.0 + valueWidth
        while self.windowNodes.count < windows.count {
            let entry = (label: ImmediateTextNode(), bar: UsageBarNode(), value: ImmediateTextNode())
            self.addSubnode(entry.label)
            self.addSubnode(entry.bar)
            self.addSubnode(entry.value)
            self.windowNodes.append(entry)
        }

        let textWidth = right - contentLeft - (usageWidth > 0 ? usageWidth + 12.0 : 0.0)
        self.titleNode.attributedText = NSAttributedString(string: item.title, font: Font.regular(theme.scaled(17.0)), textColor: theme.list.itemPrimaryTextColor)
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.truncationType = .end
        let titleSize = self.titleNode.updateLayout(CGSize(width: textWidth, height: 40.0))
        self.subtitleNode.attributedText = NSAttributedString(string: item.subtitle, font: Font.regular(theme.scaled(14.0)), textColor: item.isProblem ? colorRed : theme.list.itemSecondaryTextColor)
        self.subtitleNode.maximumNumberOfLines = 1
        self.subtitleNode.truncationType = .end
        let subtitleSize = self.subtitleNode.updateLayout(CGSize(width: textWidth, height: 40.0))
        let height = max(11.0 + titleSize.height + 1.0 + subtitleSize.height + 11.0, iconSize + 20.0)
        let textTop = floor((height - titleSize.height - 1.0 - subtitleSize.height) / 2.0)
        self.titleNode.frame = CGRect(origin: CGPoint(x: contentLeft, y: textTop), size: titleSize)
        self.subtitleNode.frame = CGRect(origin: CGPoint(x: contentLeft, y: textTop + titleSize.height + 1.0), size: subtitleSize)

        let lineHeight = ceil(small.lineHeight)
        let linesTop = floor((height - lineHeight * CGFloat(windows.count) - 3.0 * CGFloat(max(0, windows.count - 1))) / 2.0)
        let usageLeft = right - usageWidth
        for (index, entry) in self.windowNodes.enumerated() {
            let hidden = index >= windows.count
            entry.label.isHidden = hidden
            entry.bar.isHidden = hidden
            entry.value.isHidden = hidden
            guard !hidden else {
                continue
            }
            let window = windows[index]
            let level = window.level()
            let y = linesTop + CGFloat(index) * (lineHeight + 3.0)
            entry.label.attributedText = NSAttributedString(string: window.label, font: small, textColor: theme.list.itemSecondaryTextColor)
            entry.value.attributedText = NSAttributedString(string: usagePercentText(window.usedPercent), font: numbers, textColor: level == .normal ? theme.list.itemSecondaryTextColor : usageColor(level, theme: theme))
            let labelSize = entry.label.updateLayout(CGSize(width: 80.0, height: 20.0))
            let valueSize = entry.value.updateLayout(CGSize(width: 60.0, height: 20.0))
            entry.label.frame = CGRect(origin: CGPoint(x: usageLeft, y: y), size: labelSize)
            entry.value.frame = CGRect(origin: CGPoint(x: right - valueSize.width, y: y), size: valueSize)
            let barX = usageLeft + labelWidth + 6.0
            entry.bar.frame = CGRect(x: barX, y: y + floor((lineHeight - 4.0) / 2.0), width: barWidth, height: 4.0)
            entry.bar.update(size: CGSize(width: barWidth, height: 4.0), fraction: window.usedPercent / 100.0, pace: window.elapsed(), color: usageColor(level, theme: theme), trackColor: theme.list.itemSecondaryTextColor.withAlphaComponent(0.18), paceColor: theme.list.itemSecondaryTextColor.withAlphaComponent(0.6), animated: animated)
        }

        self.iconNode.image = item.icon
        self.iconNode.frame = CGRect(x: sectionLeft + 16.0, y: floor((height - iconSize) / 2.0), width: iconSize, height: iconSize)
        self.background.update(theme: theme, frame: CGRect(x: sectionLeft, y: 0.0, width: sectionWidth, height: height), position: item.position, separatorLeft: contentLeft)
        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "account"
        self.accessibilityLabel = item.title
        self.accessibilityValue = ([item.subtitle] + windows.map { "\($0.label) \(usagePercentText($0.usedPercent))" }).joined(separator: ", ")
        self.accessibilityTraits = item.action == nil ? [] : .button
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
                pace = "Keep under \(Int((left / (remaining / 86_400)).rounded()))% a day to last until it resets"
            } else {
                pace = "Keep under \(Int((left / max(remaining / 3_600, 0.1)).rounded()))% an hour to last until it resets"
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
