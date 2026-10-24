import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import UndoUI

/// A grouped list screen, like Telegram's ItemListController: it rebuilds its rows from `items(theme)` whenever the
/// theme or its own state changes.
class SettingsListController: ViewController {
    let context: AppContext
    private(set) var theme: TauTheme
    private var themeDisposable: Disposable?

    private var listNode: SettingsListNode {
        return self.displayNode as! SettingsListNode
    }

    init(context: AppContext, title: String) {
        self.context = context
        self.theme = context.theme
        super.init(navigationBarPresentationData: context.theme.navigationBarPresentationData(edgeEffectColor: context.theme.list.blocksBackgroundColor))
        self.title = title
        self.statusBar.statusBarStyle = self.theme.statusBarStyleValue
        self.themeDisposable = (context.themeContext.theme |> deliverOnMainQueue).start(next: { [weak self] theme in
            guard let self, theme !== self.theme else {
                return
            }
            self.theme = theme
            self.statusBar.statusBarStyle = theme.statusBarStyleValue
            self.navigationBar?.updatePresentationData(theme.navigationBarPresentationData(edgeEffectColor: theme.list.blocksBackgroundColor), transition: .immediate)
            if self.isNodeLoaded {
                self.listNode.backgroundColor = theme.list.blocksBackgroundColor
            }
            self.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.themeDisposable?.dispose()
    }

    /// The rows, top to bottom.
    func items(theme: TauTheme) -> [ListViewItem] {
        return []
    }

    func reload() {
        guard self.isNodeLoaded else {
            return
        }
        self.listNode.setItems(self.items(theme: self.theme))
    }

    override func loadDisplayNode() {
        self.displayNode = SettingsListNode(backgroundColor: self.theme.list.blocksBackgroundColor)
        self.displayNodeDidLoad()
        self.reload()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.listNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
}

final class SettingsListNode: ASDisplayNode {
    private let listNode = ListViewImpl()
    private var itemCount = 0
    private var pendingItems: [ListViewItem]?
    private var hasLayout = false

    init(backgroundColor: UIColor) {
        super.init()
        self.backgroundColor = backgroundColor
        self.addSubnode(self.listNode)
    }

    func setItems(_ items: [ListViewItem]) {
        guard self.hasLayout else {
            self.pendingItems = items
            return
        }
        // Rows keep their positions, so replace them in place; a different row count rebuilds the list.
        if items.count == self.itemCount {
            let updates = items.enumerated().map { ListViewUpdateItem(index: $0.offset, previousIndex: $0.offset, item: $0.element, directionHint: nil) }
            self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: updates, options: [.Synchronous], updateOpaqueState: nil)
        } else {
            let deletions = (0 ..< self.itemCount).map { ListViewDeleteItem(index: $0, directionHint: nil) }
            let insertions = items.enumerated().map { ListViewInsertItem(index: $0.offset, previousIndex: nil, item: $0.element, directionHint: nil) }
            self.listNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], updateOpaqueState: nil)
        }
        self.itemCount = items.count
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        let insets = UIEdgeInsets(top: navigationHeight, left: layout.safeInsets.left, bottom: layout.intrinsicInsets.bottom + 16.0, right: layout.safeInsets.right)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil)
        if !self.hasLayout {
            self.hasLayout = true
            if let items = self.pendingItems {
                self.pendingItems = nil
                self.setItems(items)
            }
        }
    }
}

/// Settings, laid out like Telegram's: a profile header, then grouped rows with colored icons.
final class SettingsController: SettingsListController {
    private var modeDisposable: Disposable?
    private var statusDisposable: Disposable?
    private var status: ConnectionStatus = .connecting

