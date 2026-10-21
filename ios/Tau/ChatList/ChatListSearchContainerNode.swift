import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import SearchUI

/// The chat list's search, as Telegram's ChatListSearchContainerNode: chats whose title or project match, found here at
/// once, then messages, from every server's index (server/src/search), best first, a page at a time as the list
/// scrolls. Results come as the query is typed; each new one replaces the last.
final class ChatListSearchContainerNode: SearchDisplayControllerContentNode {
    private let context: AppContext
    private let interaction: ChatListInteraction
    private let dialogs: () -> [DialogModel]
    private let listNode = ListViewImpl()
    private let emptyNode = ImmediateTextNode()
    private let searchDisposable = MetaDisposable()
    private var itemCount = 0
    private var layout: (ContainerViewLayout, CGFloat)?

    private var query = ""
    private var chats: [DialogModel] = []
    private var matches: [SearchMatch] = []
    private var hasMore = false
    private var isLoadingMore = false
    private var generation = 0

    /// The words the last page was found with, for the chat a result opens.
    private(set) var terms: [SearchTerm] = []

    init(context: AppContext, interaction: ChatListInteraction, dialogs: @escaping () -> [DialogModel]) {
        self.context = context
        self.interaction = interaction
        self.dialogs = dialogs
        super.init()
        let theme = context.theme
        self.backgroundColor = theme.chatList.backgroundColor
        self.listNode.backgroundColor = theme.chatList.backgroundColor
        self.addSubnode(self.listNode)
        self.emptyNode.isHidden = true
        self.emptyNode.maximumNumberOfLines = 2
        self.emptyNode.textAlignment = .center
        self.addSubnode(self.emptyNode)
        self.listNode.beganInteractiveDragging = { [weak self] _ in
            self?.dismissInput?()
        }
        // The next page once the last results come into view.
        self.listNode.displayedItemRangeChanged = { [weak self] range, _ in
            guard let self, let visible = range.visibleRange, visible.lastIndex >= self.itemCount - 4 else {
                return
            }
            self.loadMore()
        }
    }

    deinit {
        self.searchDisposable.dispose()
    }

