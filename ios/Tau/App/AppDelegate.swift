import UIKit
import Display
import NavigationBarImpl
import UIKitRuntimeUtils
import SwiftSignalKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private var mainWindow: Window1!
    private var statusBarHost: ApplicationStatusBarHost?
    private var context: AppContext?
    private var themeDisposable: Disposable?
    private var notificationController: NotificationContainerController?
    private let answersDisposable = MetaDisposable()
    private var navigationController: NavigationController?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TauTiming.startFrameMonitor()
        // Display only knows the NavigationBar protocol; the app picks the implementation, as Telegram's AppDelegate does.
        defaultNavigationBarImpl = { presentationData in
            return NavigationBarImpl(presentationData: presentationData)
        }
        installTelegramComponentFactories()

        // Telegram's window stack: a native window hosting Display's Window1, which drives layout (keyboard, status bar,
        // safe areas) for every ViewController as a ContainerViewLayout.
        let (window, hostView) = nativeWindowHostView()
        let statusBarHost = ApplicationStatusBarHost(scene: window.windowScene)
        self.statusBarHost = statusBarHost
        self.mainWindow = Window1(hostView: hostView, statusBarHost: statusBarHost)
        self.window = window

        let themeContext = ThemeContext()
        themeContext.observeSystemStyle(hostView.systemUserInterfaceStyle)
        let context = AppContext(store: makeStore(), themeContext: themeContext)
        self.context = context

        let makeRoot: () -> (RootTabController, ChatListController) = {
            let chatList = ChatListController(context: context)
            let root = RootTabController(context: context, tabs: [
                RootTabController.Tab(id: AnyHashable("chats"), title: "Chats", animation: "TabChats", animationOffset: CGPoint(x: 0.0, y: UIScreenPixel), controller: chatList),
                RootTabController.Tab(id: AnyHashable("settings"), title: "Settings", animation: "TabSettings", animationOffset: CGPoint(), controller: SettingsController(context: context)),
            ])
            return (root, chatList)
        }
        let (root, chatList) = makeRoot()
        let navigationController = NavigationController(mode: .single, theme: context.theme.navigationControllerTheme)
        navigationController.setViewControllers([root], animated: false)
        context.replaceStore = { [weak self] _ in
            let (root, _) = makeRoot()
            navigationController.setViewControllers([root], animated: false)
            root.select(index: 1)
            self?.observeAnswers(context: context)
        }
        self.mainWindow.viewController = navigationController
        self.navigationController = navigationController

        // Telegram's in-app notifications: banners over everything, in the window's top level.
        let notificationController = NotificationContainerController(context: context.telegram)
        self.notificationController = notificationController
        self.mainWindow.topLevelOverlayControllers = [notificationController]
        self.observeAnswers(context: context)

        context.telegramShared.mainWindow = self.mainWindow
        self.themeDisposable = (themeContext.theme |> deliverOnMainQueue).start(next: { theme in
            context.telegramShared.update(presentationData: theme.presentationData)
            hostView.containerView.backgroundColor = theme.chatList.backgroundColor
            navigationController.updateTheme(theme.navigationControllerTheme)
            // System controls (keyboard, menus) follow the theme; with Auto-Night they follow the phone, which drives it.
            window.overrideUserInterfaceStyle = themeContext.settings.autoNight ? .unspecified : (theme.overallDarkAppearance ? .dark : .light)
        })

        window.makeKeyAndVisible()
        self.applyDebugLaunchArguments(context: context, chatList: chatList, root: root, navigationController: navigationController)
        return true
    }

    /// A chat's new answer, as Telegram's ApplicationContext shows a message: not for the chat on screen, a banner for
    /// another while the app is in the foreground; a tap opens the chat.
    private func observeAnswers(context: AppContext) {
        self.answersDisposable.set((context.store.answers |> deliverOnMainQueue).start(next: { [weak self] answer in
            guard let self, UIApplication.shared.applicationState == .active, InAppNotificationSettings.banners else {
                return
            }
            if let chat = self.navigationController?.topViewController as? ChatController, chat.conversationId == answer.conversationId {
                return
            }
            if InAppNotificationSettings.vibrate {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            let item = ChatNotificationItem(conversationId: answer.conversationId, title: answer.title, text: answer.text, theme: context.theme.presentationTheme, tapAction: { [weak self] in
                self?.notificationController?.removeItemsWithGroupingKey(answer.conversationId)
                self?.openChat(answer.conversationId, context: context)
                return false
            })
            self.notificationController?.enqueue(item)
        }))
    }

    /// Opens a chat over whatever is on screen, as Telegram's banner and push taps do.
    private func openChat(_ id: Int, context: AppContext) {
        guard let navigationController = self.navigationController else {
            return
        }
        if let chat = navigationController.topViewController as? ChatController, chat.conversationId == id {
            return
        }
        navigationController.pushViewController(ChatController(context: context, conversationId: id))
    }

    /// `tau://chat?server=<serverId>&id=<conversation>`: what a push opens (server/src/notifier.ts).
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.scheme == "tau", url.host == "chat", let context = self.context, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let local = query["id"].flatMap(Int.init) else {
            return false
        }
        let open = { [weak self] in
            let server = context.store.servers.first { $0.serverInfo?.serverId == query["server"] } ?? context.store.servers.first
            guard let server else {
                return
            }
            self?.openChat(MultiStore.global(server.slot, local), context: context)
        }
        // At launch the servers may not have said who they are yet.
        if context.store.servers.contains(where: { $0.serverInfo?.serverId == query["server"] }) {
            open()
        } else {
            Queue.mainQueue().after(1.5, open)
        }
        return true
    }

    /// For screenshots and UI checks from the command line, e.g.
    /// `xcrun simctl launch booted com.rumisle.tau -openChat 2 -send "hello"`.
    private func applyDebugLaunchArguments(context: AppContext, chatList: ChatListController, root: RootTabController, navigationController: NavigationController) {
        let defaults = UserDefaults.standard
        // -theme classic|day|night|tintedNight (light and dark map to Classic and Tinted Night).
        if let name = defaults.string(forKey: "theme") {
            let aliases: [String: TauTheme.Builtin] = ["light": .classic, "dark": .tintedNight]
            if let builtin = aliases[name] ?? TauTheme.Builtin(rawValue: name) {
                context.themeContext.force(builtin)
            }
        }
        // -wrapCode YES|NO
        if defaults.object(forKey: "wrapCode") != nil {
            let value = defaults.bool(forKey: "wrapCode")
            context.themeContext.update { $0.wrapCode = value }
        }
        if defaults.object(forKey: "tab") != nil {
            Queue.mainQueue().after(0.3) {
                root.select(index: defaults.integer(forKey: "tab"))
            }
        }
        if defaults.object(forKey: "sendTo") != nil, let text = defaults.string(forKey: "send") {
            let conversationId = defaults.integer(forKey: "sendTo")
            Queue.mainQueue().after(1.0) {
                context.store.send(text, to: conversationId)
            }
        }
        if defaults.bool(forKey: "compose") {
            Queue.mainQueue().after(1.0) {
                chatList.compose()
            }
        }
        if defaults.object(forKey: "scrollTo") != nil, defaults.object(forKey: "openChat") != nil {
            context.store.setScrollState(ChatScrollState(messageId: defaults.integer(forKey: "scrollTo"), offset: 0.0), for: defaults.integer(forKey: "openChat"))
        }
        // -pushChat N: open a chat from the list with the push animation, as a tap does.
        if defaults.object(forKey: "pushChat") != nil {
            let id = defaults.integer(forKey: "pushChat")
            Queue.mainQueue().after(1.0) {
                chatList.open(conversationId: id)
            }
        }
        // -newChat YES: a fresh draft chat in the server's default directory, as New Chat makes.
        let isNewChat = defaults.bool(forKey: "newChat")
        guard defaults.object(forKey: "openChat") != nil || isNewChat else {
            return
        }
        let conversationId = isNewChat ? context.store.createConversation(server: context.store.servers.first?.slot ?? 0, cwd: nil) : defaults.integer(forKey: "openChat")
        if isNewChat {
            // A test's fresh chat: not what an earlier one left written.
            context.store.setInputDraft(nil, for: conversationId)
        }
        let chat = ChatController(context: context, conversationId: conversationId)
        navigationController.pushViewController(chat, animated: false)
        if let draft = defaults.string(forKey: "draft") {
            Queue.mainQueue().after(0.6) {
                chat.setDraft(draft)
            }
        }
        if defaults.bool(forKey: "focus") {
            Queue.mainQueue().after(0.5) {
                chat.activateInput()
            }
        }
        if let text = defaults.string(forKey: "send"), defaults.object(forKey: "sendTo") == nil {
            Queue.mainQueue().after(1.0) {
                context.store.send(text, to: conversationId)
            }
        }
    }
}

