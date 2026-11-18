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

    override func items(theme: TauTheme) -> [ListViewItem] {
        let servers = self.context.store.servers
        guard !servers.isEmpty else {
            return []
        }
        var items: [ListViewItem] = []
        // Several servers: Telegram's segmented control picks one, as Network Usage picks a network.
        let index = servers.firstIndex { $0.slot == self.selectedSlot } ?? 0
        let server = servers[index]
        if servers.count > 1 {
            items.append(UsageSpanItem(theme: theme, titles: servers.map(\.name), selectedIndex: index, changed: { [weak self] index in
                guard let self, index < self.context.store.servers.count else {
                    return
                }
                self.selectedSlot = self.context.store.servers[index].slot
                self.reload()
            }))
        } else {
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
        }
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
