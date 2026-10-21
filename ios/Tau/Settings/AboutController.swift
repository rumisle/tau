import UIKit
import Display
import SwiftSignalKit

/// Settings > About tau: the app's version, what the server runs, and the projects tau is made of, as Telegram's
/// settings lists show them.
final class AboutController: SettingsListController {
    init(context: AppContext) {
        super.init(context: context, title: "About tau")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let store = self.context.store
        let first = SettingsRowPosition(isFirst: true, isLast: false)
        let middle = SettingsRowPosition(isFirst: false, isLast: false)
        let last = SettingsRowPosition(isFirst: false, isLast: true)
        let open: (String) -> () -> Void = { address in
            return {
                if let url = URL(string: address) {
                    UIApplication.shared.open(url)
                }
            }
        }

        var items: [ListViewItem] = [
            SettingsProfileItem(theme: theme, title: "tau", subtitle: "Version \(version) (\(build))"),
        ]
        let servers = store.servers.filter { $0.serverInfo != nil }
        if !servers.isEmpty {
            items.append(SettingsTextItem(theme: theme, text: servers.count == 1 ? "Server" : "Servers", kind: .header))
            for (index, server) in servers.enumerated() {
                guard let info = server.serverInfo else {
                    continue
                }
                let revision = String(info.piRevision.prefix(7))
                items.append(SettingsRowItem(theme: theme, icon: nil, title: server.name, subtitle: "\(info.hostname) · pi \(revision.isEmpty ? "—" : revision)", accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: index == 0, isLast: index == servers.count - 1), action: revision.isEmpty ? nil : open("https://github.com/earendil-works/pi/tree/\(info.piRevision)")))
            }
            items.append(SettingsTextItem(theme: theme, text: "Servers run pi-durable from pi's main branch at these commits.", kind: .footer))
        }
        items.append(SettingsTextItem(theme: theme, text: "Made With", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Telegram for iOS", subtitle: "Interface", accessory: .disclosure(label: ""), position: first, action: open("https://github.com/TelegramMessenger/Telegram-iOS")))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "pi", subtitle: "pi-durable, pi-ai", accessory: .disclosure(label: ""), position: middle, action: open("https://github.com/earendil-works/pi")))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "SwiftMath", subtitle: "LaTeX", accessory: .disclosure(label: ""), position: middle, action: open("https://github.com/mgriebling/SwiftMath")))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Prism", subtitle: "Syntax highlighting", accessory: .disclosure(label: ""), position: last, action: open("https://github.com/PrismJS/prism")))
        return items
    }
}