    override func searchTextUpdated(text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        self.generation += 1
        let generation = self.generation
        guard !query.isEmpty else {
            self.searchDisposable.set(nil)
            self.chats = []
            self.matches = []
            self.hasMore = false
            self.reload()
            return
        }
        // Chats by their title and project, here and at once.
        let words = query.lowercased().split(separator: " ").map(String.init)
        self.chats = self.dialogs().filter { dialog in
            let haystack = "\(dialog.title) \(dialog.projectLabel)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        self.reload()
        // Messages from the servers, after a pause in typing; the last word is a prefix while it is being typed.
        let typing = !text.hasSuffix(" ")
        let signal: Signal<SearchPage, NoError> = (Signal<SearchPage, NoError>.complete() |> delay(0.12, queue: Queue.mainQueue())) |> then(self.context.store.search(query, typing: typing, offset: 0))
        self.searchDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] page in
            guard let self, self.generation == generation else {
                return
            }
            self.terms = page.terms
            self.matches = page.matches
            self.hasMore = page.hasMore
            self.reload()
        }))
    }

    private func loadMore() {
        guard self.hasMore, !self.isLoadingMore, !self.query.isEmpty else {
            return
        }
        self.isLoadingMore = true
        let generation = self.generation
        let _ = (self.context.store.search(self.query, typing: false, offset: self.matches.count) |> deliverOnMainQueue).start(next: { [weak self] page in
            guard let self else {
                return
            }
            self.isLoadingMore = false
            guard self.generation == generation else {
                return
            }
            let known = Set(self.matches.map(\.conversationId))
            self.matches += page.matches.filter { !known.contains($0.conversationId) }
            self.hasMore = page.hasMore && !page.matches.isEmpty
            self.reload()
        })
    }

    private func reload() {
        guard let (layout, _) = self.layout else {
            return
        }
        let theme = self.context.theme
        var items: [ListViewItem] = []
        if !self.chats.isEmpty {
            items.append(ChatListSearchHeaderItem(theme: theme, title: "Chats"))
            for dialog in self.chats.prefix(20) {
                items.append(ChatListItem(theme: theme, content: .dialog(dialog), interaction: self.interaction))
            }
        }
        let known = Dictionary(self.dialogs().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let found = self.matches.compactMap { match in known[match.conversationId].map { ($0, match) } }
        if !found.isEmpty {
            items.append(ChatListSearchHeaderItem(theme: theme, title: "Messages"))
            for (dialog, match) in found {
                items.append(ChatListItem(theme: theme, content: .message(dialog, match), interaction: self.interaction))
            }
        }
        let deletions = (0 ..< self.itemCount).map { ListViewDeleteItem(index: $0, directionHint: nil) }
        let insertions = items.enumerated().map { ListViewInsertItem(index: $0.offset, previousIndex: nil, item: $0.element, directionHint: nil) }
        self.listNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: [], options: [.Synchronous, .PreferSynchronousDrawing], updateOpaqueState: nil)
        self.itemCount = items.count
        // Telegram's empty result: what was searched for, and that nothing has it.
        let isEmpty = items.isEmpty && !self.query.isEmpty
        self.emptyNode.isHidden = !isEmpty
        if isEmpty {
            let text = NSMutableAttributedString(string: "No Results\n", font: Font.semibold(17.0), textColor: theme.chatList.titleColor)
            text.append(NSAttributedString(string: "There were no results for \"\(self.query)\".", font: Font.regular(15.0), textColor: theme.chatList.messageTextColor))
            self.emptyNode.attributedText = text
            self.layoutEmpty(layout)
        }
    }

    private func layoutEmpty(_ layout: ContainerViewLayout) {
        let size = self.emptyNode.updateLayout(CGSize(width: layout.size.width - 64.0, height: 200.0))
        let top = (self.layout?.1 ?? 0.0) + 120.0
        self.emptyNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - size.width) / 2.0), y: top), size: size)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
        let hadLayout = self.layout != nil
        self.layout = (layout, navigationBarHeight)
        self.listNode.frame = CGRect(origin: CGPoint(), size: layout.size)
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: UIEdgeInsets(top: navigationBarHeight, left: layout.safeInsets.left, bottom: layout.insets(options: [.input]).bottom + 16.0, right: layout.safeInsets.right), duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
        if !hadLayout {
            self.reload()
        } else if !self.emptyNode.isHidden {
            self.layoutEmpty(layout)
        }
    }
}

/// A section's title over search results, as Telegram's ChatListSearchItemHeader: small capitals on the section fill.
final class ChatListSearchHeaderItem: ListViewItem {
    let theme: TauTheme
    let title: String

    init(theme: TauTheme, title: String) {
        self.theme = theme
        self.title = title
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return false
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            Queue.mainQueue().async {
                let node = ChatListSearchHeaderItemNode()
                let layout = node.update(item: self, params: params)
                node.contentSize = layout.contentSize
                node.insets = layout.insets
                completion(node, {
                    return (nil, { _ in })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? ChatListSearchHeaderItemNode else {
                return
            }
            let layout = node.update(item: self, params: params)
            completion(layout, { _ in })
        }
    }
}

private final class ChatListSearchHeaderItemNode: ListViewItemNode {
    private let backgroundNode = ASDisplayNode()
    private let titleNode = ImmediateTextNode()

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.backgroundNode.isLayerBacked = true
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.titleNode)
    }

    func update(item: ChatListSearchHeaderItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        let theme = item.theme.presentationTheme.chatList
        let height: CGFloat = 28.0
        self.backgroundNode.backgroundColor = theme.pinnedItemBackgroundColor
        self.backgroundNode.frame = CGRect(x: 0.0, y: 0.0, width: params.width, height: height)
        self.titleNode.attributedText = NSAttributedString(string: item.title.uppercased(), font: Font.regular(13.0), textColor: theme.sectionHeaderTextColor)
        let size = self.titleNode.updateLayout(CGSize(width: params.width - 32.0, height: height))
        self.titleNode.frame = CGRect(origin: CGPoint(x: params.leftInset + 16.0, y: floor((height - size.height) / 2.0)), size: size)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }
}
