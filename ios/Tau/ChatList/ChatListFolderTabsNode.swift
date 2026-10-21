import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import ContextUI
import TelegramPresentationData
import HorizontalTabsComponent
import HeaderPanelContainerComponent

/// A tab over the chat list: All, or a folder.
enum ChatListFolderId: Hashable {
    case all
    case folder(Int32)

    /// HorizontalTabsComponent's ID, as Telegram's: Int32.min for All.
    var tabId: AnyHashable {
        switch self {
        case .all:
            return AnyHashable(Int32.min)
        case let .folder(id):
            return AnyHashable(id)
        }
    }

    init?(tabId: AnyHashable) {
        guard let value = tabId.base as? Int32 else {
            return nil
        }
        self = value == Int32.min ? .all : .folder(value)
    }
}

struct ChatListFolderTab: Equatable {
    var id: ChatListFolderId
    var title: String
    /// Chats with something new in it, as Telegram's folder badges.
    var unread: Int
}

/// The folder tabs under the search field, as Telegram's chat list has them: HorizontalTabsComponent in the glass
/// capsule of HeaderPanelContainerComponent, both Telegram's. It sits in the navigation bar as its secondary content,
/// so it stays as the search field collapses and goes with the bar when search opens.
final class ChatListFolderTabsNode: ASDisplayNode {
    static let height: CGFloat = 52.0

    private let tabsView = ComponentView<Empty>()
    private var theme: TauTheme
    private var tabs: [ChatListFolderTab] = []
    private var selected: ChatListFolderId = .all
    private(set) var isEditing = false
    private var width: CGFloat = 0.0

    var select: ((ChatListFolderId) -> Void)?
    var contextAction: ((ChatListFolderId, ContextExtractedContentContainingView, ContextGesture?) -> Void)?
    var delete: ((ChatListFolderId) -> Void)?

    init(theme: TauTheme) {
        self.theme = theme
        super.init()
    }

    /// The order the user dragged the tabs into while reordering, All included.
    var reorderedIds: [ChatListFolderId]? {
        guard let view = self.headerView?.tabs as? HorizontalTabsComponent.View, let ids = view.reorderedItemIds else {
            return nil
        }
        return ids.compactMap(ChatListFolderId.init(tabId:))
    }

    private var headerView: HeaderPanelContainerComponent.View? {
        return self.tabsView.view as? HeaderPanelContainerComponent.View
    }

    func update(theme: TauTheme, tabs: [ChatListFolderTab], selected: ChatListFolderId, isEditing: Bool, transition: ComponentTransition) {
        self.theme = theme
        self.tabs = tabs
        self.selected = selected
        self.isEditing = isEditing
        self.updateLayout(width: self.width, transition: transition)
    }

    /// While the lists are dragged between folders: the selection follows the finger.
    func updateSwitchFraction(_ fraction: CGFloat, isDragging: Bool, transition: ComponentTransition) {
        (self.headerView?.tabs as? HorizontalTabsComponent.View)?.updateTabSwitchFraction(fraction: fraction, isDragging: isDragging, transition: transition)
    }

    func updateLayout(width: CGFloat, transition: ComponentTransition) {
        self.width = width
        guard width > 0.0 else {
            return
        }
        let theme = self.theme.presentationTheme
        let tabs = self.tabs.map { tab -> HorizontalTabsComponent.Tab in
            let id = tab.id
            return HorizontalTabsComponent.Tab(
                id: id.tabId,
                content: .title(HorizontalTabsComponent.Tab.Title(text: tab.title, entities: [], enableAnimations: false)),
                badge: tab.unread > 0 ? HorizontalTabsComponent.Tab.Badge(title: "\(tab.unread)", isAccent: true) : nil,
                action: { [weak self] in
                    self?.select?(id)
                },
                contextAction: { [weak self] view, gesture in
                    self?.contextAction?(id, view, gesture)
                },
                deleteAction: (!self.isEditing || id == .all) ? nil : { [weak self] in
                    self?.delete?(id)
                }
            )
        }
        let size = self.tabsView.update(
            transition: transition,
            component: AnyComponent(HeaderPanelContainerComponent(
                theme: theme,
                tabs: AnyComponent(HorizontalTabsComponent(
                    context: nil,
                    theme: theme,
                    tabs: tabs,
                    selectedTab: self.selected.tabId,
                    isEditing: self.isEditing,
                    liftWhileSwitching: true
                )),
                panels: []
            )),
            environment: {},
            containerSize: CGSize(width: width, height: 40.0)
        )
        if let view = self.tabsView.view {
            if view.superview == nil {
                self.view.addSubview(view)
            }
            transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 0.0, y: 4.0), size: size))
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let view = self.tabsView.view, let result = view.hitTest(self.view.convert(point, to: view), with: event) {
            return result
        }
        return nil
    }
}
