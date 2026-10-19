import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

/// A grouped list screen, like Telegram's ItemListController: it rebuilds its rows from `items(theme)` whenever the
/// theme or its own state changes.
class SettingsListController: ViewController {
    let context: AppContext
    private(set) var theme: TauTheme
    private var themeDisposable: Disposable?

    private var listNode: SettingsListNode {
        return self.displayNode as! SettingsListNode
    }

    init(context: AppContext, title: String) {
        self.context = context
        self.theme = context.theme
        super.init(navigationBarPresentationData: context.theme.navigationBarPresentationData(edgeEffectColor: context.theme.list.blocksBackgroundColor))
        self.title = title
        self.statusBar.statusBarStyle = self.theme.statusBarStyleValue
        self.themeDisposable = (context.themeContext.theme |> deliverOnMainQueue).start(next: { [weak self] theme in
            guard let self, theme !== self.theme else {
                return
            }
            self.theme = theme
            self.statusBar.statusBarStyle = theme.statusBarStyleValue
            self.navigationBar?.updatePresentationData(theme.navigationBarPresentationData(edgeEffectColor: theme.list.blocksBackgroundColor), transition: .immediate)
            if self.isNodeLoaded {
                self.listNode.backgroundColor = theme.list.blocksBackgroundColor
            }
            self.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.themeDisposable?.dispose()
    }

    /// The rows, top to bottom.
    func items(theme: TauTheme) -> [ListViewItem] {
        return []
    }

    func reload() {
        guard self.isNodeLoaded else {
            return
        }
        self.listNode.setItems(self.items(theme: self.theme))
    }

    override func loadDisplayNode() {
        self.displayNode = SettingsListNode(backgroundColor: self.theme.list.blocksBackgroundColor)
        self.displayNodeDidLoad()
        self.reload()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.listNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
}

final class SettingsListNode: ASDisplayNode {
    private let listNode = ListViewImpl()
    private var itemCount = 0
    private var pendingItems: [ListViewItem]?
    private var hasLayout = false

    init(backgroundColor: UIColor) {
        super.init()
        self.backgroundColor = backgroundColor
        self.addSubnode(self.listNode)
    }

    func setItems(_ items: [ListViewItem]) {
        guard self.hasLayout else {
            self.pendingItems = items
            return
        }
        // Rows keep their positions, so replace them in place; a different row count rebuilds the list.
        if items.count == self.itemCount {
            let updates = items.enumerated().map { ListViewUpdateItem(index: $0.offset, previousIndex: $0.offset, item: $0.element, directionHint: nil) }
            self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: updates, options: [.Synchronous], updateOpaqueState: nil)
        } else {
            let deletions = (0 ..< self.itemCount).map { ListViewDeleteItem(index: $0, directionHint: nil) }
            let insertions = items.enumerated().map { ListViewInsertItem(index: $0.offset, previousIndex: nil, item: $0.element, directionHint: nil) }
            self.listNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], updateOpaqueState: nil)
        }
        self.itemCount = items.count
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        let insets = UIEdgeInsets(top: navigationHeight, left: layout.safeInsets.left, bottom: layout.intrinsicInsets.bottom + 16.0, right: layout.safeInsets.right)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)
        if !self.hasLayout {
            self.hasLayout = true
            if let items = self.pendingItems {
                self.pendingItems = nil
                self.setItems(items)
            }
        }
    }
}

/// Settings, laid out like Telegram's: a profile header, then grouped rows with colored icons.
final class SettingsController: SettingsListController {
    private var modeDisposable: Disposable?

    init(context: AppContext) {
        super.init(context: context, title: "Settings")
        self.modeDisposable = (context.themeContext.modeSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.modeDisposable?.dispose()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let context = self.context
        let first = SettingsRowPosition(isFirst: true, isLast: false)
        let middle = SettingsRowPosition(isFirst: false, isLast: false)
        let last = SettingsRowPosition(isFirst: false, isLast: true)
        let single = SettingsRowPosition(isFirst: true, isLast: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        return [
            SettingsProfileItem(theme: theme, title: "tau", subtitle: "Mock server · not connected"),
            SettingsTextItem(theme: theme, text: "Server", kind: .header),
            SettingsRowItem(theme: theme, icon: SettingsIcon.server, title: "Server", accessory: .disclosure(label: "Not set"), position: first, action: {}),
            SettingsRowItem(theme: theme, icon: SettingsIcon.model, title: "Default Model", accessory: .disclosure(label: "claude-opus-5-5"), position: middle, action: {}),
            SettingsRowItem(theme: theme, icon: SettingsIcon.projects, title: "Projects", accessory: .disclosure(label: ""), position: last, action: {}),
            SettingsTextItem(theme: theme, text: "Preferences", kind: .header),
            SettingsRowItem(theme: theme, icon: SettingsIcon.appearance, title: "Appearance", accessory: .disclosure(label: context.themeContext.mode.title), position: first, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(AppearanceController(context: self.context))
            }),
            SettingsRowItem(theme: theme, icon: SettingsIcon.notifications, title: "Notifications", accessory: .disclosure(label: "Off"), position: middle, action: {}),
            SettingsRowItem(theme: theme, icon: SettingsIcon.data, title: "Data and Storage", accessory: .disclosure(label: ""), position: last, action: {}),
            SettingsTextItem(theme: theme, text: "", kind: .header),
            SettingsRowItem(theme: theme, icon: SettingsIcon.about, title: "About tau", accessory: .disclosure(label: version), position: single, action: {}),
            SettingsTextItem(theme: theme, text: "tau is a client for pi-durable agents. Server settings arrive with the server connection.", kind: .footer),
        ]
    }
}

final class AppearanceController: SettingsListController {
    private var modeDisposable: Disposable?

    init(context: AppContext) {
        super.init(context: context, title: "Appearance")
        self.modeDisposable = (context.themeContext.modeSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.modeDisposable?.dispose()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let themeContext = self.context.themeContext
        let modes = ThemeContext.Mode.allCases
        var items: [ListViewItem] = [SettingsTextItem(theme: theme, text: "Color Theme", kind: .header)]
        for (index, mode) in modes.enumerated() {
            let position = SettingsRowPosition(isFirst: index == 0, isLast: index == modes.count - 1)
            items.append(SettingsRowItem(theme: theme, icon: nil, title: mode.title, accessory: .checkmark(themeContext.mode == mode), position: position, action: {
                themeContext.setMode(mode)
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "System switches between Day and Night with your iPhone's appearance.", kind: .footer))
        return items
    }
}
