import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import UndoUI

/// One account: who it is, each limit of its plan with a large bar, and what can be done with it: use it, sign in to
/// it again, name it, sign out.
final class AccountController: SettingsListController {
    private let slot: Int
    private let accountId: String
    private var state: AccountsState?
    private let stateDisposable = MetaDisposable()
    private var ticker: SwiftSignalKit.Timer?

    init(context: AppContext, slot: Int, accountId: String) {
        self.slot = slot
        self.accountId = accountId
        super.init(context: context, title: "")
        if let server = context.store.server(slot) {
            self.stateDisposable.set((server.accountsSignal |> deliverOnMainQueue).start(next: { [weak self] state in
                self?.state = state
                self?.reload()
            }))
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.stateDisposable.dispose()
        self.ticker?.invalidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Its numbers now: the server asks at most every 20 seconds.
        self.server?.refreshAccounts(self.accountId)
        let ticker = SwiftSignalKit.Timer(timeout: 30.0, repeat: true, completion: { [weak self] in
            self?.reload()
        }, queue: Queue.mainQueue())
        self.ticker?.invalidate()
        self.ticker = ticker
        ticker.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.ticker?.invalidate()
        self.ticker = nil
    }

    private var server: TauServer? {
        return self.context.store.server(self.slot)
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        guard let account = self.state?.account(self.accountId) else {
            return []
        }
        let single = SettingsRowPosition(isFirst: true, isLast: true)
        var items: [ListViewItem] = []
        let hasSiblings = self.state?.accounts.contains { $0.provider == account.provider && $0.id != account.id } ?? false
        // Its problem has a section of its own below.
        let subtitle = accountSubtitle(account, hasSiblings: hasSiblings, showsProblem: false).text
        items.append(AccountHeaderItem(theme: theme, account: account, subtitle: subtitle))

        if let problem = account.problem {
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Sign In Again", titleColor: theme.list.itemAccentColor, accessory: .none, position: single, action: { [weak self] in
                self?.signInAgain(account)
            }))
            items.append(SettingsTextItem(theme: theme, text: "Its sign-in no longer refreshes: \(problem)", kind: .footer))
        }
        if !account.active {
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Use This Account", titleColor: theme.list.itemAccentColor, accessory: .none, position: single, action: { [weak self] in
                guard let self else {
                    return
                }
                self.server?.useAccount(account.id)
                self.present(UndoOverlayController(presentationData: self.theme.presentationData, content: .succeed(text: "**\(account.title)** in use for \(account.serviceName)", timeout: nil, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
            }))
            items.append(SettingsTextItem(theme: theme, text: "Chats on \(self.server?.name ?? "the server") use it from their next request.", kind: .footer))
        }

        if let usage = account.usage, !usage.windows.isEmpty {
            items.append(SettingsTextItem(theme: theme, text: "Usage", kind: .header))
            for (index, window) in usage.windows.enumerated() {
                items.append(UsageWindowItem(theme: theme, window: window, position: SettingsRowPosition(isFirst: index == 0, isLast: index == usage.windows.count - 1 && usage.credits == nil)))
            }
            if let credits = usage.credits {
                items.append(SettingsRowItem(theme: theme, icon: nil, title: "Beyond the Plan", accessory: .value(credits), position: SettingsRowPosition(isFirst: false, isLast: true), action: nil))
            }
            // When the numbers are from; a failed update since leaves them, and says nothing.
            if usage.at.timeIntervalSince1970 > 0 {
                items.append(SettingsTextItem(theme: theme, text: usageUpdatedText(usage.at), kind: .footer))
            }
        } else if account.usage?.error != nil {
            items.append(SettingsTextItem(theme: theme, text: "Usage", kind: .header))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Unavailable", titleColor: theme.list.itemSecondaryTextColor, accessory: .none, position: single, action: nil))
        }

        items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Name", accessory: .disclosure(label: account.label ?? ""), position: single, action: { [weak self] in
            self?.rename(account)
        }))

        items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Sign Out", titleColor: theme.list.itemDestructiveColor, accessory: .none, position: single, action: { [weak self] in
            self?.confirmSignOut(account)
        }))
        return items
    }

    private func rename(_ account: ProviderAccount) {
        let slot = self.slot
        let store = self.context.store
        let alert = fieldsAlertController(context: self.context.telegram, presentationData: self.theme.presentationData, title: "Account Name", text: nil, fields: [
            AlertField(placeholder: account.email ?? account.serviceName, value: account.label),
        ], apply: { values in
            store.server(slot)?.renameAccount(account.id, label: values[0])
            return true
        })
        self.present(alert, in: .window(.root))
    }

    /// A new sign-in for the same provider; the server puts it in place of this one when it is the same account.
    private func signInAgain(_ account: ProviderAccount) {
        let controller = LoginController(context: self.context, slot: self.slot, provider: account.provider, providerName: account.providerName, type: account.type)
        self.push(controller)
    }

    private func confirmSignOut(_ account: ProviderAccount) {
        let presentationData = self.theme.presentationData
        let server = self.server
        let actionSheet = ActionSheetController(presentationData: presentationData)
        let text = "\(account.title) will be signed out from \(server?.name ?? "the server")."
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: text),
                ActionSheetButtonItem(title: "Sign Out", color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    server?.removeAccount(account.id)
                    let _ = (self?.navigationController as? NavigationController)?.popViewController(animated: true)
                }),
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                }),
            ]),
        ])
        self.present(actionSheet, in: .window(.root))
    }
}