    init(context: AppContext) {
        super.init(context: context, title: "Settings")
        self.modeDisposable = (context.themeContext.settingsSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reload()
        })
        self.statusDisposable = (context.store.connectionStatus |> deliverOnMainQueue).start(next: { [weak self] status in
            self?.status = status
            self?.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.modeDisposable?.dispose()
        self.statusDisposable?.dispose()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The default model may have changed in its screen.
        self.reload()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let context = self.context
        let store = context.store
        let first = SettingsRowPosition(isFirst: true, isLast: false)
        let middle = SettingsRowPosition(isFirst: false, isLast: false)
        let last = SettingsRowPosition(isFirst: false, isLast: true)
        let single = SettingsRowPosition(isFirst: true, isLast: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let strings = theme.presentationStrings
        let statusText: String
        switch self.status {
        case .online:
            statusText = "online"
        case .updating:
            statusText = strings.ChatState_Updating
        case .connecting, .refused:
            statusText = strings.ChatState_Connecting
        case .waitingForNetwork:
            statusText = strings.ChatState_WaitingForNetwork
        }
        let servers = store.servers
        let serversLabel = store.isDemo ? "Demo" : (servers.count == 1 ? servers[0].name : "\(servers.count)")
        let subtitle: String
        if store.isDemo {
            subtitle = "Demo data"
        } else if servers.count == 1 {
            subtitle = "\(servers[0].name), \(statusText.lowercased())"
        } else {
            subtitle = "\(servers.count) servers, \(statusText.lowercased())"
        }
        return [
            SettingsProfileItem(theme: theme, title: "tau", subtitle: subtitle),
            SettingsTextItem(theme: theme, text: "", kind: .header),
            SettingsRowItem(theme: theme, icon: SettingsIcon.server, title: "Servers", accessory: .disclosure(label: serversLabel), position: single, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(ServersController(context: self.context))
            }),
            SettingsTextItem(theme: theme, text: "Preferences", kind: .header),
            SettingsRowItem(theme: theme, icon: SettingsIcon.appearance, title: "Appearance", accessory: .disclosure(label: context.themeContext.settings.theme.title), position: first, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(AppearanceController(context: self.context))
            }),
            SettingsRowItem(theme: theme, icon: SettingsIcon.notifications, title: "Notifications", accessory: .disclosure(label: store.servers.contains(where: { $0.canPush && $0.pushAlerts }) && PushRegistration.shared.authorization != .denied ? "On" : ""), position: middle, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(NotificationsController(context: self.context))
            }),
            SettingsRowItem(theme: theme, icon: SettingsIcon.dictation, title: "Dictation", accessory: .disclosure(label: DictationSettings.provider?.title ?? "Off"), position: middle, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(DictationController(context: self.context))
            }),
            SettingsRowItem(theme: theme, icon: SettingsIcon.chatFolders, title: "Chat Folders", accessory: .disclosure(label: ChatFolderStore.shared.folders.isEmpty ? "" : "\(ChatFolderStore.shared.folders.count)"), position: middle, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(ChatFoldersController(context: self.context))
            }),
            SettingsRowItem(theme: theme, icon: SettingsIcon.usage, title: "Usage", accessory: .disclosure(label: ""), position: middle, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(UsageController(context: self.context))
            }),
            SettingsRowItem(theme: theme, icon: SettingsIcon.data, title: "Data and Storage", accessory: .disclosure(label: ""), position: last, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(DataStorageController(context: self.context))
            }),
            SettingsTextItem(theme: theme, text: "", kind: .header),
            SettingsRowItem(theme: theme, icon: SettingsIcon.about, title: "About tau", accessory: .disclosure(label: version), position: single, action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(AboutController(context: self.context))
            }),
        ]
    }

}

final class AppearanceController: SettingsListController {
    private var modeDisposable: Disposable?

