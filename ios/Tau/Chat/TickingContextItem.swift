import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ContextUI
import ContextControllerImpl
import TelegramPresentationData

/// A context menu row that changes as it is shown: Telegram's own action row, given a new item each second and laid
/// out again in place. New items for the whole menu would push a level each time; this keeps the menu still, as
/// Telegram keeps its "Seen by" row live.
final class TickingContextItem: ContextMenuCustomItem {
    private let make: () -> ContextMenuActionItem

    /// `make` is read now and once a second while the row is on screen.
    init(_ make: @escaping () -> ContextMenuActionItem) {
        self.make = make
    }

    func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        return TickingContextItemNode(presentationData: presentationData, make: self.make, getController: getController, actionSelected: actionSelected)
    }
}

private final class TickingContextItemNode: ASDisplayNode, ContextMenuCustomNode {
    private let make: () -> ContextMenuActionItem
    private var presentationData: PresentationData
    private let itemNode: ContextControllerActionsListActionItemNode
    private var timer: SwiftSignalKit.Timer?
    private var laidOut: (constrained: CGSize, size: CGSize)?

    init(presentationData: PresentationData, make: @escaping () -> ContextMenuActionItem, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.make = make
        self.presentationData = presentationData
        self.itemNode = ContextControllerActionsListActionItemNode(context: nil, getController: getController, requestDismiss: actionSelected, requestUpdateAction: { _, _ in }, item: make())
        super.init()
        self.addSubnode(self.itemNode)
    }

    deinit {
        self.timer?.invalidate()
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        guard self.timer == nil else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
            self?.tick()
        }, queue: Queue.mainQueue())
        self.timer = timer
        timer.start()
    }

    override func didExitHierarchy() {
        super.didExitHierarchy()
        self.timer?.invalidate()
        self.timer = nil
    }

    private func tick() {
        self.itemNode.setItem(item: self.make())
        guard let (constrained, size) = self.laidOut else {
            return
        }
        // The menu keeps its width: a longer line truncates rather than resizing the menu every second.
        let (_, apply) = self.itemNode.update(presentationData: self.presentationData, constrainedSize: constrained)
        apply(size, .immediate)
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let constrained = CGSize(width: constrainedWidth, height: constrainedHeight)
        let (minSize, apply) = self.itemNode.update(presentationData: self.presentationData, constrainedSize: constrained)
        return (minSize, { [weak self] size, transition in
            guard let self else {
                return
            }
            self.laidOut = (constrained, size)
            transition.updateFrame(node: self.itemNode, frame: CGRect(origin: CGPoint(), size: size))
            apply(size, transition)
        })
    }

    func updateTheme(presentationData: PresentationData) {
        self.presentationData = presentationData
    }

    func canBeHighlighted() -> Bool {
        return self.itemNode.canBeHighlighted()
    }

    func updateIsHighlighted(isHighlighted: Bool) {
        self.itemNode.updateIsHighlighted(isHighlighted: isHighlighted)
    }

    func performAction() {
        self.itemNode.performAction()
    }
}
