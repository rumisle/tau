import UIKit
import Display
import SwiftSignalKit
import UndoUI

func formatBytes(_ bytes: Int64) -> String {
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Settings > Data and Storage, after Telegram's DataAndStorageSettingsController: what tau keeps on this phone, and
/// what it sends and receives.
final class DataStorageController: SettingsListController {
    init(context: AppContext) {
        super.init(context: context, title: "Data and Storage")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.reload()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let servers = self.context.store.servers
        let stored = servers.reduce(Int64(0)) { total, server in
            let usage = server.storageUsage()
            return total + usage.cacheBytes + usage.unsentBytes + usage.draftBytes
        }
        let traffic = servers.reduce(Int64(0)) { total, server in
            let counters = NetworkUsage.shared.counters[server.address] ?? NetworkUsage.Counters()
            return total + counters.wifiSent + counters.wifiReceived + counters.cellularSent + counters.cellularReceived
        }
        return [
            SettingsTextItem(theme: theme, text: "Disk and Network Usage", kind: .header),
            SettingsRowItem(theme: theme, icon: SettingsIcon.storage, title: "Storage Usage", accessory: .disclosure(label: formatBytes(stored)), position: SettingsRowPosition(isFirst: true, isLast: false), action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(StorageUsageController(context: self.context))
            }),
            SettingsRowItem(theme: theme, icon: SettingsIcon.network, title: "Network Usage", accessory: .disclosure(label: formatBytes(traffic)), position: SettingsRowPosition(isFirst: false, isLast: true), action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(NetworkUsageController(context: self.context))
            }),
        ]
    }
}

/// Storage Usage, after Telegram's: the total, what it is made of, the chats that take the most, and Clear Cache.
final class StorageUsageController: SettingsListController {
    init(context: AppContext) {
        super.init(context: context, title: "Storage Usage")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let store = self.context.store
        let servers = store.servers
        let usages = servers.map { ($0, $0.storageUsage()) }
        let cache = usages.reduce(Int64(0)) { $0 + $1.1.cacheBytes }
        let unsent = usages.reduce(Int64(0)) { $0 + $1.1.unsentBytes }
        let drafts = usages.reduce(Int64(0)) { $0 + $1.1.draftBytes }
        var items: [ListViewItem] = [
            SettingsTextItem(theme: theme, text: "This iPhone · \(formatBytes(cache + unsent + drafts))", kind: .header),
            SettingsRowItem(theme: theme, icon: nil, title: "Chat History", accessory: .value(formatBytes(cache)), position: SettingsRowPosition(isFirst: true, isLast: false), action: nil),
            SettingsRowItem(theme: theme, icon: nil, title: "Unsent Messages", accessory: .value(formatBytes(unsent)), position: SettingsRowPosition(isFirst: false, isLast: false), action: nil),
            SettingsRowItem(theme: theme, icon: nil, title: "Drafts", accessory: .value(formatBytes(drafts)), position: SettingsRowPosition(isFirst: false, isLast: true), action: nil),
            SettingsTextItem(theme: theme, text: "Chat history is a copy of what the servers keep, so chats open without waiting. Unsent messages and drafts are only here, and stay.", kind: .footer),
        ]
        for (server, usage) in usages where !usage.chats.isEmpty {
            let shown = Array(usage.chats.prefix(8))
            items.append(SettingsTextItem(theme: theme, text: servers.count > 1 ? "Chats on \(server.name)" : "Chats", kind: .header))
            for (index, chat) in shown.enumerated() {
                let title = store.dialog(MultiStore.global(server.slot, chat.id))?.title ?? "Chat \(chat.id)"
                items.append(SettingsRowItem(theme: theme, icon: nil, title: title, accessory: .value(formatBytes(chat.bytes)), position: SettingsRowPosition(isFirst: index == 0, isLast: index == shown.count - 1), action: nil))
            }
        }
        items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Clear Cache · \(formatBytes(cache))", titleColor: cache > 0 ? theme.list.itemDestructiveColor : theme.list.itemSecondaryTextColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: cache > 0 ? { [weak self] in
            self?.confirmClear(bytes: cache)
        } : nil))
        items.append(SettingsTextItem(theme: theme, text: "Chats load again from their server when opened.", kind: .footer))
        return items
    }

    /// Telegram's action sheet before a destructive choice, then its toast.
    private func confirmClear(bytes: Int64) {
        let presentationData = self.theme.presentationData
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: "Clear \(formatBytes(bytes))", color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let self else {
                        return
                    }
                    for server in self.context.store.servers {
                        server.clearCache()
                    }
                    self.reload()
                    self.present(UndoOverlayController(presentationData: self.theme.presentationData, content: .succeed(text: "\(formatBytes(bytes)) cleared", timeout: nil, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
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

/// Network Usage, after Telegram's: sent and received for each server, on Wi-Fi and mobile networks apart.
final class NetworkUsageController: SettingsListController {
    init(context: AppContext) {
        super.init(context: context, title: "Network Usage")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let servers = self.context.store.servers
        var items: [ListViewItem] = []
        for (title, cellular) in [("Mobile", true), ("Wi-Fi", false)] {
            items.append(SettingsTextItem(theme: theme, text: title, kind: .header))
            for (index, server) in servers.enumerated() {
                let counters = NetworkUsage.shared.counters[server.address] ?? NetworkUsage.Counters()
                let sent = cellular ? counters.cellularSent : counters.wifiSent
                let received = cellular ? counters.cellularReceived : counters.wifiReceived
                items.append(SettingsRowItem(theme: theme, icon: nil, title: server.name, subtitle: "Sent \(formatBytes(sent)) · Received \(formatBytes(received))", accessory: .value(formatBytes(sent + received)), position: SettingsRowPosition(isFirst: index == 0, isLast: index == servers.count - 1), action: nil))
            }
        }
        let since = DateFormatter.localizedString(from: NetworkUsage.shared.since, dateStyle: .medium, timeStyle: .short)
        items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Reset Statistics", titleColor: theme.list.itemDestructiveColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
            NetworkUsage.shared.reset()
            self?.reload()
        }))
        items.append(SettingsTextItem(theme: theme, text: "Since \(since).", kind: .footer))
        return items
    }
}
