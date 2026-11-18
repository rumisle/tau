import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import WidgetKit
import ComponentFlow
import ComponentDisplayAdapters
import NavigationBarImpl

/// The Accounts tab (docs/accounts.md): a server's accounts in one list, each with its provider's logo and its usage;
/// the keys from its environment; Add Account last. Several servers: the chat list's folder tabs under the title, one
/// list a server, a swipe between them as between folders. Usage is asked again when the tab shows numbers a minute old.
final class AccountsController: ViewController {
    let context: AppContext
    private var theme: TauTheme
    private var themeDisposable: Disposable?
    private var states: [Int: AccountsState] = [:]
    private let statesDisposable = MetaDisposable()
    private var serversDisposable: Disposable?
    private var ticker: SwiftSignalKit.Timer?
    private var tabsNode: ChatListFolderTabsNode?
    /// Called with how many accounts need something done: the tab's badge.
    var badgeChanged: ((Int) -> Void)?
    /// The usage widget's last update from here, and what it showed: the accounts in use and their percentages.
    private var widgetReloaded: Date = .distantPast
    private var widgetShown: [String] = []

    private var pagesNode: AccountsPagesNode {
        return self.displayNode as! AccountsPagesNode
    }

    init(context: AppContext) {
        self.context = context
        self.theme = context.theme
        super.init(navigationBarPresentationData: context.theme.navigationBarPresentationData(edgeEffectColor: context.theme.list.blocksBackgroundColor))
        self.title = "Accounts"
        self.statusBar.statusBarStyle = self.theme.statusBarStyleValue
        self.themeDisposable = (context.themeContext.theme |> deliverOnMainQueue).start(next: { [weak self] theme in
            guard let self, theme !== self.theme else {
                return
            }
            self.theme = theme
            self.statusBar.statusBarStyle = theme.statusBarStyleValue
            self.navigationBar?.updatePresentationData(theme.navigationBarPresentationData(edgeEffectColor: theme.list.blocksBackgroundColor), transition: .immediate)
            if self.isNodeLoaded {
                self.pagesNode.backgroundColor = theme.list.blocksBackgroundColor
            }
            self.reload()
        })
        self.serversDisposable = (context.store.serversSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.observe()
        })
        self.observe()
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.themeDisposable?.dispose()
        self.statesDisposable.dispose()
        self.serversDisposable?.dispose()
        self.ticker?.invalidate()
    }

    override func loadDisplayNode() {
        let node = AccountsPagesNode(backgroundColor: self.theme.list.blocksBackgroundColor)
        node.selectedChanged = { [weak self] slot in
            self?.selectedSlot = slot
            self?.updateTabs(transition: .spring(duration: 0.4))
        }
        node.switchFractionUpdated = { [weak self] fraction, isDragging, transition in
            self?.tabsNode?.updateSwitchFraction(fraction, isDragging: isDragging, transition: ComponentTransition(transition))
        }
        self.displayNode = node
        self.displayNodeDidLoad()
        self.reload()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        if let tabsNode = self.tabsNode, tabsNode.supernode != nil, let navigationBar = self.navigationBar {
            let height = ChatListFolderTabsNode.height
            transition.updateFrame(node: tabsNode, frame: CGRect(x: 0.0, y: navigationBar.frame.height - height, width: layout.size.width, height: height))
            tabsNode.updateLayout(width: layout.size.width, transition: ComponentTransition(transition))
        }
        self.pagesNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Queue.mainQueue().after(0.1) { [weak self] in
            self?.tabsNode?.remakeIfNeeded()
        }
    }

    private func observe() {
        let servers = self.context.store.servers
        let signals = servers.map { server in server.accountsSignal |> map { (server.slot, $0) } }
        guard !signals.isEmpty else {
            self.states = [:]
            self.reload()
            return
        }
        self.statesDisposable.set((combineLatest(signals) |> deliverOnMainQueue).start(next: { [weak self] pairs in
            guard let self else {
                return
            }
            var states: [Int: AccountsState] = [:]
            for (slot, state) in pairs {
                if let state {
                    states[slot] = state
                }
            }
            self.states = states
            self.reloadWidget()
            self.badgeChanged?(states.values.reduce(0) { $0 + $1.attentionCount })
            self.reload()
        }))
    }

    /// The widget asks the servers itself every quarter of an hour; while the app runs, it follows at once when another
    /// account is put in use, and every five minutes when the numbers move.
    private func reloadWidget() {
        let shown = self.states.keys.sorted().flatMap { slot in
            (self.states[slot]?.accounts ?? []).filter(\.active).map { account in "\(account.id):" + (account.usage?.windows.map { "\(Int($0.usedPercent))" }.joined(separator: ",") ?? "") }
        }
        guard shown != self.widgetShown else {
            return
        }
        let accountsChanged = shown.map { $0.split(separator: ":").first } != self.widgetShown.map { $0.split(separator: ":").first }
        guard accountsChanged || Date().timeIntervalSince(self.widgetReloaded) > 300 else {
            return
        }
        self.widgetShown = shown
        self.widgetReloaded = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "accounts")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        for server in self.context.store.servers {
            let stale = server.accountsState?.accounts.contains { $0.type == "oauth" && Date().timeIntervalSince($0.usage?.at ?? .distantPast) > 60 } ?? false
            if stale {
                server.refreshAccounts(nil)
            }
        }
        // Reset times count down while the tab shows.
        self.ticker?.invalidate()
        let ticker = SwiftSignalKit.Timer(timeout: 30.0, repeat: true, completion: { [weak self] in
            self?.reload()
        }, queue: Queue.mainQueue())
        self.ticker = ticker
        ticker.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.ticker?.invalidate()
        self.ticker = nil
    }

    /// The server shown, when there are several: the one picked last.
    private var selectedSlot: Int? {
        get {
            return UserDefaults.standard.object(forKey: "accounts.server") as? Int
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "accounts.server")
        }
    }

    /// Each server's list, and the folder tabs over them while there are several.
    private func reload() {
        guard self.isNodeLoaded else {
            return
        }
        let servers = self.context.store.servers
        let selected = servers.first { $0.slot == self.selectedSlot }?.slot ?? servers.first?.slot
        self.pagesNode.topSpacing = servers.count < 2 ? 0.0 : 8.0
        self.pagesNode.update(pages: servers.map { server in (server.slot, self.items(server: server, theme: self.theme)) }, selected: selected)
        self.updateTabBar()
    }

    private func updateTabBar() {
        guard let navigationBar = self.navigationBar as? NavigationBarImpl else {
            return
        }
        if self.context.store.servers.count < 2 {
            if self.tabsNode != nil {
                navigationBar.setSecondaryContentNode(nil, animated: true)
                self.tabsNode = nil
                self.requestLayout(transition: .animated(duration: 0.3, curve: .spring))
            }
            return
        }
        if self.tabsNode == nil {
            let tabsNode = ChatListFolderTabsNode(theme: self.theme)
            tabsNode.select = { [weak self] id in
                guard let self, case let .folder(value) = id else {
                    return
                }
                self.pagesNode.select(Int(value))
            }
            self.tabsNode = tabsNode
            navigationBar.secondaryContentHeight = ChatListFolderTabsNode.height
            navigationBar.setSecondaryContentNode(tabsNode, animated: self.view.window != nil)
            self.updateTabs(transition: .immediate)
            self.requestLayout(transition: self.view.window != nil ? .animated(duration: 0.3, curve: .spring) : .immediate)
        } else {
            self.updateTabs(transition: .spring(duration: 0.4))
        }
    }

    /// A tab a server: its name, and its accounts to see to as the badge.
    private func updateTabs(transition: ComponentTransition) {
        guard let tabsNode = self.tabsNode else {
            return
        }
        let tabs = self.context.store.servers.map { server in
            ChatListFolderTab(id: .folder(Int32(server.slot)), title: server.name, unread: self.states[server.slot]?.attentionCount ?? 0)
        }
        let selected = self.pagesNode.selectedSlot ?? self.context.store.servers.first?.slot ?? 0
        tabsNode.update(theme: self.theme, tabs: tabs, selected: .folder(Int32(selected)), isEditing: false, transition: transition)
    }

    private func items(server: TauServer, theme: TauTheme) -> [ListViewItem] {
        // One server: the room a header leaves under the title. Several: the tabs are there, and a little room under them.
        var items: [ListViewItem] = self.context.store.servers.count < 2 ? [SettingsTextItem(theme: theme, text: "", kind: .header)] : []
        let slot = server.slot
        guard let state = self.states[slot] else {
            let online = server.status == .online
            items.append(SettingsRowItem(theme: theme, icon: nil, title: online ? "Not Available" : "Connecting…", titleColor: theme.list.itemSecondaryTextColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: nil))
            if online {
                items.append(SettingsTextItem(theme: theme, text: "\(server.name) is too old to manage its accounts here: update it.", kind: .footer))
            }
            return items
        }
        // One list: subscriptions first, then keys, as the server has them otherwise; the environment's keys; Add Account.
        let accounts = state.accounts.filter { $0.type == "oauth" } + state.accounts.filter { $0.type != "oauth" }
        var rows: [(SettingsRowPosition) -> ListViewItem] = []
        for account in accounts {
            let hasSiblings = state.accounts.contains { $0.provider == account.provider && $0.id != account.id }
            let subtitle = accountSubtitle(account, hasSiblings: hasSiblings)
            rows.append { position in
                AccountRowItem(theme: theme, icon: ProviderIcon.image(provider: account.provider, name: account.providerName, size: 36.0), title: account.title, subtitle: subtitle.text, isProblem: subtitle.isProblem, windows: account.usage?.windows ?? [], position: position, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.push(AccountController(context: self.context, slot: slot, accountId: account.id))
                })
            }
        }
        for ambient in state.ambient {
            rows.append { position in
                AccountRowItem(theme: theme, icon: ProviderIcon.image(provider: ambient.provider, name: ambient.providerName, size: 36.0), title: ambient.providerName, subtitle: "From \(ambient.source)", position: position, action: nil)
            }
        }
        rows.append { [unowned self] position in
            self.addRow(theme: theme, slot: slot, position: position)
        }
        for (index, row) in rows.enumerated() {
            items.append(row(SettingsRowPosition(isFirst: index == 0, isLast: index == rows.count - 1)))
        }
        return items
    }

    private func addRow(theme: TauTheme, slot: Int, position: SettingsRowPosition) -> ListViewItem {
        return SettingsRowItem(theme: theme, icon: accentPlusIcon(theme), title: "Add Account", titleColor: theme.list.itemAccentColor, accessory: .none, position: position, action: { [weak self] in
            guard let self else {
                return
            }
            self.push(AddAccountController(context: self.context, slot: slot))
        })
    }
}


