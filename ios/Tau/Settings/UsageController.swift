import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import SegmentedControlNode

/// Telegram's statistics charts' series colors, for the models.
private let seriesColors: [UIColor] = [0x3497ED, 0xF5BD25, 0x5FB641, 0xE65850, 0x9C6BEE, 0x36C7D0, 0xF79E39, 0x8E8E93].map { UIColor(rgb: $0) }

/// What the server's ledger calls the prompt cache refreshes (server/src/search/usage.ts).
let cacheWarmingModel = "tau/cache-warming"

/// The part of `provider/modelId` people read: the model's name.
func shortModelName(_ model: String) -> String {
    if model == cacheWarmingModel {
        return "Cache Warming"
    }
    return model.split(separator: "/", maxSplits: 1).last.map(String.init) ?? model
}

/// Settings > Usage: what the agents cost, after Telegram's statistics screens (ChannelStatsController): the span on a
/// segmented control, an overview of the totals with their change, the days as a stacked bar chart by model, then the
/// models and the costliest chats. From every server's ledger (server/src/search/usage.ts), merged.
final class UsageController: SettingsListController {
    enum Metric {
        case cost
        case tokens
    }

    private static let spans = [7, 30, 90]
    private var spanIndex = 1
    private var metric: Metric?
    private var selectedDay: Int?
    private var report: UsageReport?
    private var failed = false
    private let reportDisposable = MetaDisposable()

    init(context: AppContext) {
        super.init(context: context, title: "Usage")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.reportDisposable.dispose()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.load()
    }

    private func load() {
        let days = UsageController.spans[self.spanIndex]
        let signals = self.context.store.servers.map { $0.usageReport(days: days) }
        guard !signals.isEmpty else {
            return
        }
        self.reportDisposable.set((combineLatest(signals) |> deliverOnMainQueue).start(next: { [weak self] reports in
            guard let self else {
                return
            }
            let found = reports.compactMap { $0 }
            self.failed = found.isEmpty
            self.report = found.isEmpty ? nil : UsageReport.merged(found)
            self.selectedDay = nil
            self.reload()
        }))
    }

