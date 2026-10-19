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

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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
        context.replaceStore = { _ in
            let (root, _) = makeRoot()
            navigationController.setViewControllers([root], animated: false)
            root.select(index: 1)
        }
        self.mainWindow.viewController = navigationController

        self.themeDisposable = (themeContext.theme |> deliverOnMainQueue).start(next: { theme in
            hostView.containerView.backgroundColor = theme.chatList.backgroundColor
            navigationController.updateTheme(theme.navigationControllerTheme)
            // System controls (keyboard, menus) follow the theme; with Auto-Night they follow the phone, which drives it.
            window.overrideUserInterfaceStyle = themeContext.settings.autoNight ? .unspecified : (theme.overallDarkAppearance ? .dark : .light)
        })

        window.makeKeyAndVisible()
        self.applyDebugLaunchArguments(context: context, chatList: chatList, root: root, navigationController: navigationController)
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
        guard defaults.object(forKey: "openChat") != nil else {
            return
        }
        let conversationId = defaults.integer(forKey: "openChat")
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

/// The server from Settings, or canned data with `-mock YES` (UI tests and screenshots).
func makeStore() -> TauStore {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: "mock") {
        return MockStore()
    }
    let address = defaults.string(forKey: "server.url") ?? "ws://127.0.0.1:7878"
    let url = URL(string: address) ?? URL(string: "ws://127.0.0.1:7878")!
    return ServerStore(url: url, token: defaults.string(forKey: "server.token"))
}
