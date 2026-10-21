import UIKit
import Display
import SwiftSignalKit
import UndoUI

/// Settings > Notifications, after Telegram's: in-app banners while tau is open, and pushes while it is not, which each
/// server sends through ntfy (server/src/notifier.ts) until tau can use Apple's.
final class NotificationsController: SettingsListController {
    private var disposable: Disposable?

    init(context: AppContext) {
        super.init(context: context, title: "Notifications")
        self.disposable = (context.store.serversSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
    }

    /// A topic no one guesses: whoever knows it can read the pushes.
    private static func newTopic() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyz23456789")
        return "tau-" + String((0 ..< 20).map { _ in alphabet.randomElement()! })
    }

    private static func subscribeURL(_ target: NtfyTarget) -> URL? {
        let host = URL(string: target.server)?.host ?? "ntfy.sh"
        return URL(string: "ntfy://\(host)/\(target.topic)")
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let first = SettingsRowPosition(isFirst: true, isLast: false)
        let last = SettingsRowPosition(isFirst: false, isLast: true)
        var items: [ListViewItem] = [
            SettingsTextItem(theme: theme, text: "In-App Notifications", kind: .header),
            SettingsRowItem(theme: theme, icon: nil, title: "Banners", accessory: .toggle(InAppNotificationSettings.banners), position: first, action: nil, toggled: { value in
                InAppNotificationSettings.banners = value
            }),
            SettingsRowItem(theme: theme, icon: nil, title: "Vibrate", accessory: .toggle(InAppNotificationSettings.vibrate), position: last, action: nil, toggled: { value in
                InAppNotificationSettings.vibrate = value
            }),
            SettingsTextItem(theme: theme, text: "While tau is open, an answer in another chat shows at the top of the screen.", kind: .footer),
        ]
        let servers = self.context.store.servers
        guard !self.context.store.isDemo else {
            return items
        }
        items.append(SettingsTextItem(theme: theme, text: "Push Notifications", kind: .header))
        for (index, server) in servers.enumerated() {
            let target = server.ntfy
            let isLast = index == servers.count - 1 && target == nil
            items.append(SettingsRowItem(theme: theme, icon: nil, title: servers.count > 1 ? server.name : "Answers", subtitle: target.map { "ntfy · \($0.topic)" }, accessory: .toggle(target != nil), position: SettingsRowPosition(isFirst: index == 0, isLast: isLast), action: nil, toggled: { [weak self] value in
                server.setNtfy(value ? NtfyTarget(server: "https://ntfy.sh", topic: NotificationsController.newTopic()) : nil)
                self?.reload()
            }))
            if let target {
                items.append(SettingsRowItem(theme: theme, icon: nil, title: "Subscribe in ntfy", titleColor: theme.accentColor, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: false), action: {
                    if let url = NotificationsController.subscribeURL(target), UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    } else if let store = URL(string: "https://apps.apple.com/app/ntfy/id1625396347") {
                        UIApplication.shared.open(store)
                    }
                }))
                items.append(SettingsRowItem(theme: theme, icon: nil, title: "Copy Topic", titleColor: theme.accentColor, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: index == servers.count - 1), action: { [weak self] in
                    UIPasteboard.general.string = "\(target.server)/\(target.topic)"
                    guard let self else {
                        return
                    }
                    self.present(UndoOverlayController(presentationData: self.theme.presentationData, content: .copy(text: "Topic copied to clipboard"), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                }))
            }
        }
        items.append(SettingsTextItem(theme: theme, text: "While tau is closed, the server sends each answer to the ntfy app on this phone; its notification opens the chat. Install ntfy, then subscribe to the topic.", kind: .footer))
        return items
    }
}
