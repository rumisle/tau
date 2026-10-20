import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ContextUI
import ItemListUI
import TelegramPresentationData

/// What a row shows: a conversation, or the Archived Chats folder above them.
enum ChatListItemContent: Equatable {
    case dialog(DialogModel)
    case archive(ArchiveSummary)
}

/// The Archived Chats row: Telegram's group reference, which lists the chats inside.
struct ArchiveSummary: Equatable {
    var titles: [String]
    var date: Date?
    var unreadCount: Int
}

/// The chat list's actions, shared by its rows (Telegram's ChatListNodeInteraction).
final class ChatListInteraction {
    let open: (DialogModel) -> Void
    let openArchive: () -> Void
    let contextAction: (DialogModel, ContextControllerSourceNode, ContextGesture?) -> Void
    let toggleRead: (DialogModel) -> Void
    let setArchived: (DialogModel, Bool) -> Void
    let delete: (DialogModel) -> Void
    /// A row opened its swipe actions; the others close, as with Telegram's setPeerIdWithRevealedOptions.
    var revealedOptionsChanged: (Int?) -> Void = { _ in }

    init(open: @escaping (DialogModel) -> Void, openArchive: @escaping () -> Void, contextAction: @escaping (DialogModel, ContextControllerSourceNode, ContextGesture?) -> Void, toggleRead: @escaping (DialogModel) -> Void, setArchived: @escaping (DialogModel, Bool) -> Void, delete: @escaping (DialogModel) -> Void) {
        self.open = open
        self.openArchive = openArchive
        self.contextAction = contextAction
        self.toggleRead = toggleRead
        self.setArchived = setArchived
        self.delete = delete
    }
}

/// One chat list row. A trimmed port of Telegram-iOS ChatListUI/Sources/Node/ChatListItem.swift: same metrics (60 pt
/// avatar, 16/15/14 pt fonts, the same height formula and frames), the unread badge (ChatListBadgeNode, copied), and the
/// swipe actions (ItemListRevealOptionsItemNode, copied), with the peer replaced by a dialog whose project directory
/// takes the place of a group message's author line.
final class ChatListItem: ListViewItem {
    let theme: TauTheme
    let content: ChatListItemContent
    let interaction: ChatListInteraction

    init(theme: TauTheme, content: ChatListItemContent, interaction: ChatListInteraction) {
        self.theme = theme
        self.content = content
        self.interaction = interaction
    }

    var dialog: DialogModel? {
        if case let .dialog(dialog) = self.content {
            return dialog
        }
        return nil
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }

    var selectable: Bool {
        return true
    }

    var approximateHeight: CGFloat {
        return 76.0
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        switch self.content {
        case let .dialog(dialog):
            self.interaction.open(dialog)
        case .archive:
            self.interaction.openArchive()
        }
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = ChatListItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(.None) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? ChatListItemNode else {
                assertionFailure()
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params)
                Queue.mainQueue().async {
                    completion(layout, { _ in apply(animation) })
                }
            }
        }
    }
}

private let separatorHeight = 1.0 / UIScreen.main.scale
private let avatarDiameter: CGFloat = 60.0
private let titleFont = Font.semibold(16.0)
private let textFont = Font.regular(15.0)
private let dateFont = Font.regular(14.0)
// ChatListItem.swift: badgeFont and badgeDiameter at the default text size.
private let badgeFont = Font.with(size: 12.0, design: .regular, weight: .semibold, traits: [.monospacedNumbers])
private let badgeDiameter: CGFloat = 20.0

// ChatListItem.swift's reveal option icons and keys.
private let deleteIcon = ItemListRevealOptionIcon.animation(animation: "anim_delete", scale: 1.0, offset: 0.0, replaceColors: nil, flip: false, startFrame: 3)
private let readIcon = ItemListRevealOptionIcon.animation(animation: "anim_read", scale: 1.0, offset: 0.0, replaceColors: nil, flip: false, startFrame: 5)
private let unreadIcon = ItemListRevealOptionIcon.animation(animation: "anim_unread", scale: 1.0, offset: 0.0, replaceColors: [0x2194fa], flip: false, startFrame: 5)
private let archiveIcon = ItemListRevealOptionIcon.animation(animation: "anim_archive", scale: 1.0, offset: 2.0, replaceColors: [0xa9a9ad], flip: false, startFrame: 5)
private let unarchiveIcon = ItemListRevealOptionIcon.animation(animation: "anim_unarchive", scale: 0.52, offset: -6.0, replaceColors: [0xa9a9ad], flip: false, startFrame: 5)