    init(context: AppContext) {
        super.init(context: context, title: "Appearance")
        self.modeDisposable = (context.themeContext.settingsSignal |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.modeDisposable?.dispose()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let themeContext = self.context.themeContext
        let settings = themeContext.settings
        let themes = TauTheme.Builtin.allCases
        var items: [ListViewItem] = [SettingsTextItem(theme: theme, text: "Color Theme", kind: .header)]
        for (index, builtin) in themes.enumerated() {
            let position = SettingsRowPosition(isFirst: index == 0, isLast: index == themes.count - 1)
            items.append(SettingsRowItem(theme: theme, icon: nil, title: builtin.title, accessory: .checkmark(settings.theme == builtin), position: position, action: {
                themeContext.update { $0.theme = builtin }
            }))
        }
        // The accent of the theme on screen, which may be the night theme: each theme keeps its own, as in Telegram.
        let shown = themeContext.current.builtin
        let accents = TauTheme.Accent.available(for: shown)
        items.append(SettingsTextItem(theme: theme, text: "Accent Color", kind: .header))
        items.append(SettingsAccentColorsItem(theme: theme, colors: accents.map { (id: $0.rawValue, color: UIColor(rgb: $0.rgb(for: shown))) }, selected: settings.accent(for: shown).rawValue, select: { id in
            guard let accent = TauTheme.Accent(rawValue: id) else {
                return
            }
            themeContext.update { $0.accents[shown] = accent }
        }))
        items.append(SettingsTextItem(theme: theme, text: "For \(shown.title).", kind: .footer))
        items.append(SettingsTextItem(theme: theme, text: "Auto-Night Mode", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Disabled", accessory: .checkmark(!settings.autoNight), position: SettingsRowPosition(isFirst: true, isLast: false), action: {
            themeContext.update { $0.autoNight = false }
        }))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "System", accessory: .checkmark(settings.autoNight), position: SettingsRowPosition(isFirst: false, isLast: true), action: {
            themeContext.update { $0.autoNight = true }
        }))
        if settings.autoNight {
            items.append(SettingsTextItem(theme: theme, text: "Preferred Theme", kind: .header))
            let nightThemes = themes.filter(\.isDark)
            for (index, builtin) in nightThemes.enumerated() {
                let position = SettingsRowPosition(isFirst: index == 0, isLast: index == nightThemes.count - 1)
                items.append(SettingsRowItem(theme: theme, icon: nil, title: builtin.title, accessory: .checkmark(settings.nightTheme == builtin), position: position, action: {
                    themeContext.update { $0.nightTheme = builtin }
                }))
            }
            items.append(SettingsTextItem(theme: theme, text: "Switches to the preferred night theme while your iPhone is in dark mode.", kind: .footer))
        }
        items.append(SettingsTextItem(theme: theme, text: "Code Blocks", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Wrap Lines", accessory: .toggle(settings.wrapCode), position: SettingsRowPosition(isFirst: true, isLast: true), action: nil, toggled: { value in
            themeContext.update { $0.wrapCode = value }
        }))
        items.append(SettingsTextItem(theme: theme, text: "When off, long lines stay whole and a code block scrolls sideways.", kind: .footer))
        items.append(SettingsTextItem(theme: theme, text: "Server Tags", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Beside the Time", accessory: .checkmark(settings.serverTags == .besideTime), position: SettingsRowPosition(isFirst: true, isLast: false), action: {
            themeContext.update { $0.serverTags = .besideTime }
        }))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Under the Message", accessory: .checkmark(settings.serverTags == .underMessage), position: SettingsRowPosition(isFirst: false, isLast: true), action: {
            themeContext.update { $0.serverTags = .underMessage }
        }))
        items.append(SettingsTextItem(theme: theme, text: "With more than one server, each chat in the list says which it is on.", kind: .footer))
        return items
    }
}

/// Settings > Dictation: who turns speech into text, if anyone (off until the user picks one), and what that provider
/// needs: for Aqua Voice, the session key of the user's account, a command for a Mac that copies it, its language and
/// its model.
final class DictationController: SettingsListController {
    private var observer: NSObjectProtocol?