/// One list a server, side by side; a swipe goes to the next as the chat list goes between folders
/// (ChatListControllerNode, after Telegram's ChatListContainerNode).
final class AccountsPagesNode: ASDisplayNode, ASGestureRecognizerDelegate {
    private var pages: [(slot: Int, node: SettingsListNode)] = []
    private(set) var selectedSlot: Int?
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?
    private var transitionFraction: CGFloat = 0.0
    private var transitionFractionOffset: CGFloat = 0.0
    /// Room between the tabs and the lists.
    var topSpacing: CGFloat = 0.0
    var selectedChanged: ((Int) -> Void)?
    var switchFractionUpdated: ((CGFloat, Bool, ContainedViewLayoutTransition) -> Void)?

    init(backgroundColor: UIColor) {
        super.init()
        self.backgroundColor = backgroundColor
        self.clipsToBounds = true
    }

    override func didLoad() {
        super.didLoad()
        let recognizer = InteractiveTransitionGestureRecognizer(target: self, action: #selector(self.panGesture(_:)), allowedDirections: { [weak self] _ in
            guard let self, self.pages.count > 1, let page = self.pages.first(where: { $0.slot == self.selectedSlot })?.node else {
                return []
            }
            if page.listView.isDragging || page.listView.isDeceleratingAfterTracking {
                return []
            }
            return [.leftCenter, .rightCenter]
        }, edgeWidth: .widthMultiplier(factor: 1.0 / 6.0, min: 22.0, max: 80.0))
        recognizer.delegate = self.wrappedGestureRecognizerDelegate
        recognizer.delaysTouchesBegan = false
        recognizer.cancelsTouchesInView = true
        self.view.addGestureRecognizer(recognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is InteractiveTransitionGestureRecognizer {
            return false
        }
        return otherGestureRecognizer is UIPanGestureRecognizer
    }

