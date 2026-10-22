import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import SearchUI
import MergeLists
import ComponentFlow
import LottieComponent

/// The chats opened from search, newest first, as Telegram's recent searches: shown under the field before anything is
/// typed.
enum RecentSearches {
    private static let key = "recentSearchChats"

    static var ids: [Int] {
        return UserDefaults.standard.array(forKey: self.key) as? [Int] ?? []
    }

    static func add(_ id: Int) {
        var ids = self.ids.filter { $0 != id }
        ids.insert(id, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(20)), forKey: self.key)
    }

    static func remove(_ id: Int) {
        UserDefaults.standard.set(self.ids.filter { $0 != id }, forKey: self.key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: self.key)
    }
}

private enum SearchEntryId: Hashable {
    case header(String)
    case chat(Int)
    case message(Int, Int)
}

private struct SearchEntry: Identifiable, Comparable {
    let stableId: SearchEntryId
    let index: Int
    let item: () -> ListViewItem
    /// What the row shows, for whether it changed.
    let content: ChatListItemContent?

    static func == (lhs: SearchEntry, rhs: SearchEntry) -> Bool {
        return lhs.stableId == rhs.stableId && lhs.index == rhs.index && lhs.content == rhs.content
    }

    static func < (lhs: SearchEntry, rhs: SearchEntry) -> Bool {
        return lhs.index < rhs.index
    }
}

/// The chat list's search, as Telegram's ChatListSearchContainerNode: before anything is typed, the chats last opened
/// from it ("Recent", with Clear); then chats whose title or project match, found here at once, then messages, from
/// every server's index (server/src/search), best first, a page at a time as the list scrolls. Results come as the
/// query is typed and move into place, as Telegram's search list animates its changes; nothing found, its duck.
final class ChatListSearchContainerNode: SearchDisplayControllerContentNode {
    private let context: AppContext
    private let interaction: ChatListInteraction
    private let dialogs: () -> [DialogModel]
    private let listNode = ListViewImpl()
    private let emptyNode = ImmediateTextNode()
    private let emptyAnimation = ComponentView<Empty>()
    private let searchDisposable = MetaDisposable()
    private var entries: [SearchEntry] = []
    private var layout: (ContainerViewLayout, CGFloat)?