/// The account's avatar, large, its name and what it is, as the top of a Telegram profile.
final class AccountHeaderItem: SyncListItem {
    let theme: TauTheme
    let account: ProviderAccount
    let subtitle: String

    init(theme: TauTheme, account: ProviderAccount, subtitle: String) {
        self.theme = theme
        self.account = account
        self.subtitle = subtitle
    }

    override func makeNode() -> SyncListItemNode {
        return AccountHeaderItemNode()
    }
}

final class AccountHeaderItemNode: SyncListItemNode {
    private let avatarNode = ASImageNode()
    private let titleNode = ImmediateTextNode()
    private let subtitleNode = ImmediateTextNode()

    override init() {
        super.init()
        self.avatarNode.displaysAsynchronously = false
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
    }

    override func update(item: SyncListItem, params: ListViewItemLayoutParams, animated: Bool) -> ListViewItemNodeLayout {
        guard let item = item as? AccountHeaderItem else {
            return ListViewItemNodeLayout(contentSize: CGSize(), insets: UIEdgeInsets())
        }
        let avatarSize: CGFloat = 90.0
        self.avatarNode.image = ProviderIcon.image(provider: item.account.provider, name: item.account.providerName, size: avatarSize)
        self.titleNode.attributedText = NSAttributedString(string: item.account.title, font: Font.semibold(24.0), textColor: item.theme.list.itemPrimaryTextColor)
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.truncationType = .middle
        self.subtitleNode.attributedText = NSAttributedString(string: item.subtitle, font: Font.regular(16.0), textColor: item.theme.list.itemSecondaryTextColor)
        let titleSize = self.titleNode.updateLayout(CGSize(width: params.width - 40.0, height: 40.0))
        let subtitleSize = self.subtitleNode.updateLayout(CGSize(width: params.width - 40.0, height: 30.0))
        self.avatarNode.frame = CGRect(x: floor((params.width - avatarSize) / 2.0), y: 0.0, width: avatarSize, height: avatarSize)
        self.titleNode.frame = CGRect(origin: CGPoint(x: floor((params.width - titleSize.width) / 2.0), y: avatarSize + 12.0), size: titleSize)
        self.subtitleNode.frame = CGRect(origin: CGPoint(x: floor((params.width - subtitleSize.width) / 2.0), y: self.titleNode.frame.maxY + 2.0), size: subtitleSize)
        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "accountHeader"
        self.accessibilityLabel = item.account.title
        self.accessibilityValue = item.subtitle
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: self.subtitleNode.frame.maxY), insets: UIEdgeInsets(top: 12.0, left: 0.0, bottom: 4.0, right: 0.0))
    }
}

/// "Usage updated now", "Usage updated 2m ago".
func usageUpdatedText(_ date: Date, now: Date = Date()) -> String {
    return now.timeIntervalSince(date) < 60 ? "Usage updated now" : "Usage updated \(durationText(until: now, now: date)) ago"
}
