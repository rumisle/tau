import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

/// Where an account can come from: a subscription's sign-in, or a provider's API key, every provider the server has.
final class AddAccountController: SettingsListController {
    private let slot: Int
    private var state: AccountsState?
    private let stateDisposable = MetaDisposable()

    init(context: AppContext, slot: Int) {
        self.slot = slot
        super.init(context: context, title: "Add Account")
        if let server = context.store.server(slot) {
            self.stateDisposable.set((server.accountsSignal |> deliverOnMainQueue).start(next: { [weak self] state in
                // The providers do not change while the screen shows: no reload for each usage update.
                let first = self?.state == nil
                self?.state = state
                if first {
                    self?.reload()
                }
            }))
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.stateDisposable.dispose()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        guard let providers = self.state?.providers else {
            return []
        }
        var items: [ListViewItem] = []
        // Subscriptions first, the best known first: as the providers list has them otherwise.
        let known = ["anthropic", "openai-codex", "github-copilot"]
        let signIns = providers.filter { $0.oauthName != nil }.sorted { lhs, rhs in
            let lhsRank = known.firstIndex(of: lhs.id) ?? (lhs.subscription ? known.count : known.count + 1)
            let rhsRank = known.firstIndex(of: rhs.id) ?? (rhs.subscription ? known.count : known.count + 1)
            return lhsRank < rhsRank
        }
        items.append(SettingsTextItem(theme: theme, text: "Sign In", kind: .header))
        for (index, provider) in signIns.enumerated() {
            let title = ProviderAccount.serviceName(provider: provider.id, providerName: provider.name, subscription: true)
            items.append(SettingsRowItem(theme: theme, icon: nil, title: title, subtitle: provider.oauthName, accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: index == 0, isLast: index == signIns.count - 1), action: { [weak self] in
                self?.login(provider, type: "oauth")
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "With a subscription: its usage shows here. The server signs in; a code to enter or to paste back connects it to this account.", kind: .footer))

        let keys = providers.filter { $0.apiKeyName != nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        items.append(SettingsTextItem(theme: theme, text: "API Key", kind: .header))
        for (index, provider) in keys.enumerated() {
            let keyName = provider.apiKeyName ?? ""
            // "Anthropic API key" says nothing more than "Anthropic"; "AWS credentials or bearer token" does.
            let subtitle = keyName.hasPrefix(provider.name) ? nil : keyName
            items.append(SettingsRowItem(theme: theme, icon: nil, title: provider.name, subtitle: subtitle, accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: index == 0, isLast: index == keys.count - 1), action: { [weak self] in
                self?.login(provider, type: "api_key")
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "Kept on the server, never on this phone.", kind: .footer))
        return items
    }

    private func login(_ provider: ProviderEntry, type: String) {
        self.push(LoginController(context: self.context, slot: self.slot, provider: provider.id, providerName: provider.name, type: type))
    }
}