// Copied from Telegram-iOS TelegramUI/Sources/AppDelegate.swift: lets Window1 find the keyboard for interactive dismissal.

private func isKeyboardWindow(window: NSObject) -> Bool {
    let typeName = NSStringFromClass(type(of: window))
    return typeName.hasPrefix("UI") && typeName.hasSuffix("RemoteKeyboardWindow")
}

private func isKeyboardView(view: NSObject) -> Bool {
    let typeName = NSStringFromClass(type(of: view))
    if typeName.hasPrefix("UI") && typeName.hasSuffix("InputSetHostView") {
        return true
    }
    if typeName.hasPrefix("UI") && typeName.hasSuffix("KeyboardItemContainerView") {
        return true
    }
    return false
}

private func isKeyboardViewContainer(view: NSObject) -> Bool {
    let typeName = NSStringFromClass(type(of: view))
    if typeName.hasPrefix("UI") && typeName.hasSuffix("InputSetContainerView") {
        return true
    }
    if typeName.hasPrefix("UI") && typeName.hasSuffix("TrackingWindowView") {
        return true
    }
    return false
}

private final class ApplicationStatusBarHost: StatusBarHost {
    weak var scene: UIWindowScene?

    init(scene: UIWindowScene?) {
        self.scene = scene
    }