    /// Cost, unless nothing cost anything (free models): then tokens.
    private var effectiveMetric: Metric {
        if let metric = self.metric {
            return metric
        }
        return (self.report?.total.cost ?? 0.0) > 0.0 ? .cost : .tokens
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        var items: [ListViewItem] = [
            UsageSpanItem(theme: theme, titles: ["7 Days", "30 Days", "90 Days"], selectedIndex: self.spanIndex, changed: { [weak self] index in
                guard let self, self.spanIndex != index else {
                    return
                }
                self.spanIndex = index
                self.load()
            }),
        ]
        guard let report = self.report else {
            items.append(SettingsTextItem(theme: theme, text: self.failed ? "The servers did not answer. Usage needs a server that keeps it (tau server from October 2026 on)." : "Loading…", kind: .footer))
            return items
        }
        let models = report.models.map(\.model)
        let colors = Dictionary(models.enumerated().map { ($0.element, seriesColors[$0.offset % seriesColors.count]) }, uniquingKeysWith: { first, _ in first })

        items.append(SettingsTextItem(theme: theme, text: "Overview", kind: .header))
        items.append(UsageOverviewItem(theme: theme, report: report))

        items.append(SettingsTextItem(theme: theme, text: "By Day", kind: .header))
        items.append(UsageChartItem(theme: theme, report: report, models: models, colors: colors, metric: self.effectiveMetric, selectedDay: self.selectedDay, selectDay: { [weak self] day in
            self?.selectedDay = day
            self?.reload()
        }, toggleMetric: { [weak self] in
            guard let self else {
                return
            }
            self.metric = self.effectiveMetric == .cost ? .tokens : .cost
            self.reload()
        }))

        if !report.models.isEmpty {
            items.append(SettingsTextItem(theme: theme, text: "By Model", kind: .header))
            let total = max(report.total.cost, 0.000_001)
            let totalTokens = max(Double(report.total.tokens), 1.0)
            for (index, entry) in report.models.enumerated() {
                let share = self.effectiveMetric == .cost ? entry.totals.cost / total : Double(entry.totals.tokens) / totalTokens
                let value = self.effectiveMetric == .cost ? formatCost(entry.totals.cost) : formatTokens(entry.totals.tokens)
                items.append(SettingsRowItem(theme: theme, icon: seriesIcon(colors[entry.model] ?? seriesColors[0]), title: shortModelName(entry.model), subtitle: "\(formatTokens(entry.totals.tokens)) tokens · \(entry.model == cacheWarmingModel ? refreshesText(entry.totals.replies) : answersText(entry.totals.replies))", accessory: .value("\(value) · \(percentText(share))"), position: SettingsRowPosition(isFirst: index == 0, isLast: index == report.models.count - 1), action: nil))
            }
            items.append(SettingsTextItem(theme: theme, text: "Input \(formatTokens(report.total.input)), output \(formatTokens(report.total.output)), cache read \(formatTokens(report.total.cacheRead)), cache write \(formatTokens(report.total.cacheWrite)).", kind: .footer))
        }

        let chats = report.conversations.compactMap { entry in self.context.store.dialog(entry.conversationId).map { ($0, entry.totals) } }.prefix(10)
        if !chats.isEmpty {
            items.append(SettingsTextItem(theme: theme, text: "Top Chats", kind: .header))
            for (index, (dialog, totals)) in chats.enumerated() {
                let value = self.effectiveMetric == .cost ? formatCost(totals.cost) : formatTokens(totals.tokens)
                items.append(SettingsRowItem(theme: theme, icon: Avatar.image(letters: Avatar.letters(dialog.title), colorIndex: dialog.id, diameter: 30.0), title: dialog.title, subtitle: "\(dialog.projectLabel) · \(answersText(totals.replies))", accessory: .disclosure(label: value), position: SettingsRowPosition(isFirst: index == 0, isLast: index == chats.count - 1), action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.push(ChatController(context: self.context, conversationId: dialog.id))
                }))
            }
        }
        items.append(SettingsTextItem(theme: theme, text: "Costs are pi's, from each provider's prices, for every answer the agents wrote, subagents' included, and for the refreshes that kept prompt caches warm while they worked. Summaries made to compact a context are not counted.", kind: .footer))
        return items
    }
}

private func answersText(_ count: Int) -> String {
    return count == 1 ? "1 answer" : "\(count) answers"
}

private func refreshesText(_ count: Int) -> String {
    return count == 1 ? "1 refresh" : "\(count) refreshes"
}

private func percentText(_ share: Double) -> String {
    let percent = share * 100.0
    if percent > 0.0 && percent < 1.0 {
        return "<1%"
    }
    return "\(Int(percent.rounded()))%"
}

private var seriesIcons: [UInt32: UIImage] = [:]

/// A series' color as a settings icon: a rounded square with a dot, as Telegram's storage categories show theirs.
private func seriesIcon(_ color: UIColor) -> UIImage? {
    if let icon = seriesIcons[color.argb] {
        return icon
    }
    let icon = generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: 7.0).cgPath)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 10.0, y: 10.0, width: 10.0, height: 10.0))
    })
    seriesIcons[color.argb] = icon
    return icon
}

private let sectionInset: CGFloat = 16.0
private let sectionCornerRadius: CGFloat = 26.0

// MARK: - Span

/// Telegram's segmented control (SegmentedControlNode) on the list background, as the statistics screens' period.
final class UsageSpanItem: ListViewItem {
    let theme: TauTheme
    let titles: [String]
    let selectedIndex: Int
    let changed: (Int) -> Void