private enum RevealOptionKey: Int32 {
    case delete
    case archive
    case unarchive
    case toggleMarkedUnread
}

private func rightRevealOptions(strings: PresentationStrings, theme: PresentationTheme, archived: Bool) -> [ItemListRevealOption] {
    let actions = theme.list.itemDisclosureActions
    var options: [ItemListRevealOption] = []
    options.append(ItemListRevealOption(key: RevealOptionKey.delete.rawValue, title: strings.Common_Delete, icon: deleteIcon, color: actions.destructive.fillColor, iconColor: actions.destructive.foregroundColor, textColor: theme.chatList.dateTextColor))
    if archived {
        options.append(ItemListRevealOption(key: RevealOptionKey.unarchive.rawValue, title: strings.ChatList_UnarchiveAction, icon: unarchiveIcon, color: actions.inactive.fillColor, iconColor: actions.inactive.foregroundColor, textColor: theme.chatList.dateTextColor))
    } else {
        options.append(ItemListRevealOption(key: RevealOptionKey.archive.rawValue, title: strings.ChatList_ArchiveAction, icon: archiveIcon, color: actions.inactive.fillColor, iconColor: actions.inactive.foregroundColor, textColor: theme.chatList.dateTextColor))
    }
    return options
}

private func leftRevealOptions(strings: PresentationStrings, theme: PresentationTheme, isUnread: Bool) -> [ItemListRevealOption] {
    let actions = theme.list.itemDisclosureActions
    if isUnread {
        return [ItemListRevealOption(key: RevealOptionKey.toggleMarkedUnread.rawValue, title: strings.DialogList_Read, icon: readIcon, color: actions.inactive.fillColor, iconColor: actions.neutral1.foregroundColor, textColor: theme.chatList.dateTextColor)]
    } else {
        return [ItemListRevealOption(key: RevealOptionKey.toggleMarkedUnread.rawValue, title: strings.DialogList_Unread, icon: unreadIcon, color: actions.accent.fillColor, iconColor: actions.accent.foregroundColor, textColor: theme.chatList.dateTextColor)]
    }
}

/// AvatarNode's archivedChatsIcon: the archive box on the theme's archive gradient.
private func archiveAvatarImage(theme: PresentationTheme, diameter: CGFloat) -> UIImage? {
    let colors = theme.chatList.pinnedArchiveAvatarColor
    let icon = generateTintedImage(image: UIImage(bundleImageName: "Avatar/ArchiveAvatarIcon"), color: colors.foregroundColor)
    return generateImage(CGSize(width: diameter, height: diameter), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.addEllipse(in: CGRect(origin: CGPoint(), size: size))
        context.clip()
        let (top, bottom) = colors.backgroundColors.colors
        let gradientColors = [bottom.cgColor, top.cgColor] as CFArray
        var locations: [CGFloat] = [1.0, 0.0]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradientColors, locations: &locations) {
            context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: [])
        }
        if let icon, let cgImage = icon.cgImage {
            let iconSize = icon.size
            let rect = CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: floor((size.height - iconSize.height) / 2.0)), size: iconSize)
            context.draw(cgImage, in: rect)
        }
    })
}

final class ChatListItemNode: ItemListRevealOptionsItemNode {
    /// As in Telegram's ChatListItemNode: the row's content sits in a context source, which shrinks it under the finger
    /// and is where the preview grows from.
    private let contextContainer = ContextControllerSourceNode()
    private let mainContentContainerNode = ASDisplayNode()
    private let highlightedBackgroundNode: ASDisplayNode
    private let avatarNode: ASImageNode
    private let titleNode: TextNode
    private let authorNode: TextNode
    private let textNode: TextNode
    private let dateNode: TextNode
    private let statusNode = ChatListStatusNode()
    private let badgeNode: ChatListBadgeNode
    private let separatorNode: ASDisplayNode
    private let busyIndicatorNode: BusyDotsNode