    var isApplicationInForeground: Bool {
        guard let scene = self.scene else {
            return false
        }
        switch scene.activationState {
        case .foregroundActive, .foregroundInactive:
            return true
        default:
            return false
        }
    }

    var statusBarFrame: CGRect {
        return self.scene?.statusBarManager?.statusBarFrame ?? CGRect()
    }

    var keyboardWindow: UIWindow? {
        if let window = UIApplication.shared.internalGetKeyboard(for: self.scene) {
            return window
        }
        for window in UIApplication.shared.allWindowSceneWindows {
            if isKeyboardWindow(window: window) {
                return window
            }
        }
        return nil
    }

    var keyboardView: UIView? {
        guard let keyboardWindow = self.keyboardWindow else {
            return nil
        }
        for view in keyboardWindow.subviews {
            if isKeyboardViewContainer(view: view) {
                for subview in view.subviews {
                    if isKeyboardView(view: subview) {
                        return subview
                    }
                }
            }
        }
        return nil
    }
}

/// The server unless Settings names another: the Mac's tau server, by its tailnet name.
let defaultServerURL = "ws://nest.example.ts.net:7878"

/// The server from Settings, or canned data with `-mock YES` (UI tests and screenshots).
func makeStore() -> TauStore {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: "mock") {
        return MockStore()
    }
    return MultiStore(configs: ServerConfigStorage.load())
}

/// Settings > Notifications > In-App: Telegram's InAppNotificationSettings, in UserDefaults.
enum InAppNotificationSettings {
    static var banners: Bool {
        get { UserDefaults.standard.object(forKey: "notifications.banners") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifications.banners") }
    }

    static var vibrate: Bool {
        get { UserDefaults.standard.object(forKey: "notifications.vibrate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifications.vibrate") }
    }
}