    init(theme: TauTheme, titles: [String], selectedIndex: Int, changed: @escaping (Int) -> Void) {
        self.theme = theme
        self.titles = titles
        self.selectedIndex = selectedIndex
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
            let node = UsageSpanItemNode(item: self)
            let layout = node.update(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { return (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? UsageSpanItemNode else {
                return
            }
            let layout = node.update(item: self, params: params)
            completion(layout, { _ in })
        }
    }
}

private final class UsageSpanItemNode: ListViewItemNode {
    private let control: SegmentedControlNode
    private var item: UsageSpanItem

    init(item: UsageSpanItem) {
        self.item = item
        self.control = SegmentedControlNode(theme: SegmentedControlTheme(theme: item.theme.presentationTheme), items: item.titles.map { SegmentedControlItem(title: $0) }, selectedIndex: item.selectedIndex)
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.addSubnode(self.control)
        self.control.selectedIndexChanged = { [weak self] index in
            self?.item.changed(index)
        }
    }

    func update(item: UsageSpanItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        self.item = item
        if self.control.selectedIndex != item.selectedIndex {
            self.control.selectedIndex = item.selectedIndex
        }
        let width = params.width - params.leftInset - params.rightInset - sectionInset * 2.0
        let size = self.control.updateLayout(.stretchToFill(width: width), transition: .immediate)
        self.control.frame = CGRect(origin: CGPoint(x: params.leftInset + sectionInset, y: 16.0), size: size)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: size.height + 20.0), insets: UIEdgeInsets())
    }
}

// MARK: - Overview

/// Telegram's StatsOverviewItem: the totals in two columns, each with its change against the span before.
final class UsageOverviewItem: ListViewItem {
    let theme: TauTheme
    let report: UsageReport

    init(theme: TauTheme, report: UsageReport) {
        self.theme = theme
        self.report = report
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return false
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = UsageOverviewItemNode()
            let layout = node.update(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { return (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? UsageOverviewItemNode else {
                return
            }
            let layout = node.update(item: self, params: params)
            completion(layout, { _ in })
        }
    }
}

private final class UsageOverviewItemNode: ListViewItemNode {
    private let backgroundNode = ASDisplayNode()
    private var valueNodes: [ImmediateTextNode] = []
    private var titleNodes: [ImmediateTextNode] = []

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.backgroundNode.isLayerBacked = true
        self.backgroundNode.cornerRadius = sectionCornerRadius
        self.backgroundNode.layer.cornerCurve = .continuous
        self.addSubnode(self.backgroundNode)
        for _ in 0 ..< 4 {
            let value = ImmediateTextNode()
            let title = ImmediateTextNode()
            self.valueNodes.append(value)
            self.titleNodes.append(title)
            self.addSubnode(value)
            self.addSubnode(title)
        }
    }

    func update(item: UsageOverviewItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        let theme = item.theme.list
        let report = item.report
        let width = params.width - params.leftInset - params.rightInset - sectionInset * 2.0
        let positive = UIColor(rgb: 0x34C759)
        let negative = UIColor(rgb: 0xFF3B30)
        // As StatsOverviewItem: a rise in spend is the red one.
        func change(_ now: Double, _ before: Double, rising: UIColor, falling: UIColor) -> NSAttributedString? {
            guard before > 0.0 else {
                return nil
            }
            let delta = (now - before) / before * 100.0
            let text = delta >= 0.0 ? " +\(Int(delta.rounded()))%" : " −\(Int((-delta).rounded()))%"
            return NSAttributedString(string: text, font: Font.regular(13.0), textColor: delta >= 0.0 ? rising : falling)
        }
        let cells: [(String, String, NSAttributedString?)] = [
            (formatCost(report.total.cost), "Spent", change(report.total.cost, report.previous.cost, rising: negative, falling: positive)),
            (formatTokens(report.total.tokens), "Tokens", change(Double(report.total.tokens), Double(report.previous.tokens), rising: negative, falling: positive)),
            ("\(report.total.replies)", "Answers", change(Double(report.total.replies), Double(report.previous.replies), rising: positive, falling: negative)),
            ("\(report.conversationCount)", "Chats", nil),
        ]
        let columnWidth = (width - 32.0) / 2.0
        let rowHeight: CGFloat = 50.0
        for (index, cell) in cells.enumerated() {
            let value = NSMutableAttributedString(string: cell.0, font: Font.semibold(17.0), textColor: theme.itemPrimaryTextColor)
            if let delta = cell.2 {
                value.append(delta)
            }
            self.valueNodes[index].attributedText = value
            self.titleNodes[index].attributedText = NSAttributedString(string: cell.1, font: Font.regular(13.0), textColor: theme.itemSecondaryTextColor)
            let x = params.leftInset + sectionInset + 16.0 + CGFloat(index % 2) * columnWidth
            let y = 12.0 + CGFloat(index / 2) * rowHeight
            let valueSize = self.valueNodes[index].updateLayout(CGSize(width: columnWidth - 8.0, height: 30.0))
            let titleSize = self.titleNodes[index].updateLayout(CGSize(width: columnWidth - 8.0, height: 20.0))
            self.valueNodes[index].frame = CGRect(origin: CGPoint(x: x, y: y), size: valueSize)
            self.titleNodes[index].frame = CGRect(origin: CGPoint(x: x, y: y + valueSize.height + 1.0), size: titleSize)
        }
        let height = 12.0 + rowHeight * 2.0 + 4.0
        self.backgroundNode.backgroundColor = theme.itemBlocksBackgroundColor
        self.backgroundNode.frame = CGRect(x: params.leftInset + sectionInset, y: 0.0, width: width, height: height)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }
}

// MARK: - Chart

/// The days as Telegram's stacked bar chart: a bar a day, a segment a model, three grid lines with their values, dates
/// under it. A touch selects a day, the others dim, and its total and models show above; the metric (cost or tokens)
/// switches from the header.
final class UsageChartItem: ListViewItem {
    let theme: TauTheme
    let report: UsageReport
    let models: [String]
    let colors: [String: UIColor]
    let metric: UsageController.Metric
    let selectedDay: Int?
    let selectDay: (Int?) -> Void
    let toggleMetric: () -> Void

