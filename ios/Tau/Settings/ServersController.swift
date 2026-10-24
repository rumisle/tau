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
    case .refused:
        return ("Token refused", theme.list.itemDestructiveColor)
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
            items.append(SettingsTextItem(theme: theme, text: "Chats from every server are in one list. Start a server with `npm start` in tau's server/ directory, then add the computer's address, its Tailscale name, and its token (~/.config/tau/token there).", kind: .footer))
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
        let alert = fieldsAlertController(context: self.context.telegram, presentationData: self.theme.presentationData, title: "Add Server", text: "The address of a computer running tau's server, and its token: on that computer, ~/.config/tau/token.", fields: [
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
            items.append(SettingsTextItem(theme: theme, text: "\(info.hostname), pi \(info.piRevision.prefix(7))", kind: .footer))
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
        items.append(SettingsTextItem(theme: theme, text: "Prompt Cache", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.cache, title: "Keep Warm", accessory: .disclosure(label: cacheWarmingTitle(server.cacheWarming)), position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
            guard let self else {
                return
            }
            self.push(CacheWarmingController(context: self.context, slot: self.slot))
        }))
        items.append(SettingsTextItem(theme: theme, text: "The server refreshes a chat's prompt cache before it expires when that costs less than writing it again.", kind: .footer))
        items.append(SettingsTextItem(theme: theme, text: "Context", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.compaction, title: "Auto-Compact", accessory: .disclosure(label: compactionTitle(server.compaction)), position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
            guard let self else {
                return
            }
            self.push(CompactionController(context: self.context, slot: self.slot))
        }))
        items.append(SettingsTextItem(theme: theme, text: "When a chat's context fills up, the model summarizes the older part, and the chat goes on from the summary and the latest messages.", kind: .footer))
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
        let alert = fieldsAlertController(context: self.context.telegram, presentationData: self.theme.presentationData, title: "Address", text: "Where tau's server runs, and its token: on that computer, ~/.config/tau/token. Changing them reconnects.", fields: [
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

func cacheWarmingTitle(_ mode: String) -> String {
    switch mode {
    case "off":
        return "Off"
    case "streaming":
        return "While Working"
    default:
        return "Also When Idle"
    }
}

func compactionTitle(_ threshold: CompactionThreshold) -> String {
    return threshold.enabled ? "At \(Int((threshold.ratio * 100.0).rounded()))%" : "Off"
}

private func tokensTitle(_ tokens: Int) -> String {
    if tokens >= 1_000_000 && tokens % 1_000_000 == 0 {
        return "\(tokens / 1_000_000)M tokens"
    }
    return "\(tokens / 1000)K tokens"
}

/// Settings > a server > Auto-Compact: when the server compacts its chats, as a share of the model's window with a cap
/// for the largest windows.
final class CompactionController: SettingsListController {
    private let slot: Int
    private static let ratios: [Double] = [0.5, 0.7, 0.8, 0.9, 0.95]
    private static let caps: [Int] = [200_000, 400_000, 700_000, 1_000_000]

    init(context: AppContext, slot: Int) {
        self.slot = slot
        super.init(context: context, title: "Auto-Compact")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        guard let server = self.context.store.server(self.slot) else {
            return []
        }
        let current = server.compaction
        var items: [ListViewItem] = [SettingsTextItem(theme: theme, text: "Compact At", kind: .header)]
        let ratios = CompactionController.ratios
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Off", accessory: .checkmark(!current.enabled), position: SettingsRowPosition(isFirst: true, isLast: false), action: { [weak self] in
            var updated = current
            updated.enabled = false
            server.setCompaction(updated)
            self?.reload()
        }))
        for (index, ratio) in ratios.enumerated() {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "\(Int((ratio * 100.0).rounded()))% of the Window", accessory: .checkmark(current.enabled && abs(current.ratio - ratio) < 0.001), position: SettingsRowPosition(isFirst: false, isLast: index == ratios.count - 1), action: { [weak self] in
                var updated = current
                updated.enabled = true
                updated.ratio = ratio
                server.setCompaction(updated)
                self?.reload()
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "Off, a chat is compacted only when its context overflows, or when you ask from its menu.", kind: .footer))
        if current.enabled {
            items.append(SettingsTextItem(theme: theme, text: "But No Later Than", kind: .header))
            let caps = CompactionController.caps
            for (index, cap) in caps.enumerated() {
                items.append(SettingsRowItem(theme: theme, icon: nil, title: tokensTitle(cap), accessory: .checkmark(current.maxTokens == cap), position: SettingsRowPosition(isFirst: index == 0, isLast: index == caps.count - 1), action: { [weak self] in
                    var updated = current
                    updated.maxTokens = cap
                    server.setCompaction(updated)
                    self?.reload()
                }))
            }
            items.append(SettingsTextItem(theme: theme, text: "In the largest windows a very long context answers worse and costs more at every step. The summary is asked for after the chat's cached context, so it costs little.", kind: .footer))
        }
        return items
    }
}

/// Settings > a server > Keep Warm: pi's cache warming modes, which the server applies to all its chats.
final class CacheWarmingController: SettingsListController {
    private let slot: Int

    init(context: AppContext, slot: Int) {
        self.slot = slot
        super.init(context: context, title: "Keep Warm")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        guard let server = self.context.store.server(self.slot) else {
            return []
        }
        let modes = ["off", "streaming", "idle"]
        var items: [ListViewItem] = [SettingsTextItem(theme: theme, text: "Prompt Cache", kind: .header)]
        for (index, mode) in modes.enumerated() {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: cacheWarmingTitle(mode), accessory: .checkmark(server.cacheWarming == mode), position: SettingsRowPosition(isFirst: index == 0, isLast: index == modes.count - 1), action: { [weak self] in
                server.setCacheWarming(mode)
                self?.reload()
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "A provider keeps the start of a chat cached for a few minutes, and charges a tenth for it. While an agent works through a long command, the server refreshes it so the next step reads it; when idle too, for half an hour after, if the chance that you write again makes that worth it.", kind: .footer))
        return items
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