    func update(pages: [(slot: Int, items: [ListViewItem])], selected: Int?) {
        let slots = pages.map(\.slot)
        for page in self.pages where !slots.contains(page.slot) {
            page.node.removeFromSupernode()
        }
        var next: [(slot: Int, node: SettingsListNode)] = []
        for page in pages {
            let node = self.pages.first { $0.slot == page.slot }?.node ?? {
                let node = SettingsListNode(backgroundColor: .clear)
                self.addSubnode(node)
                return node
            }()
            node.setItems(page.items)
            next.append((page.slot, node))
        }
        self.pages = next
        if self.selectedSlot == nil || !slots.contains(self.selectedSlot!) {
            self.selectedSlot = selected
        }
        self.layoutPages(transition: .immediate)
    }

    /// A tab tapped: its list slides in from its side.
    func select(_ slot: Int) {
        guard slot != self.selectedSlot, self.pages.contains(where: { $0.slot == slot }) else {
            return
        }
        self.selectedSlot = slot
        self.layoutPages(transition: .animated(duration: 0.4, curve: .spring))
        self.selectedChanged?(slot)
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationHeight)
        self.layoutPages(transition: transition)
    }

    private func layoutPages(transition: ContainedViewLayoutTransition) {
        guard let (layout, navigationHeight) = self.validLayout else {
            return
        }
        let selectedIndex = self.pages.firstIndex { $0.slot == self.selectedSlot } ?? 0
        for (index, page) in self.pages.enumerated() {
            let distance = CGFloat(index - selectedIndex) + self.transitionFraction
            transition.updateFrame(node: page.node, frame: CGRect(origin: CGPoint(x: distance * layout.size.width, y: 0.0), size: layout.size))
            page.node.containerLayoutUpdated(layout, navigationHeight: navigationHeight + self.topSpacing, transition: transition)
        }
    }

    @objc private func panGesture(_ recognizer: InteractiveTransitionGestureRecognizer) {
        guard let (layout, _) = self.validLayout, let selectedIndex = self.pages.firstIndex(where: { $0.slot == self.selectedSlot }) else {
            return
        }
        func rubberBand(_ offset: CGFloat) -> CGFloat {
            let range: CGFloat = 600.0
            return (1.0 - (1.0 / ((offset * 0.4 / range) + 1.0))) * range
        }
        switch recognizer.state {
        case .began:
            // Caught mid-slide: from where the list is on screen.
            self.transitionFractionOffset = 0.0
            if let page = self.pages.first(where: { $0.slot == self.selectedSlot })?.node, let presentation = page.layer.presentation() {
                self.transitionFractionOffset = presentation.frame.minX / layout.size.width
                if !self.transitionFractionOffset.isZero {
                    for page in self.pages {
                        page.node.layer.removeAllAnimations()
                    }
                }
            }
            self.transitionFraction = self.transitionFractionOffset
            self.layoutPages(transition: .immediate)
            self.switchFractionUpdated?(self.transitionFraction, true, .immediate)
        case .changed:
            let translation = recognizer.translation(in: self.view)
            var fraction = translation.x / layout.size.width
            if selectedIndex <= 0 && translation.x > 0.0 {
                fraction = rubberBand(translation.x) / layout.size.width
            }
            if selectedIndex >= self.pages.count - 1 && translation.x < 0.0 {
                fraction = -rubberBand(-translation.x) / layout.size.width
            }
            self.transitionFraction = fraction + self.transitionFractionOffset
            self.layoutPages(transition: .immediate)
            self.switchFractionUpdated?(self.transitionFraction, true, .immediate)
        case .cancelled, .ended:
            let translation = recognizer.translation(in: self.view)
            let velocity = recognizer.velocity(in: self.view)
            var toRight: Bool?
            if abs(velocity.x) > 10.0 {
                if translation.x < 0.0 {
                    toRight = velocity.x >= 0.0 ? nil : true
                } else {
                    toRight = velocity.x <= 0.0 ? nil : false
                }
            } else if abs(translation.x) > layout.size.width / 2.0 {
                toRight = translation.x < 0.0
            }
            if recognizer.state == .cancelled {
                toRight = nil
            }
            if let toRight {
                let index = toRight ? min(selectedIndex + 1, self.pages.count - 1) : max(selectedIndex - 1, 0)
                self.selectedSlot = self.pages[index].slot
            }
            self.transitionFraction = 0.0
            let transition: ContainedViewLayoutTransition = .animated(duration: 0.45, curve: .spring)
            self.layoutPages(transition: transition)
            if let slot = self.selectedSlot {
                self.selectedChanged?(slot)
            }
            self.switchFractionUpdated?(0.0, false, transition)
        default:
            break
        }
    }
}

/// Telegram's Add Account icon: the list's plus in the accent, centered in the icons' 30 pt.
func accentPlusIcon(_ theme: TauTheme) -> UIImage? {
    guard let plus = generateTintedImage(image: UIImage(bundleImageName: "Item List/AddItemIcon"), color: theme.list.itemAccentColor) else {
        return nil
    }
    return generateImage(CGSize(width: 30.0, height: 30.0), contextGenerator: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        if let image = plus.cgImage {
            context.draw(image, in: CGRect(x: floor((size.width - plus.size.width) / 2.0), y: floor((size.height - plus.size.height) / 2.0), width: plus.size.width, height: plus.size.height))
        }
    })
}
