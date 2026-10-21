import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData

/// What a server's row says about its connection, as Telegram's proxy list does: "Connected, ping 42 ms" in the
/// accent color, else what it is doing, in gray.
func serverStatusText(_ server: TauServer, theme: TauTheme) -> (text: String, color: UIColor) {
    switch server.status {
    case .online:
        let ping = server.latency.map { ", ping \(max(1, Int(($0 * 1000.0).rounded()))) ms" } ?? ""
        return ("Connected" + ping, theme.accentColor)
    case .updating:
        return ("Updating…", theme.list.itemSecondaryTextColor)
    case .connecting:
        return ("Connecting…", theme.list.itemSecondaryTextColor)
    case .waitingForNetwork:
        return ("Waiting for network", theme.list.itemSecondaryTextColor)
    }
}

/// Telegram's plus glyph for "Add Proxy" rows (ProxySettingsActionItem), in the accent color.
private func addIcon(_ theme: TauTheme) -> UIImage? {
    return generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setStrokeColor(theme.accentColor.cgColor)
        context.setLineWidth(2.0)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 15.0, y: 7.0))
        context.addLine(to: CGPoint(x: 15.0, y: 23.0))
        context.move(to: CGPoint(x: 7.0, y: 15.0))
        context.addLine(to: CGPoint(x: 23.0, y: 15.0))
        context.strokePath()
    })
}

/// The address a field holds, as the app connects to it: a bare host gets ws:// and the default port.
func normalizedServerAddress(_ text: String) -> String? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
        return nil
    }
    if !text.contains("://") {
        text = "ws://" + text
    }
    guard var components = URLComponents(string: text), let scheme = components.scheme, scheme == "ws" || scheme == "wss", let host = components.host, !host.isEmpty else {
        return nil
    }
    if components.port == nil && scheme == "ws" {
        components.port = 7878
    }
    return components.string
}

/// Settings > Servers, after Telegram's proxy list (ProxyListSettingsController): Add Server first, then every server
/// with what its connection is doing; a server opens its own page.
final class ServersController: SettingsListController {
    private var disposable: Disposable?
    private var timer: SwiftSignalKit.Timer?

    init(context: AppContext) {
        super.init(context: context, title: "Servers")
        self.disposable = (context.store.serversSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
        self.timer?.invalidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.reload()
        // Statuses and pings change without a server changing.
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
            self?.reload()
        }, queue: Queue.mainQueue())
        self.timer = timer
        timer.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.timer?.invalidate()
        self.timer = nil
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let store = self.context.store
        let servers = store.servers
        var items: [ListViewItem] = [SettingsTextItem(theme: theme, text: "Servers", kind: .header)]
        if !store.isDemo {
            items.append(SettingsRowItem(theme: theme, icon: addIcon(theme), title: "Add Server", titleColor: theme.accentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: servers.isEmpty), action: { [weak self] in
                self?.addServer()
            }))
            for (index, server) in servers.enumerated() {
                let status = serverStatusText(server, theme: theme)
                items.append(SettingsRowItem(theme: theme, icon: nil, title: server.name, subtitle: status.text, subtitleColor: status.color, accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: false, isLast: index == servers.count - 1), action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.push(ServerController(context: self.context, slot: server.slot))
                }))
            }
            items.append(SettingsTextItem(theme: theme, text: "Chats from every server are in one list. Start a server with `npm start` in tau's server/ directory, then add the computer's address: its Tailscale name, or ws://192.168.1.10:7878 on the same network.", kind: .footer))
        }
        items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: store.isDemo ? "Use Servers" : "Use Demo Data", titleColor: theme.accentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
            guard let self else {
                return
            }
            UserDefaults.standard.set(!store.isDemo, forKey: "mock")
            self.context.store.close()
            self.context.setStore(makeStore())
        }))
        return items
    }

    /// Telegram's alert with fields: the help on what to enter, then the address and the token.
    private func addServer() {
        let alert = fieldsAlertController(context: self.context.telegram, presentationData: self.theme.presentationData, title: "Add Server", text: "The address of a computer running tau's server, and its TAU_TOKEN if it has one.", fields: [
            AlertField(placeholder: "nest.example.ts.net:7878", value: nil, keyboardType: .URL, isVerbatim: true),
            AlertField(placeholder: "Token (optional)", value: nil, isSecure: true, isVerbatim: true),
        ], doneTitle: "Add", apply: { [weak self] values in
            guard let self, let address = normalizedServerAddress(values[0]) else {
                return false
            }
            self.context.store.addServer(address: address, token: values[1].isEmpty ? nil : values[1], name: nil)
            return true
        })
        self.present(alert, in: .window(.root))
    }
}

/// One server, after Telegram's proxy server screen: its connection, what it keeps for new chats, and Delete.
final class ServerController: SettingsListController {
    private let slot: Int
    private var disposable: Disposable?
    private var timer: SwiftSignalKit.Timer?