    init(context: AppContext) {
        super.init(context: context, title: "Dictation")
        self.observer = NotificationCenter.default.addObserver(forName: DictationSettings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let provider = DictationSettings.provider
        var items: [ListViewItem] = [SettingsTextItem(theme: theme, text: "Provider", kind: .header)]
        let choices: [DictationProvider?] = [nil] + DictationProvider.allCases.map { $0 }
        for (index, choice) in choices.enumerated() {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: choice?.title ?? "Off", accessory: .checkmark(choice == provider), position: SettingsRowPosition(isFirst: index == 0, isLast: index == choices.count - 1), action: {
                DictationSettings.provider = choice
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: provider == nil ? "Turn a provider on for a microphone in the message field that writes what you say." : "The microphone in the message field writes what you say: tap it to start and stop, or hold it while you speak.", kind: .footer))
        guard provider == .aqua else {
            return items
        }

        items.append(SettingsTextItem(theme: theme, text: "Aqua Voice", kind: .header))
        let stored = AquaSessionKey.stored
        let keyLabel: String
        if let stored, let expiry = AquaSessionKey.expiry(of: stored) {
            if expiry > Date() {
                keyLabel = "Until \(expiry.formatted(date: .abbreviated, time: .omitted))"
            } else {
                keyLabel = "Expired"
            }
        } else {
            keyLabel = "Not Set"
        }
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Session Key", accessory: .disclosure(label: keyLabel), position: SettingsRowPosition(isFirst: true, isLast: false), action: { [weak self] in
            self?.editKey()
        }))
        items.append(SettingsRowItem(theme: theme, icon: nil, title: "Copy Command for Mac", titleColor: theme.accentColor, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: stored == nil), action: { [weak self] in
            UIPasteboard.general.string = AquaSessionKey.macCommand
            guard let self else {
                return
            }
            self.present(UndoOverlayController(presentationData: self.theme.presentationData, content: .copy(text: "Command copied. Run it in Terminal on a Mac signed in to Aqua Voice, then paste the key here."), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
        }))
        if stored != nil {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Remove Key", titleColor: theme.list.itemDestructiveColor, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: true), action: {
                AquaSessionKey.remove()
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "Aqua Voice has no API keys: tau listens with the session of your own Aqua account. On a Mac where the Aqua Voice app is signed in, run the command in Terminal: it copies the key, and Universal Clipboard brings it to this iPhone. The key stays in this iPhone's keychain.", kind: .footer))

        items.append(SettingsTextItem(theme: theme, text: "Language", kind: .header))
        let language = AquaSettings.language
        let languages = AquaSettings.languages
        for (index, option) in languages.enumerated() {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: option.title, subtitle: option.subtitle, accessory: .checkmark(option.id == language), position: SettingsRowPosition(isFirst: index == 0, isLast: index == languages.count - 1), action: { [weak self] in
                AquaSettings.language = option.id
                self?.reload()
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "Auto-Detect can take a few words for another language. For one you mostly speak, choose it.", kind: .footer))
        items.append(SettingsTextItem(theme: theme, text: "Model", kind: .header))
        let model = AquaSettings.model
        let models = AquaSettings.models
        for (index, option) in models.enumerated() {
            items.append(SettingsRowItem(theme: theme, icon: nil, title: option.title, subtitle: option.subtitle, accessory: .checkmark(option.id == model), position: SettingsRowPosition(isFirst: index == 0, isLast: index == models.count - 1), action: { [weak self] in
                AquaSettings.model = option.id
                self?.reload()
            }))
        }
        return items
    }

    /// Telegram's alert with a field: the key pasted in, checked before it is kept.
    private func editKey() {
        let alert = fieldsAlertController(context: self.context.telegram, presentationData: self.theme.presentationData, title: "Session Key", text: "Paste the key the command copied on your Mac.", fields: [
            AlertField(placeholder: "eyJ…", value: nil, isSecure: true, isVerbatim: true),
        ], apply: { values in
            return AquaSessionKey.set(values[0])
        })
        self.present(alert, in: .window(.root))
    }
}
