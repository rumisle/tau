import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ComponentFlow
import ComponentDisplayAdapters
import TabBarComponent

/// The root screen: tabs with Telegram's floating glass tab bar. Switching follows Telegram-iOS
/// TabBarUI/Sources/TabBarController.swift (`updateSelectedIndex`): the old tab shrinks a few points, the new one fades
/// in and springs back to full size. Each tab's controller keeps its own navigation bar, as in Telegram.
final class RootTabController: ViewController {
    struct Tab {
        let id: AnyHashable
        let title: String
        /// A Lottie animation in the bundle (Telegram plays it once on selection), and its offset.
        let animation: String
        let animationOffset: CGPoint
        let controller: ViewController
    }

    private let context: AppContext
    private let tabs: [Tab]
    private var theme: TauTheme
    private var themeDisposable: Disposable?

    private(set) var selectedIndex: Int = 0
    private var currentController: ViewController?
    private var tabBarView = ComponentView<Empty>()
    /// The system's liquid lens draws nothing in the selected tab when the bar was set up outside a window, as when the
    /// app opens straight into a chat: such a bar is made again once it is in one.
    private var tabBarMadeOutsideWindow = false
    private var isChangingSelectedIndex = false
    /// While a tab's search is open the bar slides away, as TabBarController.updateIsTabBarHidden does.
    private(set) var isTabBarHidden = false
    private var validLayout: ContainerViewLayout?

    override var transitionNavigationBar: NavigationBar? {
        return self.currentController?.navigationBar
    }

    init(context: AppContext, tabs: [Tab]) {
        self.context = context
        self.tabs = tabs
        self.theme = context.theme
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = self.theme.statusBarStyleValue
        self.themeDisposable = (context.themeContext.theme |> deliverOnMainQueue).start(next: { [weak self] theme in
            self?.updateTheme(theme)
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.themeDisposable?.dispose()
    }

    var controllers: [ViewController] {
        return self.tabs.map(\.controller)
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.theme.chatList.backgroundColor
        self.updateSelectedIndex(animated: false)
        self.displayNodeDidLoad()
    }

    private func updateTheme(_ theme: TauTheme) {
        guard theme !== self.theme else {
            return
        }
        self.theme = theme
        self.statusBar.statusBarStyle = theme.statusBarStyleValue
        if self.isNodeLoaded {
            self.displayNode.backgroundColor = theme.chatList.backgroundColor
        }
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .immediate)
        }
    }