    private var item: ChatListItem?
    private var isHighlightedValue = false
    private var currentAvatarKey: String?

    var dialog: DialogModel? {
        return self.item?.dialog
    }

    init() {
        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isLayerBacked = true
        self.highlightedBackgroundNode.alpha = 0.0

        self.avatarNode = ASImageNode()
        self.avatarNode.isLayerBacked = true
        self.avatarNode.displaysAsynchronously = false

        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.authorNode = TextNode()
        self.authorNode.isUserInteractionEnabled = false
        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false
        self.dateNode = TextNode()
        self.dateNode.isUserInteractionEnabled = false
        self.badgeNode = ChatListBadgeNode()

        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true

        self.busyIndicatorNode = BusyDotsNode()

        super.init(layerBacked: false, rotated: false, seeThrough: false)

        self.addSubnode(self.separatorNode)
        self.addSubnode(self.contextContainer)
        self.contextContainer.addSubnode(self.mainContentContainerNode)
        self.mainContentContainerNode.addSubnode(self.avatarNode)
        self.mainContentContainerNode.addSubnode(self.titleNode)
        self.mainContentContainerNode.addSubnode(self.authorNode)
        self.mainContentContainerNode.addSubnode(self.textNode)
        self.mainContentContainerNode.addSubnode(self.dateNode)
        self.mainContentContainerNode.addSubnode(self.statusNode)
        self.mainContentContainerNode.addSubnode(self.badgeNode)
        self.mainContentContainerNode.addSubnode(self.busyIndicatorNode)

        self.contextContainer.activated = { [weak self] gesture, _ in
            guard let self, let item = self.item, let dialog = item.dialog else {
                gesture.cancel()
                return
            }
            item.interaction.contextAction(dialog, self.contextContainer, gesture)
        }
    }

    override func layoutForParams(_ params: ListViewItemLayoutParams, item: ListViewItem, neighbors: ListViewItemNeighbors) {
        guard let item = item as? ChatListItem else {
            return
        }
        let (layout, apply) = self.asyncLayout()(item, params)
        apply(.None)
        self.contentSize = layout.contentSize
        self.insets = layout.insets
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        self.isHighlightedValue = highlighted
        self.updateIsHighlighted(transition: (animated && !highlighted) ? .animated(duration: 0.3, curve: .easeInOut) : .immediate)
    }

    /// ChatListItemNode.updateIsHighlighted: a row with open swipe actions stays highlighted, with rounded corners.
    private func updateIsHighlighted(transition: ContainedViewLayoutTransition) {
        transition.updateCornerRadius(node: self.highlightedBackgroundNode, cornerRadius: self.isRevealOptionsActive ? 26.0 : 0.0)
        if self.isHighlightedValue || self.isRevealOptionsActive {
            if self.highlightedBackgroundNode.supernode == nil {
                self.insertSubnode(self.highlightedBackgroundNode, aboveSubnode: self.separatorNode)
                self.highlightedBackgroundNode.alpha = 0.0
            }
            self.highlightedBackgroundNode.layer.removeAllAnimations()
            transition.updateAlpha(layer: self.highlightedBackgroundNode.layer, alpha: 1.0)
        } else if self.highlightedBackgroundNode.supernode != nil {
            transition.updateAlpha(layer: self.highlightedBackgroundNode.layer, alpha: 0.0, completion: { [weak self] completed in
                if completed, let self, !(self.isHighlightedValue || self.isRevealOptionsActive) {
                    self.highlightedBackgroundNode.removeFromSupernode()
                }
            })
        }
        let separatorAlpha: CGFloat = (self.isRevealOptionsActive || self.isNextRevealOptionsActive) ? 0.0 : 1.0
        transition.updateAlpha(node: self.separatorNode, alpha: separatorAlpha)
    }

