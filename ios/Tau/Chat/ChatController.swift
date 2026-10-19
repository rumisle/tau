import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

final class ChatController: ViewController {
    private let store: MockStore
    private let theme: TauTheme
    private let conversationId: Int
    private let stateDisposable = MetaDisposable()
    private let titleView: ChatTitleView

    private var controllerNode: ChatControllerNode {
        return self.displayNode as! ChatControllerNode
    }

    init(store: MockStore, theme: TauTheme, conversationId: Int) {
        self.store = store
        self.theme = theme
        self.conversationId = conversationId
        self.titleView = ChatTitleView(theme: theme)

        // Telegram's chat screen uses the glass navigation bar over the wallpaper.
        super.init(navigationBarPresentationData: theme.navigationBarPresentationData(style: .glass))

        if let dialog = store.dialog(conversationId) {
            self.titleView.update(title: dialog.title, subtitle: "\(dialog.projectName) · \(dialog.model)")
        }
        self.navigationItem.titleView = self.titleView
        self.statusBar.statusBarStyle = theme.statusBarStyle == .black ? .Black : .White
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.stateDisposable.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ChatControllerNode(theme: self.theme)
        self.controllerNode.sendMessage = { [weak self] text in
            guard let self else {
                return
            }
            self.store.send(text, to: self.conversationId)
        }

        let conversationId = self.conversationId
        self.stateDisposable.set((self.store.conversationSignal(conversationId) |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            self.controllerNode.update(state: state)
            if let dialog = self.store.dialog(conversationId) {
                self.titleView.update(title: dialog.title, subtitle: state.busy ? "working…" : "\(dialog.projectName) · \(dialog.model)", isActive: state.busy)
            }
        }))
        self.displayNodeDidLoad()
    }

    func activateInput() {
        self.controllerNode.inputPanelNode.activateInput()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
}

/// Two-line chat title: the conversation, then its project and model, or what the agent is doing.
final class ChatTitleView: UIView {
    private let theme: TauTheme
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    init(theme: TauTheme) {
        self.theme = theme
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 220.0, height: 40.0))
        self.titleLabel.font = Font.semibold(17.0)
        self.titleLabel.textColor = theme.navigationBar.primaryTextColor
        self.titleLabel.textAlignment = .center
        self.subtitleLabel.font = Font.regular(13.0)
        self.subtitleLabel.textAlignment = .center
        self.addSubview(self.titleLabel)
        self.addSubview(self.subtitleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, subtitle: String, isActive: Bool = false) {
        self.titleLabel.text = title
        self.subtitleLabel.text = subtitle
        self.subtitleLabel.textColor = isActive ? self.theme.accentColor : self.theme.navigationBar.secondaryTextColor
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = self.bounds.width
        self.titleLabel.frame = CGRect(x: 0.0, y: floor(self.bounds.height / 2.0) - 20.0, width: width, height: 22.0)
        self.subtitleLabel.frame = CGRect(x: 0.0, y: floor(self.bounds.height / 2.0) + 1.0, width: width, height: 17.0)
    }
}
