import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import SearchBarNode
import SearchUI

/// Choosing a model, after Telegram's LanguageSelectionScreen: a modal list with Telegram's search field in the
/// navigation bar. Recently chosen models come first, then every model the server has credentials for, by provider. The
/// search matches names, IDs and providers, word by word.
final class ModelPickerController: ViewController {
    private let context: AppContext
    private let current: String?
    private let select: (ModelInfo) -> Void

    private var controllerNode: ModelPickerControllerNode {
        return self.displayNode as! ModelPickerControllerNode
    }

    private let _ready = Promise<Bool>()
    override var ready: Promise<Bool> {
        return self._ready
    }

    private var searchContentNode: NavigationBarSearchContentNode?
    private var previousContentOffset: ListViewVisibleContentOffset?
    private var modelsDisposable: Disposable?

    /// `current` is the selected model as `provider/id`.
    /// The server whose models it lists.
    private let server: TauServer

    init(context: AppContext, server: TauServer, title: String, current: String?, select: @escaping (ModelInfo) -> Void) {
        self.context = context
        self.server = server
        self.current = current
        self.select = select
        let presentationData = context.theme.presentationData
        super.init(navigationBarPresentationData: context.theme.navigationBarPresentationData())
        self.statusBar.statusBarStyle = context.theme.statusBarStyleValue
        self.navigationPresentation = .modal
        self.title = title
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: presentationData.strings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelPressed))

        self.scrollToTop = { [weak self] in
            guard let self else {
                return
            }
            self.searchContentNode?.updateExpansionProgress(1.0, animated: true)
            self.controllerNode.scrollToTop()
        }

        self.searchContentNode = NavigationBarSearchContentNode(theme: presentationData.theme, placeholder: presentationData.strings.Common_Search, inline: true, activate: { [weak self] in
            self?.activateSearch()
        })
        self.navigationBar?.setContentNode(self.searchContentNode, animated: false)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.modelsDisposable?.dispose()
    }

    @objc private func cancelPressed() {
        self.dismiss()
    }

    override func loadDisplayNode() {
        self.displayNode = ModelPickerControllerNode(context: self.context, navigationBar: self.navigationBar!, current: self.current, requestDeactivateSearch: { [weak self] in
            self?.deactivateSearch()
        }, select: { [weak self] model in
            guard let self else {
                return
            }
            ModelPickerController.noteRecent(model)
            self.select(model)
            self.dismiss()
        })

        self.controllerNode.listNode.visibleContentOffsetChanged = { [weak self] offset, _ in
            guard let self else {
                return
            }
            self.searchContentNode?.updateListVisibleContentOffset(offset)
            var previousContentOffsetValue: CGFloat?
            if let previousContentOffset = self.previousContentOffset, case let .known(value) = previousContentOffset {
                previousContentOffsetValue = value
            }
            switch offset {
            case let .known(value):
                let transition: ContainedViewLayoutTransition
                if let previousContentOffsetValue, value <= 0.0, previousContentOffsetValue > 30.0 {
                    transition = .animated(duration: 0.2, curve: .easeInOut)
                } else {
                    transition = .immediate
                }
                self.navigationBar?.updateBackgroundAlpha(min(30.0, max(0.0, value - 54.0)) / 30.0, transition: transition)
            case .unknown, .none:
                self.navigationBar?.updateBackgroundAlpha(1.0, transition: .immediate)
            }
            self.previousContentOffset = offset
        }
        self.controllerNode.listNode.didEndScrolling = { [weak self] _ in
            if let self, let searchContentNode = self.searchContentNode {
                let _ = fixNavigationSearchableListNodeScrolling(self.controllerNode.listNode, searchNode: searchContentNode)
            }
        }

        self._ready.set(self.controllerNode.ready.get())
        self.navigationBar?.updateBackgroundAlpha(0.0, transition: .immediate)
        self.displayNodeDidLoad()

        self.modelsDisposable = (self.server.models() |> deliverOnMainQueue).start(next: { [weak self] models in
            self?.controllerNode.update(models: models)
        })
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.cleanNavigationHeight, transition: transition)
    }

    private func activateSearch() {
        if self.displayNavigationBar {
            self.scrollToTop?()
            if let searchContentNode = self.searchContentNode {
                self.controllerNode.activateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
            self.setDisplayNavigationBar(false, transition: .animated(duration: 0.5, curve: .spring))
        }
    }

    private func deactivateSearch() {
        if !self.displayNavigationBar {
            self.setDisplayNavigationBar(true, transition: .animated(duration: 0.5, curve: .spring))
            if let searchContentNode = self.searchContentNode {
                self.controllerNode.deactivateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
        }
    }

    // MARK: - Recent models

    private static let recentKey = "models.recent"

    /// Models chosen lately, as `provider/id`, newest first.
    static var recent: [String] {
        return UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    static func noteRecent(_ model: ModelInfo) {
        let ref = "\(model.provider)/\(model.id)"
        var list = self.recent.filter { $0 != ref }
        list.insert(ref, at: 0)
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: recentKey)
    }
}

/// The models' rows: section headers and two-line rows (name, then `provider/id`) with the current one checked.
private func modelListItems(theme: TauTheme, sections: [(String, [ModelInfo])], current: String?, select: @escaping (ModelInfo) -> Void) -> [ListViewItem] {
    var items: [ListViewItem] = []
    for (title, models) in sections where !models.isEmpty {
        items.append(SettingsTextItem(theme: theme, text: title, kind: .header))
        for (index, model) in models.enumerated() {
            let ref = "\(model.provider)/\(model.id)"
            items.append(SettingsRowItem(theme: theme, icon: nil, title: model.name, subtitle: ref, accessory: .checkmark(ref == current), position: SettingsRowPosition(isFirst: index == 0, isLast: index == models.count - 1), action: {
                select(model)
            }))
        }
    }
    return items
}

/// Whether every word of the query is in the model's name, ID or provider.
private func modelMatches(_ model: ModelInfo, query: String) -> Bool {
    let haystack = "\(model.name) \(model.provider)/\(model.id)".lowercased()
    return query.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
}

private final class ModelPickerControllerNode: ASDisplayNode {
    private let context: AppContext
    private weak var navigationBar: NavigationBar?
    private let current: String?
    private let requestDeactivateSearch: () -> Void
    private let select: (ModelInfo) -> Void

    let listNode: ListView
    let ready = ValuePromise<Bool>()
    private var models: [ModelInfo] = []
    private var itemCount = 0
    private var containerLayout: (ContainerViewLayout, CGFloat)?
    private var searchDisplayController: SearchDisplayController?

    init(context: AppContext, navigationBar: NavigationBar, current: String?, requestDeactivateSearch: @escaping () -> Void, select: @escaping (ModelInfo) -> Void) {
        self.context = context
        self.navigationBar = navigationBar
        self.current = current
        self.requestDeactivateSearch = requestDeactivateSearch
        self.select = select
        self.listNode = ListViewImpl()
        let theme = context.theme
        self.listNode.keepTopItemOverscrollBackground = ListViewKeepTopItemOverscrollBackground(color: theme.list.blocksBackgroundColor, direction: true)
        super.init()
        self.backgroundColor = theme.list.blocksBackgroundColor
        self.addSubnode(self.listNode)
    }

    func update(models: [ModelInfo]) {
        self.models = models
        self.reload()
        self.ready.set(true)
    }

    private func reload() {
        guard self.containerLayout != nil else {
            return
        }
        let theme = self.context.theme
        let recent = ModelPickerController.recent.compactMap { ref in self.models.first(where: { "\($0.provider)/\($0.id)" == ref }) }
        var sections: [(String, [ModelInfo])] = [("Recent", recent)]
        var providers: [String] = []
        for model in self.models where !providers.contains(model.provider) {
            providers.append(model.provider)
        }
        for provider in providers {
            sections.append((provider, self.models.filter { $0.provider == provider }))
        }
        let items = modelListItems(theme: theme, sections: sections, current: self.current, select: self.select)
        let deletions = (0 ..< self.itemCount).map { ListViewDeleteItem(index: $0, directionHint: nil) }
        let insertions = items.enumerated().map { ListViewInsertItem(index: $0.offset, previousIndex: nil, item: $0.element, directionHint: nil) }
        self.listNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], updateOpaqueState: nil)
        self.itemCount = items.count
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let hadLayout = self.containerLayout != nil
        self.containerLayout = (layout, navigationBarHeight)
        var insets = layout.insets(options: [.input])
        insets.top += navigationBarHeight
        insets.left += layout.safeInsets.left
        insets.right += layout.safeInsets.right
        insets.bottom += 16.0
        self.searchDisplayController?.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
        self.listNode.frame = CGRect(origin: CGPoint(), size: layout.size)
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
        if !hadLayout {
            self.reload()
        }
    }

    func activateSearch(placeholderNode: SearchBarPlaceholderNode) {
        guard let (layout, navigationBarHeight) = self.containerLayout, self.searchDisplayController == nil else {
            return
        }
        let presentationData = self.context.theme.presentationData
        self.searchDisplayController = SearchDisplayController(presentationData: presentationData, contentNode: ModelSearchContainerNode(context: self.context, models: self.models, current: self.current, select: self.select), inline: true, cancel: { [weak self] in
            self?.requestDeactivateSearch()
        }, fieldStyle: placeholderNode.fieldStyle)
        self.searchDisplayController?.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
        self.searchDisplayController?.activate(insertSubnode: { [weak self, weak placeholderNode] subnode, isSearchBar in
            guard let self, let placeholderNode else {
                return
            }
            if isSearchBar {
                placeholderNode.supernode?.insertSubnode(subnode, aboveSubnode: placeholderNode)
            } else if let navigationBar = self.navigationBar {
                self.insertSubnode(subnode, belowSubnode: navigationBar)
            }
        }, placeholder: placeholderNode)
    }

    func deactivateSearch(placeholderNode: SearchBarPlaceholderNode) {
        if let searchDisplayController = self.searchDisplayController {
            searchDisplayController.deactivate(placeholder: placeholderNode)
            self.searchDisplayController = nil
        }
    }

    func scrollToTop() {
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
    }
}