    init(context: AppContext, slot: Int) {
        self.slot = slot
        super.init(context: context, title: context.store.server(slot)?.name ?? "Server")
        self.disposable = (context.store.serversSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self else {
                return
            }
            if let server = self.context.store.server(self.slot) {
                self.title = server.name
            }
            self.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
        self.timer?.invalidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.reload()
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
            self?.reload()
        }, queue: Queue.mainQueue())
        self.timer = timer
        timer.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.timer?.invalidate()
        self.timer = nil
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        guard let server = self.context.store.server(self.slot) else {
            return []
        }
        let store = self.context.store
        let first = SettingsRowPosition(isFirst: true, isLast: false)
        let middle = SettingsRowPosition(isFirst: false, isLast: false)
        let last = SettingsRowPosition(isFirst: false, isLast: true)
        let status = serverStatusText(server, theme: theme)
        var items: [ListViewItem] = [
            SettingsTextItem(theme: theme, text: "Connection", kind: .header),
            SettingsRowItem(theme: theme, icon: nil, title: "Status", accessory: .value(status.text), position: first, action: nil),
            SettingsRowItem(theme: theme, icon: nil, title: "Name", accessory: .disclosure(label: server.name), position: middle, action: { [weak self] in
                self?.editName()
            }),
            SettingsRowItem(theme: theme, icon: nil, title: "Address", accessory: .disclosure(label: server.address.replacingOccurrences(of: "ws://", with: "")), position: middle, action: { [weak self] in
                self?.editAddress()
            }),
            SettingsRowItem(theme: theme, icon: nil, title: "Token", accessory: .disclosure(label: store.serverToken(self.slot) == nil ? "None" : "Set"), position: last, action: { [weak self] in
                self?.editAddress()
            }),
        ]
        if let info = server.serverInfo {
            items.append(SettingsTextItem(theme: theme, text: "\(info.hostname) · pi \(info.piRevision.prefix(7))", kind: .footer))
        }
        let thinking = server.defaultThinkingLevel
        items.append(SettingsTextItem(theme: theme, text: "New Chats", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.model, title: "Default Model", accessory: .disclosure(label: server.defaultModel?.components(separatedBy: "/").last ?? "—"), position: first, action: { [weak self] in
            guard let self else {
                return
            }
            let picker = ModelPickerController(context: self.context, server: server, title: "Default Model", current: server.defaultModel, select: { [weak self] model in
                server.setDefaultModel(model)
                self?.reload()
            })
            (self.navigationController as? NavigationController)?.pushViewController(picker)
        }))
        items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.thinking, title: "Default Thinking", accessory: .disclosure(label: thinkingTitle(thinking)), position: last, action: { [weak self] in
            guard let self else {
                return
            }
            self.push(ThinkingLevelController(context: self.context, slot: self.slot))
        }))
        items.append(SettingsTextItem(theme: theme, text: "New chats use this model.", kind: .footer))
        if store.servers.count > 1 {
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Delete Server", titleColor: theme.list.itemDestructiveColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
                self?.confirmDelete()
            }))
        }
        return items
    }

    private func editName() {
        guard let server = self.context.store.server(self.slot) else {
            return
        }
        let store = self.context.store
        let slot = self.slot
        let alert = fieldsAlertController(context: self.context.telegram, presentationData: self.theme.presentationData, title: "Server Name", text: "What the app calls this server. Empty for the computer's name.", fields: [
            AlertField(placeholder: server.serverInfo?.hostname ?? "Name", value: server.name),
        ], apply: { values in
            store.updateServer(slot, address: server.address, token: store.serverToken(slot), name: values[0].isEmpty ? nil : values[0])
            return true
        })
        self.present(alert, in: .window(.root))
    }

    private func editAddress() {
        guard let server = self.context.store.server(self.slot) else {
            return
        }
        let store = self.context.store
        let slot = self.slot
        let name = (server as? ServerStore)?.configuredName
        let alert = fieldsAlertController(context: self.context.telegram, presentationData: self.theme.presentationData, title: "Address", text: "Where tau's server runs, and its TAU_TOKEN if it has one. Changing them reconnects.", fields: [
            AlertField(placeholder: "nest.example.ts.net:7878", value: server.address, keyboardType: .URL, isVerbatim: true),
            AlertField(placeholder: "Token (optional)", value: store.serverToken(slot), isSecure: true, isVerbatim: true),
        ], apply: { values in
            guard let address = normalizedServerAddress(values[0]) else {
                return false
            }
            store.updateServer(slot, address: address, token: values[1].isEmpty ? nil : values[1], name: name)
            return true
        })
        self.present(alert, in: .window(.root))
    }

    /// Telegram's action sheet for a destructive choice.
    private func confirmDelete() {
        guard let server = self.context.store.server(self.slot) else {
            return
        }
        let store = self.context.store
        let slot = self.slot
        let presentationData = self.theme.presentationData
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: "\(server.name)'s chats leave this app; they stay on the server."),
                ActionSheetButtonItem(title: "Delete Server", color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    store.removeServer(slot)
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

func thinkingTitle(_ level: String) -> String {
    switch level {
    case "xhigh":
        return "Extra High"
    default:
        return level.capitalized
    }
}

/// Settings > a server > Default Thinking: pi's levels; the server fits the one picked to each new chat's model.
final class ThinkingLevelController: SettingsListController {
    private let slot: Int

    init(context: AppContext, slot: Int) {
        self.slot = slot
        super.init(context: context, title: "Default Thinking")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        guard let server = self.context.store.server(self.slot) else {
            return []
        }
        let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        var items: [ListViewItem] = [SettingsTextItem(theme: theme, text: "Thinking Level", kind: .header)]
        for (index, level) in levels.enumerated() {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: thinkingTitle(level), accessory: .checkmark(server.defaultThinkingLevel == level), position: SettingsRowPosition(isFirst: index == 0, isLast: index == levels.count - 1), action: { [weak self] in
                server.setDefaultThinkingLevel(level)
                self?.reload()
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "New chats think this much, or as near as their model can.", kind: .footer))
        return items
    }
}
