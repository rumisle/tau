import UIKit
import Display
import SwiftSignalKit
import UndoUI

/// Settings > Notifications, after Telegram's: in-app banners while tau is open, and pushes while it is not, which each
/// server sends through Apple's push service with the account's key, or else through ntfy (server/src/notifier.ts).
final class NotificationsController: SettingsListController {
    private var disposable: Disposable?

    init(context: AppContext) {
        super.init(context: context, title: "Notifications")
        self.disposable = (context.store.serversSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reload()
        })
        // The permission, answered or changed in iOS Settings.
        self.pushObserver = NotificationCenter.default.addObserver(forName: PushRegistration.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    private var pushObserver: NSObjectProtocol?

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
        if let observer = self.pushObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
            SettingsTextItem(theme: theme, text: "Live Activity", kind: .header),
            SettingsRowItem(theme: theme, icon: nil, title: "Chats You Wait On", accessory: .toggle(LiveActivityController.isEnabled), position: SettingsRowPosition(isFirst: true, isLast: true), action: nil, toggled: { value in
                LiveActivityController.isEnabled = value
            }),
            SettingsTextItem(theme: theme, text: "A chat you send a message to shows on the Lock Screen and in the Dynamic Island until you see how it ended. Its server updates it while tau is closed; one without Apple push cannot, and it says when it started once it cannot tell more.", kind: .footer),
        ]
        let servers = self.context.store.servers
        guard !self.context.store.isDemo else {
            return items
        }
        items.append(SettingsTextItem(theme: theme, text: "Push Notifications", kind: .header))
        let denied = PushRegistration.shared.authorization == .denied
        var rows: [(title: String, subtitle: String?, on: Bool, toggled: (Bool) -> Void)] = []
        for server in servers {
            let title = servers.count > 1 ? server.name : "Answers"
            if server.canPush {
                rows.append((title, nil, server.pushAlerts && !denied, { [weak self] value in
                    server.setPushAlerts(value)
                    self?.reload()
                }))
            }
            // ntfy, for a server without the APNs key, or one that still has a topic.
            if !server.canPush || server.ntfy != nil {
                let target = server.ntfy
                rows.append((server.canPush ? "\(title) through ntfy" : title, target.map { "ntfy · \($0.topic)" }, target != nil, { [weak self] value in
                    server.setNtfy(value ? NtfyTarget(server: "https://ntfy.sh", topic: NotificationsController.newTopic()) : nil)
                    self?.reload()
                }))
            }
        }
        for (index, row) in rows.enumerated() {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: row.title, subtitle: row.subtitle, accessory: .toggle(row.on), position: SettingsRowPosition(isFirst: index == 0, isLast: index == rows.count - 1 && !denied), action: nil, toggled: row.toggled))
        }
        if denied {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Turn On in Settings", titleColor: theme.accentColor, accessory: .none, position: SettingsRowPosition(isFirst: rows.isEmpty, isLast: true), action: {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }))
        }
        for server in servers {
            if let target = server.ntfy {
                items.append(SettingsRowItem(theme: theme, icon: nil, title: "Subscribe in ntfy", titleColor: theme.accentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: false), action: {
                    if let url = NotificationsController.subscribeURL(target), UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    } else if let store = URL(string: "https://apps.apple.com/app/ntfy/id1625396347") {
                        UIApplication.shared.open(store)
                    }
                }))
                items.append(SettingsRowItem(theme: theme, icon: nil, title: "Copy Topic", titleColor: theme.accentColor, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: true), action: { [weak self] in
                    UIPasteboard.general.string = "\(target.server)/\(target.topic)"
                    guard let self else {
                        return
                    }
                    self.present(UndoOverlayController(presentationData: self.theme.presentationData, content: .copy(text: "Topic copied to clipboard"), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                }))
            }
        }
        let anyApns = servers.contains { $0.canPush }
        let footer: String
        if denied {
            footer = "Notifications are off for tau in iOS Settings."
        } else if anyApns {
            footer = "While tau is closed, each answer arrives as a notification from its chat; reply to it without opening tau. A chat you wait on in the Live Activity says it there instead."
        } else {
            footer = "While tau is closed, the server sends each answer to the ntfy app on this phone; its notification opens the chat. Install ntfy, then subscribe to the topic."
        }
        items.append(SettingsTextItem(theme: theme, text: footer, kind: .footer))
        return items
    }
}
