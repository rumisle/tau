import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import GlassBackgroundComponent

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
        super.init(navigationBarPresentationData: theme.navigationBarPresentationData(style: .glass, edgeEffectColor: UIColor(white: 1.0, alpha: 0.25)))

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

    func setDraft(_ text: String) {
        self.controllerNode.inputPanelNode.setText(text)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
}

/// Two-line chat title in a glass capsule, as Telegram's ChatTitleView draws it in the glass navigation bar: the
/// conversation, then its project and model, or what the agent is doing.
final class ChatTitleView: UIView {
    private let theme: TauTheme
    private let backgroundView = GlassBackgroundView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    init(theme: TauTheme) {
        self.theme = theme
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 240.0, height: 44.0))
        self.titleLabel.font = Font.semibold(16.0)
        self.titleLabel.textColor = theme.navigationBar.primaryTextColor
        self.titleLabel.textAlignment = .center
        self.subtitleLabel.font = Font.regular(12.0)
        self.subtitleLabel.textAlignment = .center
        self.addSubview(self.backgroundView)
        self.backgroundView.contentView.addSubview(self.titleLabel)
        self.backgroundView.contentView.addSubview(self.subtitleLabel)
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
        let maxTextWidth = max(40.0, self.bounds.width - 24.0)
        let titleSize = self.titleLabel.sizeThatFits(CGSize(width: maxTextWidth, height: 22.0))
        let subtitleSize = self.subtitleLabel.sizeThatFits(CGSize(width: maxTextWidth, height: 16.0))
        let textWidth = min(maxTextWidth, ceil(max(titleSize.width, subtitleSize.width)))

        // Telegram ChatTitleView: a 44 pt capsule, 12 pt wider than the text on each side.
        let backgroundSize = CGSize(width: textWidth + 24.0, height: 44.0)
        let backgroundFrame = CGRect(origin: CGPoint(x: floor((self.bounds.width - backgroundSize.width) / 2.0), y: floor((self.bounds.height - backgroundSize.height) / 2.0)), size: backgroundSize)
        self.backgroundView.frame = backgroundFrame
        self.backgroundView.update(size: backgroundSize, cornerRadius: backgroundSize.height / 2.0, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: .immediate)
        self.titleLabel.frame = CGRect(x: 12.0, y: 4.0, width: textWidth, height: 21.0)
        self.subtitleLabel.frame = CGRect(x: 12.0, y: 24.0, width: textWidth, height: 15.0)
    }
}