    init(theme: TauTheme, report: UsageReport, models: [String], colors: [String: UIColor], metric: UsageController.Metric, selectedDay: Int?, selectDay: @escaping (Int?) -> Void, toggleMetric: @escaping () -> Void) {
        self.theme = theme
        self.report = report
        self.models = models
        self.colors = colors
        self.metric = metric
        self.selectedDay = selectedDay
        self.selectDay = selectDay
        self.toggleMetric = toggleMetric
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return false
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = UsageChartItemNode()
            let layout = node.update(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { return (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? UsageChartItemNode else {
                return
            }
            let layout = node.update(item: self, params: params)
            completion(layout, { _ in })
        }
    }
}

private final class UsageChartItemNode: ListViewItemNode {
    private let backgroundNode = ASDisplayNode()
    private let titleNode = ImmediateTextNode()
    private let metricNode = ImmediateTextNode()
    private let chartLayer = CALayer()
    private var labelNodes: [ImmediateTextNode] = []
    private var legendNodes: [ImmediateTextNode] = []
    private var item: UsageChartItem?
    private var plot = CGRect()

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.backgroundNode.isLayerBacked = true
        self.backgroundNode.cornerRadius = sectionCornerRadius
        self.backgroundNode.layer.cornerCurve = .continuous
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.metricNode)
        self.layer.addSublayer(self.chartLayer)
    }