    override func updateRevealOffset(offset: CGFloat, transition: ContainedViewLayoutTransition) {
        super.updateRevealOffset(offset: offset, transition: transition)
        transition.updateBounds(node: self.contextContainer, bounds: self.contextContainer.frame.offsetBy(dx: -offset, dy: 0.0))
        let frame = self.highlightedBackgroundNode.frame
        transition.updateFrame(node: self.highlightedBackgroundNode, frame: CGRect(origin: CGPoint(x: offset, y: frame.minY), size: frame.size))
    }

    override func revealOptionsActiveStateUpdated(isActive: Bool, transition: ContainedViewLayoutTransition) {
        super.revealOptionsActiveStateUpdated(isActive: isActive, transition: transition)
        self.updateIsHighlighted(transition: transition)
    }

    override func nextRevealOptionsActiveStateUpdated(isActive: Bool, transition: ContainedViewLayoutTransition) {
        super.nextRevealOptionsActiveStateUpdated(isActive: isActive, transition: transition)
        self.updateIsHighlighted(transition: transition)
    }

    override func revealOptionsInteractivelyOpened() {
        self.item?.interaction.revealedOptionsChanged(self.item?.dialog?.id)
    }

    override func touchesToOtherItemsPrevented() {
        super.touchesToOtherItemsPrevented()
        self.item?.interaction.revealedOptionsChanged(nil)
    }

    /// Closes the swipe actions unless this is the row that opened them.
    func closeRevealOptions(except id: Int?) {
        if self.isDisplayingRevealedOptions, self.item?.dialog?.id != id {
            self.setRevealOptionsOpened(false, animated: true)
        }
    }

    override func revealOptionSelected(_ option: ItemListRevealOption, animated: Bool) {
        guard let item = self.item, let dialog = item.dialog else {
            return
        }
        var close = true
        switch option.key {
        case RevealOptionKey.delete.rawValue:
            item.interaction.delete(dialog)
        case RevealOptionKey.archive.rawValue, RevealOptionKey.unarchive.rawValue:
            // As Telegram: the action fills the row, then the row leaves the list.
            close = false
            self.animateRevealOptionsFill {
                item.interaction.setArchived(dialog, option.key == RevealOptionKey.archive.rawValue)
            }
        case RevealOptionKey.toggleMarkedUnread.rawValue:
            item.interaction.toggleRead(dialog)
        default:
            break
        }
        if close {
            self.setRevealOptionsOpened(false, animated: true)
        }
    }

