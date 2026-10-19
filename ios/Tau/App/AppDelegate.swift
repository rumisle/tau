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
    private var store: MockStore?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Display only knows the NavigationBar protocol; the app picks the implementation, as Telegram's AppDelegate does.
        defaultNavigationBarImpl = { presentationData in
            return NavigationBarImpl(presentationData: presentationData)
        }

        let theme = TauTheme.day

        // Telegram's window stack: a native window hosting Display's Window1, which drives layout (keyboard, status bar,
        // safe areas) for every ViewController as a ContainerViewLayout.
        let (window, hostView) = nativeWindowHostView()
        let statusBarHost = ApplicationStatusBarHost(scene: window.windowScene)
        self.statusBarHost = statusBarHost
        self.mainWindow = Window1(hostView: hostView, statusBarHost: statusBarHost)
        hostView.containerView.backgroundColor = theme.chatList.backgroundColor
        self.window = window

        let store = MockStore()
        self.store = store

        let navigationController = NavigationController(mode: .single, theme: theme.navigationControllerTheme)
        navigationController.setViewControllers([ChatListController(store: store, theme: theme)], animated: false)
        self.mainWindow.viewController = navigationController

        window.makeKeyAndVisible()
        self.applyDebugLaunchArguments(store: store, theme: theme, navigationController: navigationController)
        return true
    }

    /// For screenshots and UI checks from the command line, e.g.
    /// `xcrun simctl launch booted dev.tau.app -openChat 2 -send "hello"`.
    private func applyDebugLaunchArguments(store: MockStore, theme: TauTheme, navigationController: NavigationController) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "sendTo") != nil, let text = defaults.string(forKey: "send") {
            let conversationId = defaults.integer(forKey: "sendTo")
            Queue.mainQueue().after(1.0) {
                store.send(text, to: conversationId)
            }
        }
        guard defaults.object(forKey: "openChat") != nil else {
            return
        }
        let conversationId = defaults.integer(forKey: "openChat")
        let chat = ChatController(store: store, theme: theme, conversationId: conversationId)
        navigationController.pushViewController(chat, animated: false)
        if defaults.bool(forKey: "focus") {
            Queue.mainQueue().after(0.5) {
                chat.activateInput()
            }
        }
        if let text = defaults.string(forKey: "send") {
            Queue.mainQueue().after(1.0) {
                store.send(text, to: conversationId)
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