    override func didLoad() {
        super.didLoad()
        // A tap selects a day; a press, held, scrubs across them; a swipe scrolls the list as ever.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(self.touch(_:)))
        press.minimumPressDuration = 0.2
        press.cancelsTouchesInView = false
        self.view.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.tapped(_:)))
        self.view.addGestureRecognizer(tap)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let item = self.item, !item.report.days.isEmpty else {
            return
        }
        let point = recognizer.location(in: self.view)
        if self.metricNode.frame.insetBy(dx: -12.0, dy: -10.0).contains(point) {
            item.toggleMetric()
        } else if self.plot.insetBy(dx: 0.0, dy: -20.0).contains(point) {
            let step = self.plot.width / CGFloat(item.report.days.count)
            let index = max(0, min(item.report.days.count - 1, Int((point.x - self.plot.minX) / step)))
            item.selectDay(index == item.selectedDay ? nil : index)
        } else {
            item.selectDay(nil)
        }
    }

    @objc private func touch(_ recognizer: UILongPressGestureRecognizer) {
        guard let item = self.item, !item.report.days.isEmpty else {
            return
        }
        let point = recognizer.location(in: self.view)
        guard self.plot.insetBy(dx: 0.0, dy: -20.0).contains(point) || recognizer.state == .changed else {
            return
        }
        switch recognizer.state {
        case .began, .changed:
            let step = self.plot.width / CGFloat(item.report.days.count)
            let index = max(0, min(item.report.days.count - 1, Int((point.x - self.plot.minX) / step)))
            if index != item.selectedDay {
                item.selectDay(index)
            }
        default:
            break
        }
    }

    private func value(_ totals: UsageTotals, metric: UsageController.Metric) -> Double {
        return metric == .cost ? totals.cost : Double(totals.tokens)
    }

    private func format(_ value: Double, metric: UsageController.Metric) -> String {
        return metric == .cost ? formatCost(value) : formatTokens(Int(value))
    }

    func update(item: UsageChartItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        self.item = item
        let theme = item.theme.list
        let width = params.width - params.leftInset - params.rightInset - sectionInset * 2.0
        let left = params.leftInset + sectionInset
        let days = item.report.days
        let metric = item.metric

        // Header: the selected day, or the span's total; the metric to switch to.
        let header: String
        if let selected = item.selectedDay, selected < days.count {
            header = "\(dayTitle(days[selected].day)) · \(self.format(self.value(days[selected].total, metric: metric), metric: metric))"
        } else {
            let total = self.value(item.report.total, metric: metric)
            header = "\(self.format(total, metric: metric)) in \(days.count) days"
        }
        self.titleNode.attributedText = NSAttributedString(string: header, font: Font.semibold(15.0), textColor: theme.itemPrimaryTextColor)
        self.metricNode.attributedText = NSAttributedString(string: metric == .cost ? "Tokens" : "Cost", font: Font.regular(15.0), textColor: theme.itemAccentColor)
        let metricSize = self.metricNode.updateLayout(CGSize(width: 100.0, height: 30.0))
        self.metricNode.frame = CGRect(origin: CGPoint(x: left + width - 16.0 - metricSize.width, y: 14.0), size: metricSize)
        let titleSize = self.titleNode.updateLayout(CGSize(width: width - 48.0 - metricSize.width, height: 30.0))
        self.titleNode.frame = CGRect(origin: CGPoint(x: left + 16.0, y: 14.0), size: titleSize)

        // The plot, with room for the grid's values above its lines and the dates under it.
        let plot = CGRect(x: left + 16.0, y: 50.0, width: width - 32.0, height: 150.0)
        self.plot = plot
        let totals = days.map { self.value($0.total, metric: metric) }
        let maximum = niceCeiling(totals.max() ?? 0.0)
        self.chartLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        self.chartLayer.frame = CGRect(origin: CGPoint(), size: CGSize(width: params.width, height: 300.0))
        var labels: [(String, CGRect, UIColor)] = []
        // Three lines: 0, half, the top.
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.maxY - plot.height * CGFloat(fraction)
            let line = CALayer()
            line.backgroundColor = theme.itemBlocksSeparatorColor.cgColor
            line.frame = CGRect(x: plot.minX, y: y, width: plot.width, height: UIScreenPixel)
            self.chartLayer.addSublayer(line)
            if maximum > 0.0 {
                labels.append((self.format(maximum * fraction, metric: metric), CGRect(x: plot.minX, y: y - 16.0, width: 120.0, height: 14.0), theme.itemSecondaryTextColor))
            }
        }
        if !days.isEmpty && maximum > 0.0 {
            let step = plot.width / CGFloat(days.count)
            let barWidth = max(1.0, step * (days.count > 40 ? 0.8 : 0.66))
            // One path a model, and one more for the selected bar at full strength.
            var paths = Dictionary(uniqueKeysWithValues: item.models.map { ($0, UIBezierPath()) })
            var selectedPaths = Dictionary(uniqueKeysWithValues: item.models.map { ($0, UIBezierPath()) })
            for (index, day) in days.enumerated() {
                var y = plot.maxY
                let x = plot.minX + step * CGFloat(index) + (step - barWidth) / 2.0
                for model in item.models {
                    guard let totals = day.models[model] else {
                        continue
                    }
                    let height = plot.height * CGFloat(self.value(totals, metric: metric) / maximum)
                    guard height > 0.0 else {
                        continue
                    }
                    let rect = CGRect(x: x, y: y - height, width: barWidth, height: height)
                    if index == item.selectedDay {
                        selectedPaths[model]?.append(UIBezierPath(rect: rect))
                    } else {
                        paths[model]?.append(UIBezierPath(rect: rect))
                    }
                    y -= height
                }
            }
            for model in item.models {
                let color = item.colors[model] ?? seriesColors[0]
                for (path, alpha) in [(paths[model], item.selectedDay == nil ? 1.0 : 0.35), (selectedPaths[model], 1.0)] {
                    guard let path, !path.isEmpty else {
                        continue
                    }
                    let shape = CAShapeLayer()
                    shape.path = path.cgPath
                    shape.fillColor = color.withAlphaComponent(alpha).cgColor
                    self.chartLayer.addSublayer(shape)
                }
            }
            // Dates: the first, the middle and the last.
            let marks = Array(Set([0, days.count / 2, days.count - 1])).sorted()
            for index in marks {
                let x = plot.minX + step * (CGFloat(index) + 0.5)
                labels.append((dayTitle(days[index].day), CGRect(x: x - 40.0, y: plot.maxY + 6.0, width: 80.0, height: 14.0), theme.itemSecondaryTextColor))
            }
        }
        while self.labelNodes.count < labels.count {
            let node = ImmediateTextNode()
            self.labelNodes.append(node)
            self.addSubnode(node)
        }
        for (index, node) in self.labelNodes.enumerated() {
            guard index < labels.count else {
                node.isHidden = true
                continue
            }
            let (text, frame, color) = labels[index]
            node.isHidden = false
            node.attributedText = NSAttributedString(string: text, font: Font.regular(11.0), textColor: color)
            let size = node.updateLayout(frame.size)
            // Grid values at the left over their lines; dates centered under their bars, kept inside the card.
            var x = frame.width == 120.0 ? frame.minX : frame.midX - size.width / 2.0
            x = min(max(x, plot.minX), plot.maxX - size.width)
            node.frame = CGRect(origin: CGPoint(x: x, y: frame.minY), size: size)
        }

        // The legend: each model with its share of the span, or of the selected day.
        var y = plot.maxY + 30.0
        var x = plot.minX
        let source: [String: UsageTotals]
        if let selected = item.selectedDay, selected < days.count {
            source = days[selected].models
        } else {
            source = Dictionary(item.report.models.map { ($0.model, $0.totals) }, uniquingKeysWith: { first, _ in first })
        }
        let shown = item.models.filter { source[$0] != nil }
        while self.legendNodes.count < shown.count {
            let node = ImmediateTextNode()
            self.legendNodes.append(node)
            self.addSubnode(node)
        }
        for (index, node) in self.legendNodes.enumerated() {
            guard index < shown.count else {
                node.isHidden = true
                continue
            }
            let model = shown[index]
            let text = NSMutableAttributedString(string: "● ", font: Font.regular(13.0), textColor: item.colors[model] ?? seriesColors[0])
            text.append(NSAttributedString(string: "\(shortModelName(model)) \(self.format(self.value(source[model] ?? UsageTotals(), metric: metric), metric: metric))", font: Font.regular(13.0), textColor: theme.itemPrimaryTextColor))
            node.isHidden = false
            node.attributedText = text
            let size = node.updateLayout(CGSize(width: plot.width, height: 20.0))
            if x > plot.minX && x + size.width > plot.maxX {
                x = plot.minX
                y += 20.0
            }
            node.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + 14.0
        }
        let height = y + (shown.isEmpty ? 0.0 : 20.0) + 12.0
        self.backgroundNode.backgroundColor = theme.itemBlocksBackgroundColor
        self.backgroundNode.frame = CGRect(x: left, y: 0.0, width: width, height: height)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }
}

/// "Oct 21" from "2026-10-21".
private func dayTitle(_ day: String) -> String {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.timeZone = TimeZone(identifier: "UTC")
    guard let date = parser.date(from: day) else {
        return day
    }
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

/// The chart's top: the largest day rounded up to 1, 2 or 5 times a power of ten.
private func niceCeiling(_ value: Double) -> Double {
    guard value > 0.0 else {
        return 0.0
    }
    let power = pow(10.0, floor(log10(value)))
    for step in [1.0, 2.0, 5.0, 10.0] where step * power >= value {
        return step * power
    }
    return 10.0 * power
}