    func asyncLayout() -> (_ item: ChatListItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeAuthorLayout = TextNode.asyncLayout(self.authorNode)
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        let makeDateLayout = TextNode.asyncLayout(self.dateNode)
        let makeBadgeLayout = self.badgeNode.asyncLayout()
        let currentAvatarKey = self.currentAvatarKey

        return { [weak self] item, params in
            let theme = item.theme.chatList
            let presentationTheme = item.theme.presentationTheme
            let strings = item.theme.presentationStrings

            let avatarLeftInset: CGFloat = 24.0 + avatarDiameter
            let leftInset = params.leftInset + avatarLeftInset
            let rawContentWidth = params.width - leftInset - params.rightInset - 18.0

            let title: String
            let author: String
            var date: Date?
            var statusState: ChatListStatusNodeState = .none
            let busy: Bool
            let badgeContent: ChatListBadgeContent
            let badgeImage: UIImage?
            var textString: NSAttributedString
            var textLines = 1
            let avatarKey: String
            switch item.content {
            case let .dialog(dialog):
                title = dialog.title
                author = dialog.projectName
                date = dialog.last?.date
                busy = dialog.busy
                avatarKey = "\(dialog.id):\(dialog.title)"
                if dialog.unreadCount > 0 {
                    badgeContent = .text(NSAttributedString(string: "\(dialog.unreadCount)", font: badgeFont, textColor: presentationTheme.chatList.unreadBadgeActiveTextColor))
                } else if dialog.markedUnread {
                    badgeContent = .blank
                } else {
                    badgeContent = .none
                }
                badgeImage = badgeContent.isEmpty ? nil : PresentationResourcesChatList.badgeBackgroundActive(presentationTheme, diameter: badgeDiameter)
                if let outgoing = dialog.outgoing {
                    // As Telegram's list shows an outgoing message from the moment it is sent: the clock, or the red
                    // badge once refused.
                    date = outgoing.date
                    statusState = outgoing.failed ? .failed(presentationTheme.chatList.failedFillColor, presentationTheme.chatList.failedForegroundColor) : .clock(PresentationResourcesChatList.clockFrameImage(presentationTheme), PresentationResourcesChatList.clockMinImage(presentationTheme))
                    textString = NSAttributedString(string: "You: " + outgoing.text.replacingOccurrences(of: "\n", with: " "), font: textFont, textColor: theme.messageTextColor)
                } else if dialog.busy {
                    textString = NSAttributedString(string: "working", font: textFont, textColor: theme.activityTextColor)
                } else if let last = dialog.last {
                    if last.role == .user {
                        // The agent reads at once: two checks, as a bot chat shows.
                        statusState = .read(presentationTheme.chatList.checkmarkColor)
                    }
                    let prefix: String
                    switch last.role {
                    case .user:
                        prefix = "You: "
                    case .assistant, .thinking:
                        prefix = ""
                    case let .tool(name):
                        prefix = name.isEmpty ? "" : "\(name): "
                    }
                    let flat = (prefix + plainPreview(last.text)).replacingOccurrences(of: "\n", with: " ")
                    textString = NSAttributedString(string: flat, font: textFont, textColor: theme.messageTextColor)
                } else {
                    textString = NSAttributedString(string: "No messages yet", font: textFont, textColor: theme.messageTextColor)
                }
            case let .archive(summary):
                title = strings.ChatList_ArchivedChatsTitle
                author = ""
                date = summary.date
                busy = false
                avatarKey = "archive"
                // Archived chats count as muted: a gray badge.
                if summary.unreadCount > 0 {
                    badgeContent = .text(NSAttributedString(string: "\(summary.unreadCount)", font: badgeFont, textColor: presentationTheme.chatList.unreadBadgeInactiveTextColor))
                    badgeImage = PresentationResourcesChatList.badgeBackgroundInactive(presentationTheme, diameter: badgeDiameter)
                } else {
                    badgeContent = .none
                    badgeImage = nil
                }
                textString = NSAttributedString(string: summary.titles.joined(separator: ", "), font: textFont, textColor: theme.messageTextColor)
                textLines = 2
            }

            let dateString = date.map { chatListDateString($0) } ?? ""
            let (dateLayout, dateApply) = makeDateLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: dateString, font: dateFont, textColor: theme.dateTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: rawContentWidth, height: .greatestFiniteMagnitude)))
            let (badgeSize, badgeApply) = makeBadgeLayout(CGSize(width: rawContentWidth, height: .greatestFiniteMagnitude), badgeDiameter, badgeFont, badgeImage, badgeContent)
            let badgeInset: CGFloat = badgeContent.isEmpty ? 0.0 : badgeSize.width + 5.0

            // ChatListItem.swift: 24 pt for the status before the date.
            let statusWidth: CGFloat = statusState == .none ? 0.0 : 24.0
            let titleRectWidth = rawContentWidth - dateLayout.size.width - 10.0 - statusWidth
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: title, font: titleFont, textColor: theme.titleColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(10.0, titleRectWidth), height: .greatestFiniteMagnitude)))

            // The project directory reads like the author line of a group chat.
            let (authorLayout, authorApply) = makeAuthorLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: author, font: textFont, textColor: theme.authorNameColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: rawContentWidth - badgeInset, height: .greatestFiniteMagnitude)))

            let busyIndicatorWidth: CGFloat = busy ? 24.0 : 0.0
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: textString, maximumNumberOfLines: textLines, truncationType: .end, constrainedSize: CGSize(width: rawContentWidth - busyIndicatorWidth - badgeInset, height: .greatestFiniteMagnitude)))

            // Telegram measures one line of the title font to size the row (ChatListItem.swift, "measureLayout").
            let (measureLayout, _) = TextNode.asyncLayout(nil)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: " ", font: titleFont, textColor: .black), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: titleRectWidth, height: .greatestFiniteMagnitude)))
            let measureHeight = measureLayout.size.height
            let titleSpacing: CGFloat = -1.0
            let authorSpacing: CGFloat = -3.0
            var itemHeight: CGFloat = 8.0 * 2.0 + 1.0
            itemHeight -= 21.0
            itemHeight += titleLayout.size.height
            itemHeight += measureHeight * 3.0
            itemHeight += titleSpacing
            itemHeight += authorSpacing

            let rawContentRect = CGRect(origin: CGPoint(x: 2.0, y: 8.0), size: CGSize(width: rawContentWidth, height: itemHeight - 12.0 - 9.0))
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: itemHeight), insets: UIEdgeInsets())

            let avatarImage: UIImage?
            if currentAvatarKey != avatarKey || item.theme !== self?.item?.theme {
                switch item.content {
                case let .dialog(dialog):
                    avatarImage = Avatar.image(letters: Avatar.letters(dialog.title), colorIndex: dialog.id, diameter: avatarDiameter)
                case .archive:
                    avatarImage = archiveAvatarImage(theme: presentationTheme, diameter: avatarDiameter)
                }
            } else {
                avatarImage = nil
            }

            return (layout, { animation in
                guard let strongSelf = self else {
                    return
                }
                let previousItem = strongSelf.item
                strongSelf.item = item
                strongSelf.currentAvatarKey = avatarKey
                let transition = animation.transition

                strongSelf.highlightedBackgroundNode.backgroundColor = theme.itemHighlightedBackgroundColor
                strongSelf.separatorNode.backgroundColor = theme.itemSeparatorColor
                if let avatarImage {
                    strongSelf.avatarNode.image = avatarImage
                }

                let _ = titleApply()
                let _ = authorApply()
                let _ = textApply()
                let _ = dateApply()
                badgeApply(previousItem != nil && animation.isAnimated, false)

                let contentRect = rawContentRect.offsetBy(dx: leftInset, dy: 0.0)
                let avatarFrame = CGRect(origin: CGPoint(x: params.leftInset + 16.0, y: floor((itemHeight - avatarDiameter) / 2.0)), size: CGSize(width: avatarDiameter, height: avatarDiameter))
                transition.updateFrame(node: strongSelf.avatarNode, frame: avatarFrame)

                let titleFrame = CGRect(origin: CGPoint(x: contentRect.origin.x, y: contentRect.origin.y + UIScreenPixel), size: titleLayout.size)
                transition.updateFrame(node: strongSelf.titleNode, frame: titleFrame)

                let authorFrame = CGRect(origin: CGPoint(x: contentRect.origin.x - 1.0, y: contentRect.minY + titleLayout.size.height - 2.0), size: authorLayout.size)
                transition.updateFrame(node: strongSelf.authorNode, frame: authorFrame)

                let textY = author.isEmpty ? authorFrame.minY : authorFrame.minY + authorLayout.size.height - 3.0
                let textFrame = CGRect(origin: CGPoint(x: contentRect.origin.x - 1.0 + busyIndicatorWidth, y: textY), size: textLayout.size)
                transition.updateFrame(node: strongSelf.textNode, frame: textFrame)

                strongSelf.busyIndicatorNode.isHidden = !busy
                strongSelf.busyIndicatorNode.color = theme.activityTextColor
                transition.updateFrame(node: strongSelf.busyIndicatorNode, frame: CGRect(origin: CGPoint(x: contentRect.origin.x, y: textFrame.midY - 4.0), size: CGSize(width: 20.0, height: 8.0)))

                let dateFrame = CGRect(origin: CGPoint(x: contentRect.maxX - dateLayout.size.width, y: contentRect.origin.y + 2.0), size: dateLayout.size)
                transition.updateFrame(node: strongSelf.dateNode, frame: dateFrame)
                let statusSize = CGSize(width: 24.0, height: 24.0)
                strongSelf.statusNode.frame = CGRect(origin: CGPoint(x: contentRect.maxX - dateLayout.size.width - statusSize.width, y: contentRect.origin.y + 2.0 - UIScreenPixel + floor((dateLayout.size.height - statusSize.height) / 2.0)), size: statusSize)
                strongSelf.statusNode.fontSize = 17.0
                let _ = strongSelf.statusNode.transitionToState(statusState, animated: previousItem != nil && animation.isAnimated)

                // ChatListItem.swift: the badge sits at the bottom right, raised by rightAccessoryVerticalOffset.
                let badgeFrame = CGRect(x: contentRect.maxX - badgeSize.width, y: contentRect.maxY - badgeSize.height - 4.0, width: badgeSize.width, height: badgeSize.height)
                transition.updateFrame(node: strongSelf.badgeNode, frame: badgeFrame)

                let separatorX = leftInset + rawContentRect.origin.x
                transition.updateFrame(node: strongSelf.separatorNode, frame: CGRect(origin: CGPoint(x: separatorX, y: itemHeight - separatorHeight), size: CGSize(width: params.width - separatorX, height: separatorHeight)))
                strongSelf.highlightedBackgroundNode.frame = CGRect(origin: CGPoint(x: strongSelf.revealOffset, y: -separatorHeight), size: CGSize(width: params.width, height: itemHeight + separatorHeight))
                let rowFrame = CGRect(origin: CGPoint(), size: CGSize(width: params.width, height: itemHeight))
                strongSelf.contextContainer.frame = rowFrame
                strongSelf.contextContainer.bounds = rowFrame.offsetBy(dx: -strongSelf.revealOffset, dy: 0.0)
                strongSelf.mainContentContainerNode.frame = rowFrame

                strongSelf.updateLayout(size: layout.contentSize, leftInset: params.leftInset, rightInset: params.rightInset)
                switch item.content {
                case let .dialog(dialog):
                    strongSelf.setRevealOptions((
                        left: leftRevealOptions(strings: strings, theme: presentationTheme, isUnread: dialog.unreadCount > 0 || dialog.markedUnread),
                        right: rightRevealOptions(strings: strings, theme: presentationTheme, archived: dialog.archived)
                    ))
                case .archive:
                    strongSelf.setRevealOptions((left: [], right: []))
                }
            })
        }
    }
}

