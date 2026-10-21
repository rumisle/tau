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
        if let server = store.serverInfo {
            let revision = String(server.piRevision.prefix(7))
            items.append(SettingsTextItem(theme: theme, text: "Server", kind: .header))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Computer", accessory: .value(server.hostname), position: first, action: nil))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Address", accessory: .value(server.address), position: middle, action: nil))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "pi", accessory: .disclosure(label: revision.isEmpty ? "—" : revision), position: last, action: revision.isEmpty ? nil : open("https://github.com/earendil-works/pi/commit/\(server.piRevision)")))
            items.append(SettingsTextItem(theme: theme, text: "The server runs pi-durable from pi's main branch at this commit.", kind: .footer))
        }
        items.append(SettingsTextItem(theme: theme, text: "Made With", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Telegram for iOS", subtitle: "Interface · GPL-2.0", accessory: .disclosure(label: ""), position: first, action: open("https://github.com/TelegramMessenger/Telegram-iOS")))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "pi", subtitle: "pi-durable, pi-ai · MIT", accessory: .disclosure(label: ""), position: middle, action: open("https://github.com/earendil-works/pi")))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "SwiftMath", subtitle: "LaTeX · MIT", accessory: .disclosure(label: ""), position: middle, action: open("https://github.com/mgriebling/SwiftMath")))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Prism", subtitle: "Syntax highlighting · MIT", accessory: .disclosure(label: ""), position: last, action: open("https://github.com/PrismJS/prism")))
        items.append(SettingsTextItem(theme: theme, text: "tau's screens are Telegram's own code, so tau is free software under the GNU GPL as well.", kind: .footer))
        return items
    }
}