    func updateIsTabBarHidden(_ hidden: Bool, transition: ContainedViewLayoutTransition) {
        guard hidden != self.isTabBarHidden else {
            return
        }
        self.isTabBarHidden = hidden
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .animated(duration: 0.4, curve: .slide))
        }
    }

    func select(index: Int) {
        guard index != self.selectedIndex, index >= 0, index < self.tabs.count else {
            self.currentController?.scrollToTop?()
            return
        }
        self.selectedIndex = index
        self.isChangingSelectedIndex = true
        self.updateSelectedIndex(animated: true)
    }

    private func updateSelectedIndex(animated: Bool) {
        guard self.isNodeLoaded else {
            return
        }
        var transitionScale: CGFloat = 0.998
        if let currentView = self.currentController?.view, currentView.frame.height > 0.0 {
            transitionScale = (currentView.frame.height - 3.0) / currentView.frame.height
        }
        if let currentController = self.currentController {
            currentController.willMove(toParent: nil)
            if animated {
                currentController.view.layer.animateScale(from: 1.0, to: transitionScale, duration: 0.12, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { completed in
                    if completed {
                        currentController.view.layer.removeAllAnimations()
                    }
                })
            }
            currentController.view.removeFromSuperview()
            currentController.removeFromParent()
            currentController.didMove(toParent: nil)
            self.currentController = nil
        }

        let currentController = self.tabs[self.selectedIndex].controller
        self.currentController = currentController
        currentController.willMove(toParent: self)
        self.addChild(currentController)
        if let tabBar = self.tabBarView.view {
            self.displayNode.view.insertSubview(currentController.view, belowSubview: tabBar)
        } else {
            self.displayNode.view.addSubview(currentController.view)
        }
        if animated {
            currentController.view.layer.animateScale(from: transitionScale, to: 1.0, duration: 0.15, delay: 0.1, timingFunction: kCAMediaTimingFunctionSpring)
            currentController.view.layer.allowsGroupOpacity = true
            currentController.view.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1, completion: { completed in
                if completed {
                    currentController.view.layer.allowsGroupOpacity = false
                }
            })
        }
        currentController.didMove(toParent: self)
        currentController.displayNode.recursivelyEnsureDisplaySynchronously(true)
        self.statusBar.statusBarStyle = self.theme.statusBarStyleValue

        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .immediate)
        }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout

        let tabBarHeight = self.updateTabBar(layout: layout, transition: transition)
        if let currentController = self.currentController {
            currentController.view.frame = CGRect(origin: CGPoint(), size: layout.size)
            var childLayout = layout
            if !self.isTabBarHidden {
                childLayout.intrinsicInsets.bottom = tabBarHeight
            }
            currentController.containerLayoutUpdated(childLayout, transition: transition)
        }
    }

    /// Lays out the floating tab bar as Telegram's TabBarControllerNode.updateImpl does and returns the height it covers.
    private func updateTabBar(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) -> CGFloat {
        let panelsBottomInset = max(layout.insets(options: []).bottom, 8.0)
        let sideInset: CGFloat = panelsBottomInset <= 28.0 ? 20.0 : 12.0

        var tabBarTransition = ComponentTransition(transition)
        if self.isChangingSelectedIndex {
            self.isChangingSelectedIndex = false
            tabBarTransition = .spring(duration: 0.4)
        }
        if self.tabBarView.view == nil {
            tabBarTransition = .immediate
            self.tabBarMadeOutsideWindow = self.view.window == nil
        }
        let tabBarSize = self.tabBarView.update(
            transition: tabBarTransition,
            component: AnyComponent(TabBarComponent(
                theme: self.theme.presentationTheme,
                strings: self.theme.presentationStrings,
                items: self.tabs.enumerated().map { index, tab in
                    TabBarComponent.Item(
                        content: .customItem(.init(id: tab.id, title: tab.title, icon: .animation(name: tab.animation, offset: tab.animationOffset))),
                        action: { [weak self] _ in
                            self?.select(index: index)
                        },
                        doubleTapAction: nil,
                        contextAction: nil
                    )
                },
                search: nil,
                selectedId: self.tabs[self.selectedIndex].id,
                outerInsets: UIEdgeInsets(top: 0.0, left: sideInset, bottom: panelsBottomInset, right: sideInset)
            )),
            environment: {},
            containerSize: CGSize(width: layout.size.width - sideInset * 2.0, height: 100.0)
        )
        let tabBarFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - tabBarSize.width) * 0.5), y: layout.size.height - (self.isTabBarHidden ? 0.0 : tabBarSize.height + panelsBottomInset)), size: tabBarSize)
        if let tabBar = self.tabBarView.view {
            if tabBar.superview == nil {
                self.displayNode.view.addSubview(tabBar)
            }
            transition.updateFrame(view: tabBar, frame: tabBarFrame)
        }
        return tabBarSize.height + panelsBottomInset
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.currentController?.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.currentController?.viewDidAppear(animated)
        // Once the navigation transition has put the root back in the window; at didMoveToWindow it is too early.
        if self.tabBarMadeOutsideWindow {
            Queue.mainQueue().after(0.1) { [weak self] in
                self?.remakeTabBarIfNeeded()
            }
        }
    }

    private func remakeTabBarIfNeeded() {
        guard self.tabBarMadeOutsideWindow, self.view.window != nil else {
            return
        }
        self.tabBarMadeOutsideWindow = false
        self.tabBarView.view?.removeFromSuperview()
        self.tabBarView = ComponentView<Empty>()
        if let layout = self.validLayout {
            let _ = self.updateTabBar(layout: layout, transition: .immediate)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.currentController?.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.currentController?.viewDidDisappear(animated)
    }
}