/// The search's results over the list, as LanguageSelectionScreenNode's LocalizationListSearchContainerNode: dimmed until
/// there is a query, then the matching models.
private final class ModelSearchContainerNode: SearchDisplayControllerContentNode {
    private let context: AppContext
    private let models: [ModelInfo]
    private let current: String?
    private let select: (ModelInfo) -> Void
    private let dimNode = ASDisplayNode()
    private let listNode = ListViewImpl()
    private var itemCount = 0
    private var hasLayout = false
    private var pendingQuery: String?

    override var hasDim: Bool {
        return true
    }

    init(context: AppContext, models: [ModelInfo], current: String?, select: @escaping (ModelInfo) -> Void) {
        self.context = context
        self.models = models
        self.current = current
        self.select = select
        super.init()
        self.dimNode.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        self.listNode.backgroundColor = context.theme.list.blocksBackgroundColor
        self.listNode.isHidden = true
        self.addSubnode(self.dimNode)
        self.addSubnode(self.listNode)
        self.listNode.beganInteractiveDragging = { [weak self] _ in
            self?.dismissInput?()
        }
    }

    override func didLoad() {
        super.didLoad()
        self.dimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapGesture(_:))))
    }

    @objc private func dimTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.cancel?()
        }
    }

    override func searchTextUpdated(text: String) {
        guard self.hasLayout else {
            self.pendingQuery = text
            return
        }
        let query = text.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? [] : self.models.filter { modelMatches($0, query: query) }
        var providers: [String] = []
        for model in found where !providers.contains(model.provider) {
            providers.append(model.provider)
        }
        let sections = providers.map { provider in (provider, found.filter { $0.provider == provider }) }
        let items = modelListItems(theme: self.context.theme, sections: sections, current: self.current, select: self.select)
        let deletions = (0 ..< self.itemCount).map { ListViewDeleteItem(index: $0, directionHint: nil) }
        let insertions = items.enumerated().map { ListViewInsertItem(index: $0.offset, previousIndex: nil, item: $0.element, directionHint: nil) }
        self.listNode.transaction(deleteIndices: deletions, insertIndicesAndItems: insertions, updateIndicesAndItems: [], options: [.Synchronous, .PreferSynchronousDrawing], updateOpaqueState: nil)
        self.itemCount = items.count
        self.listNode.isHidden = query.isEmpty
        self.dimNode.isHidden = !query.isEmpty
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(x: 0.0, y: navigationBarHeight), size: CGSize(width: layout.size.width, height: layout.size.height - navigationBarHeight)))
        self.listNode.frame = CGRect(origin: CGPoint(), size: layout.size)
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: UIEdgeInsets(top: navigationBarHeight, left: layout.safeInsets.left, bottom: layout.insets(options: [.input]).bottom + 16.0, right: layout.safeInsets.right), duration: duration, curve: curve), stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
        if !self.hasLayout {
            self.hasLayout = true
            if let query = self.pendingQuery {
                self.pendingQuery = nil
                self.searchTextUpdated(text: query)
            }
        }
    }
}