    private var query = ""
    /// The last query sent to the servers, with whether its last word was still being typed: the same again is not.
    private var sentQuery: (String, Bool)?
    /// Telegram waits as long before its message search (ChatListSearchListPaneNode); keys come faster than that.
    private static let debounce = 0.25
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
        self.emptyNode.maximumNumberOfLines = 3
        self.emptyNode.textAlignment = .center
        self.addSubnode(self.emptyNode)
        self.listNode.beganInteractiveDragging = { [weak self] _ in
            self?.dismissInput?()
        }
        // The next page once the last results come into view.
        self.listNode.displayedItemRangeChanged = { [weak self] range, _ in
            guard let self, let visible = range.visibleRange, visible.lastIndex >= self.entries.count - 4 else {
                return
            }
            self.loadMore()
        }
        // A result opened goes to the top of Recent.
        let open = interaction.open
        interaction.open = { dialog in
            RecentSearches.add(dialog.id)
            open(dialog)
        }
        let openResult = interaction.openSearchResult
        interaction.openSearchResult = { dialog, match in
            RecentSearches.add(dialog.id)
            openResult(dialog, match)
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
            self.sentQuery = nil
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
        // Messages already shown stay until the new page replaces them, so the list does not flash empty between keys.
        self.reload()
        // Messages from the servers once typing pauses: each key cancels the wait for the one before, so a word typed
        // quickly is one request. The last word is a prefix while it is being typed.
        let typing = !text.hasSuffix(" ")
        if let sent = self.sentQuery, sent.0 == query, sent.1 == typing {
            return
        }
        self.sentQuery = nil
        let store = self.context.store
        let signal: Signal<SearchPage, NoError> = (Signal<Void, NoError>.single(Void()) |> delay(ChatListSearchContainerNode.debounce, queue: Queue.mainQueue()))
        |> mapToSignal { [weak self] _ -> Signal<SearchPage, NoError> in
            self?.sentQuery = (query, typing)
            return store.search(query, typing: typing, offset: 0)
        }
        self.searchDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] page in
            guard let self, self.generation == generation else {
                return
            }
            self.terms = page.terms
            self.matches = page.matches
            self.hasMore = page.hasMore
            self.didSearch = true
            self.reload()
        }))
    }

    /// Whether messages have been searched for the query since it was last empty: until then "no results" is not known.
    private var didSearch = false

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

    private func makeEntries() -> [SearchEntry] {
        let theme = self.context.theme
        let interaction = self.interaction
        var entries: [SearchEntry] = []
        func add(_ id: SearchEntryId, content: ChatListItemContent?, _ item: @escaping () -> ListViewItem) {
            entries.append(SearchEntry(stableId: id, index: entries.count, item: item, content: content))
        }
        let known = Dictionary(self.dialogs().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.query.isEmpty {
            let recent = RecentSearches.ids.compactMap { known[$0] }
            if !recent.isEmpty {
                add(.header("recent"), content: nil) {
                    ChatListSearchHeaderItem(theme: theme, title: "Recent", action: "Clear", activate: { [weak self] in
                        RecentSearches.clear()
                        self?.reload()
                    })
                }
                for dialog in recent {
                    add(.chat(dialog.id), content: .dialog(dialog)) {
                        ChatListItem(theme: theme, content: .dialog(dialog), interaction: interaction)
                    }
                }
            }
            return entries
        }
        if !self.chats.isEmpty {
            add(.header("chats"), content: nil) {
                ChatListSearchHeaderItem(theme: theme, title: "Chats")
            }
            for dialog in self.chats.prefix(20) {
                add(.chat(dialog.id), content: .dialog(dialog)) {
                    ChatListItem(theme: theme, content: .dialog(dialog), interaction: interaction)
                }
            }
        }
        let found = self.matches.compactMap { match in known[match.conversationId].map { ($0, match) } }
        if !found.isEmpty {
            add(.header("messages"), content: nil) {
                ChatListSearchHeaderItem(theme: theme, title: "Messages")
            }
            for (dialog, match) in found {
                add(.message(dialog.id, match.entryId ?? -1), content: .message(dialog, match)) {
                    ChatListItem(theme: theme, content: .message(dialog, match), interaction: interaction)
                }
            }
        }
        return entries
    }

    private func reload() {
        guard let (layout, _) = self.layout else {
            return
        }
        if self.query.isEmpty {
            self.didSearch = false
        }
        let theme = self.context.theme
        let previous = self.entries
        let entries = self.makeEntries()
        self.entries = entries
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: previous, rightList: entries)
        var options: ListViewDeleteAndInsertOptions = [.PreferSynchronousDrawing]
        if previous.isEmpty || entries.isEmpty {
            options.insert(.Synchronous)
        } else {
            options.insert(.AnimateInsertion)
        }
        self.listNode.transaction(
            deleteIndices: deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) },
            insertIndicesAndItems: indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(), directionHint: nil) },
            updateIndicesAndItems: updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(), directionHint: nil) },
            options: options,
            scrollToItem: previous.isEmpty || (previous.first?.stableId != entries.first?.stableId) ? ListViewScrollToItem(index: 0, position: .top(0.0), animated: false, curve: .Default(duration: nil), directionHint: .Up) : nil,
            updateOpaqueState: nil
        )
        // Telegram's empty result: its duck, what was searched for, and that nothing has it.
        let isEmpty = entries.isEmpty && !self.query.isEmpty && self.didSearch
        let wasHidden = self.emptyNode.isHidden
        self.emptyNode.isHidden = !isEmpty
        self.emptyAnimation.view?.isHidden = !isEmpty
        if isEmpty {
            let text = NSMutableAttributedString(string: "No Results\n", font: Font.semibold(17.0), textColor: theme.chatList.titleColor)
            text.append(NSAttributedString(string: "There were no results for \"\(self.query)\".\nTry a new search.", font: Font.regular(15.0), textColor: theme.chatList.messageTextColor))
            self.emptyNode.attributedText = text
            self.layoutEmpty(layout)
            if wasHidden {
                (self.emptyAnimation.view as? LottieComponent.View)?.playOnce()
                self.emptyNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                self.emptyAnimation.view?.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
    }

    private func layoutEmpty(_ layout: ContainerViewLayout) {
        let animationSize = CGSize(width: 120.0, height: 120.0)
        let _ = self.emptyAnimation.update(transition: .immediate, component: AnyComponent(LottieComponent(content: LottieComponent.AppBundleContent(name: "ChatListNoResults"), startingPosition: .begin, size: animationSize, lottieSettings: .noAccountFallback)), environment: {}, containerSize: animationSize)
        if let view = self.emptyAnimation.view, view.superview == nil {
            view.isHidden = self.emptyNode.isHidden
            self.view.addSubview(view)
        }
        let size = self.emptyNode.updateLayout(CGSize(width: layout.size.width - 64.0, height: 200.0))
        let visibleHeight = layout.size.height - (self.layout?.1 ?? 0.0) - layout.insets(options: [.input]).bottom
        let total = animationSize.height + 16.0 + size.height
        let top = (self.layout?.1 ?? 0.0) + max(24.0, floor((visibleHeight - total) * 0.4))
        self.emptyAnimation.view?.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - animationSize.width) / 2.0), y: top), size: animationSize)
        self.emptyNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - size.width) / 2.0), y: top + animationSize.height + 16.0), size: size)
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
    /// A button at the end, as Telegram's "Clear" over recent searches.
    let action: String?
    let activate: (() -> Void)?

    init(theme: TauTheme, title: String, action: String? = nil, activate: (() -> Void)? = nil) {
        self.theme = theme
        self.title = title
        self.action = action
        self.activate = activate
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
    private let actionNode = HighlightableButtonNode()
    private var activate: (() -> Void)?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.backgroundNode.isLayerBacked = true
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.actionNode)
        self.actionNode.addTarget(self, action: #selector(self.actionPressed), forControlEvents: .touchUpInside)
    }

    @objc private func actionPressed() {
        self.activate?()
    }

    func update(item: ChatListSearchHeaderItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        let theme = item.theme.presentationTheme.chatList
        let height: CGFloat = 28.0
        self.activate = item.activate
        self.backgroundNode.backgroundColor = theme.pinnedItemBackgroundColor
        self.backgroundNode.frame = CGRect(x: 0.0, y: 0.0, width: params.width, height: height)
        self.titleNode.attributedText = NSAttributedString(string: item.title.uppercased(), font: Font.regular(13.0), textColor: theme.sectionHeaderTextColor)
        let size = self.titleNode.updateLayout(CGSize(width: params.width - 32.0, height: height))
        self.titleNode.frame = CGRect(origin: CGPoint(x: params.leftInset + 16.0, y: floor((height - size.height) / 2.0)), size: size)
        if let action = item.action {
            self.actionNode.isHidden = false
            self.actionNode.setAttributedTitle(NSAttributedString(string: action, font: Font.regular(13.0), textColor: item.theme.presentationTheme.list.itemAccentColor), for: .normal)
            let actionSize = self.actionNode.measure(CGSize(width: 120.0, height: height))
            self.actionNode.frame = CGRect(x: params.width - params.rightInset - 16.0 - actionSize.width, y: 0.0, width: actionSize.width, height: height)
            self.actionNode.hitTestSlop = UIEdgeInsets(top: -6.0, left: -10.0, bottom: -6.0, right: -10.0)
            self.actionNode.accessibilityIdentifier = "searchHeaderAction"
        } else {
            self.actionNode.isHidden = true
        }
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
    }
}
