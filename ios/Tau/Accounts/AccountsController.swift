import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import WidgetKit

/// The Accounts tab (docs/accounts.md): each server's accounts by service, their usage in small bars, the one in use checked; Add Account;
/// keys the server has from its environment. Usage is asked again when the tab shows numbers a minute old.
final class AccountsController: SettingsListController {
    private var states: [Int: AccountsState] = [:]
    private let statesDisposable = MetaDisposable()
    private var serversDisposable: Disposable?
    private var ticker: SwiftSignalKit.Timer?
    /// Called with how many accounts need something done: the tab's badge.
    var badgeChanged: ((Int) -> Void)?
    /// The usage widget's last update from here, and what it showed: the accounts in use and their percentages.
    private var widgetReloaded: Date = .distantPast
    private var widgetShown: [String] = []

    init(context: AppContext) {
        super.init(context: context, title: "Accounts")
        self.serversDisposable = (context.store.serversSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.observe()
        })
        self.observe()
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.statesDisposable.dispose()
        self.serversDisposable?.dispose()
        self.ticker?.invalidate()
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
            self.badgeChanged?(states.values.reduce(0) { $0 + $1.accounts.filter { $0.problem != nil || ($0.active && $0.usage?.windows.contains { $0.usedPercent >= 100 } == true) }.count })
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
                server.refreshAccounts()
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

    override func items(theme: TauTheme) -> [ListViewItem] {
        let store = self.context.store
        let servers = store.servers
        var items: [ListViewItem] = []
        let several = servers.count > 1
        for server in servers {
            let slot = server.slot
            guard let state = self.states[slot] else {
                if several {
                    items.append(SettingsTextItem(theme: theme, text: server.name, kind: .header))
                }
                if !several {
                    items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
                }
                let online = server.status == .online
                items.append(SettingsRowItem(theme: theme, icon: nil, title: online ? "Not Available" : "Connecting…", titleColor: theme.list.itemSecondaryTextColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: nil))
                if online {
                    items.append(SettingsTextItem(theme: theme, text: "\(server.name) is too old to manage its accounts here: update it.", kind: .footer))
                }
                continue
            }
            // By service, in the order the server has the providers: a subscription's sign-in first, then keys.
            let groups = Dictionary(grouping: state.accounts) { "\($0.serviceName)" }
            let order = state.accounts.map(\.serviceName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let sorted = order.sorted { lhs, rhs in
                let lhsKey = groups[lhs]?.contains { $0.type == "oauth" } == true ? 0 : 1
                let rhsKey = groups[rhs]?.contains { $0.type == "oauth" } == true ? 0 : 1
                return lhsKey < rhsKey
            }
            if several {
                items.append(SettingsTextItem(theme: theme, text: server.name, kind: .header))
            }
            if state.accounts.isEmpty {
                if !several {
                    items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
                }
                items.append(SettingsRowItem(theme: theme, icon: nil, title: "No accounts yet", titleColor: theme.list.itemSecondaryTextColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: false), action: nil))
                items.append(self.addRow(theme: theme, slot: slot, position: SettingsRowPosition(isFirst: false, isLast: true)))
            } else {
                for (groupIndex, name) in sorted.enumerated() {
                    let accounts = groups[name] ?? []
                    items.append(SettingsTextItem(theme: theme, text: several && groupIndex == 0 ? "\(name)" : name, kind: .header))
                    for (index, account) in accounts.enumerated() {
                        items.append(AccountRowItem(theme: theme, account: account, position: SettingsRowPosition(isFirst: index == 0, isLast: index == accounts.count - 1), action: { [weak self] in
                            guard let self else {
                                return
                            }
                            self.push(AccountController(context: self.context, slot: slot, accountId: account.id))
                        }))
                    }
                }
                items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
                items.append(self.addRow(theme: theme, slot: slot, position: SettingsRowPosition(isFirst: true, isLast: true)))
            }
            if !state.ambient.isEmpty {
                items.append(SettingsTextItem(theme: theme, text: "From the Server's Environment", kind: .header))
                for (index, ambient) in state.ambient.enumerated() {
                    items.append(SettingsRowItem(theme: theme, icon: nil, title: ambient.providerName, subtitle: ambient.source, accessory: .none, position: SettingsRowPosition(isFirst: index == 0, isLast: index == state.ambient.count - 1), action: nil))
                }
            }
            if let footer = self.footer(state) {
                items.append(SettingsTextItem(theme: theme, text: footer, kind: .footer))
            }
        }
        return items
    }

    /// When the numbers are from, once there are any.
    private func footer(_ state: AccountsState) -> String? {
        let times = state.accounts.compactMap { $0.usage?.at }.filter { $0.timeIntervalSince1970 > 0 }
        guard let oldest = times.min() else {
            return nil
        }
        let age = Date().timeIntervalSince(oldest)
        if age < 90 {
            return "Usage as of now. The tick on a bar is where an even pace would be."
        }
        return "Usage as of \(durationText(until: Date(), now: oldest)) ago. The tick on a bar is where an even pace would be."
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