/// Message text without Markdown syntax, for one-line previews.
func plainPreview(_ text: String) -> String {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    guard let parsed = try? AttributedString(markdown: text, options: options) else {
        return text
    }
    return String(parsed.characters)
}

/// Telegram's chat list date: time today, weekday this week, date otherwise.
func chatListDateString(_ date: Date) -> String {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        formatter.dateFormat = "EEE"
    } else {
        formatter.dateFormat = "dd.MM.yy"
    }
    return formatter.string(from: date)
}

/// Three pulsing dots, like Telegram's typing indicator in the chat list.
final class BusyDotsNode: ASDisplayNode {
    private var dots: [CALayer] = []

    var color: UIColor = .black {
        didSet {
            for dot in self.dots {
                dot.backgroundColor = self.color.cgColor
            }
        }
    }

    // Nodes are created off the main thread (ListView lays rows out asynchronously); layers only exist from didLoad.
    override func didLoad() {
        super.didLoad()
        self.dots = (0 ..< 3).map { _ in
            let dot = CALayer()
            dot.cornerRadius = 2.5
            dot.backgroundColor = self.color.cgColor
            self.layer.addSublayer(dot)
            return dot
        }
        self.startAnimations()
    }

    override func layout() {
        super.layout()
        for (index, dot) in self.dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * 7.0, y: (self.bounds.height - 5.0) / 2.0, width: 5.0, height: 5.0)
        }
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        // Layers drop their animations when they leave the window.
        self.startAnimations()
    }

    private func startAnimations() {
        for (index, dot) in self.dots.enumerated() where dot.animation(forKey: "pulse") == nil {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.3, 1.0, 0.3]
            animation.keyTimes = [0.0, 0.5, 1.0]
            animation.duration = 1.0
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            dot.add(animation, forKey: "pulse")
        }
    }
}
