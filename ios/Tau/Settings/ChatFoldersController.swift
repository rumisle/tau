import UIKit
import Display
import SwiftSignalKit
import UndoUI
import TelegramPresentationData

private let colorBlue = UIColor(rgb: 0x0079ff)
private let colorViolet = UIColor(rgb: 0xAF52DE)
private let colorOrange = UIColor(rgb: 0xFF9F0A)
private let colorLightBlue = UIColor(rgb: 0x32ADE6)

/// The icons of a folder's parts, as ChatListFilterPresetController draws its chat types: Telegram's filter glyphs on
/// colored squares; a server and a project as Settings shows them; a chat its avatar.
enum ChatFolderIcons {
    static let working = renderSettingsIcon(name: "Chat List/Filters/Bot", backgroundColors: [colorViolet])
    static let unread = renderSettingsIcon(name: "Chat List/Filters/NewChats", backgroundColors: [colorBlue])
    static let read = renderSettingsIcon(name: "Chat List/Filters/Read", backgroundColors: [colorLightBlue])
    static let archived = renderSettingsIcon(name: "Chat List/Filters/Archive", backgroundColors: [colorOrange])
    static let folder = renderSettingsIcon(name: "Item List/Icons/Folder", backgroundColors: [colorLightBlue])
}

extension ChatFolder {
    /// "12 chats", as Telegram's folder list counts them.
    func countText(_ dialogs: [DialogModel]) -> String {
        let count = dialogs.filter { $0.parentConversationId == nil && self.contains($0) }.count
        return count == 0 ? "No chats" : count == 1 ? "1 chat" : "\(count) chats"
    }

    /// What a suggested folder takes in, in a few words.
    func summary(store: TauStore) -> String {
        if self.working {
            return "Chats an agent is working in"
        } else if self.unread {
            return "Chats with answers you have not seen"
        } else if let slot = self.servers.first, self.servers.count == 1 {
            return "Every chat on \(store.server(slot)?.name ?? "the server")"
        }
        return ""
    }
}

/// Settings > Chat Folders, as Telegram's ChatListFilterPresetListController: its animation and what folders are for,
/// the user's folders (a tap edits one), Create a New Folder, and recommended ones to add with a tap.
final class ChatFoldersController: SettingsListController {
    private var disposable: Disposable?
    private var dialogs: [DialogModel] = []

    init(context: AppContext) {
        super.init(context: context, title: "Chat Folders")
        self.disposable = (combineLatest(ChatFolderStore.shared.signal, context.store.dialogsSignal()) |> deliverOnMainQueue).start(next: { [weak self] _, dialogs in
            self?.dialogs = dialogs
            self?.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let store = ChatFolderStore.shared
        let folders = store.folders
        var items: [ListViewItem] = [
            SettingsAnimationHeaderItem(theme: theme, animation: "ChatListFolders", text: "Create folders for different groups of chats and quickly switch between them."),
            SettingsTextItem(theme: theme, text: "Folders", kind: .header),
        ]
        let plus = PresentationResourcesItemList.plusIconImage(theme.presentationTheme)
        items.append(SettingsRowItem(theme: theme, icon: plus.map { centeredIcon($0) }, title: "Create a New Folder", titleColor: theme.presentationTheme.list.itemAccentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: folders.isEmpty), action: { [weak self] in
            self?.edit(nil)
        }))
        for (index, folder) in folders.enumerated() {
            items.append(SettingsRowItem(theme: theme, icon: ChatFolderIcons.folder, title: folder.title, subtitle: folder.countText(self.dialogs), accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: false, isLast: index == folders.count - 1), action: { [weak self] in
                self?.edit(folder)
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: folders.count > 1 ? "Long-press a tab over the chats to reorder the folders." : "Folders show as tabs over the chats; swipe between them.", kind: .footer))
        let suggestions = store.suggestions(store: self.context.store, dialogs: self.dialogs)
        if !suggestions.isEmpty {
            items.append(SettingsTextItem(theme: theme, text: "Recommended Folders", kind: .header))
            for (index, folder) in suggestions.enumerated() {
                items.append(SettingsRowItem(theme: theme, icon: nil, title: folder.title, subtitle: folder.summary(store: self.context.store), accessory: .button("Add"), position: SettingsRowPosition(isFirst: index == 0, isLast: index == suggestions.count - 1), action: { [weak self] in
                    var added = folder
                    added.id = ChatFolderStore.shared.nextId
                    ChatFolderStore.shared.update(added)
                    self?.reload()
                }))
            }
        }
        return items
    }

    private func edit(_ folder: ChatFolder?) {
        (self.navigationController as? NavigationController)?.pushViewController(ChatFolderEditController(context: self.context, folder: folder))
    }
}

/// An icon centered in the 30 pt icon box, for the glyphs that come without a square.
func centeredIcon(_ image: UIImage) -> UIImage {
    return generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        UIGraphicsPushContext(context)
        image.draw(at: CGPoint(x: floor((size.width - image.size.width) / 2.0), y: floor((size.height - image.size.height) / 2.0)))
        UIGraphicsPopContext()
    }) ?? image
}

/// A new folder, or one to change, as Telegram's ChatListFilterPresetController: its name, the chats it takes in, the
/// ones it leaves out, and Delete Folder. Nothing is kept until Create or Done.
final class ChatFolderEditController: SettingsListController {
    private var folder: ChatFolder
    private let isNew: Bool
    private var dialogs: [DialogModel] = []
    private var disposable: Disposable?
    /// The name as typed until the user changes the parts, then what they would make it.
    private var nameEdited: Bool

    init(context: AppContext, folder: ChatFolder?) {
        self.isNew = folder == nil
        self.folder = folder ?? ChatFolder(id: ChatFolderStore.shared.nextId, title: "")
        self.nameEdited = folder != nil
        super.init(context: context, title: folder == nil ? "New Folder" : "Edit Folder")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: folder == nil ? "Create" : context.theme.presentationStrings.Common_Done, style: .done, target: self, action: #selector(self.donePressed))
        self.disposable = (context.store.dialogsSignal() |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            self?.dialogs = dialogs
            self?.reload()
        })
        self.updateDone()
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
    }

    private func updateDone() {
        let title = self.folder.title.trimmingCharacters(in: .whitespaces)
        self.navigationItem.rightBarButtonItem?.isEnabled = !title.isEmpty && !self.folder.isEmpty
    }

    @objc private func donePressed() {
        self.view.endEditing(true)
        var folder = self.folder
        folder.title = folder.title.trimmingCharacters(in: .whitespaces)
        guard !folder.title.isEmpty, !folder.isEmpty else {
            return
        }
        ChatFolderStore.shared.update(folder)
        (self.navigationController as? NavigationController)?.popViewController(animated: true)
    }

    /// A name for what was picked, as Telegram names a folder of one chat type: the server, the project, the category.
    private func suggestedName(_ folder: ChatFolder) -> String {
        let store = self.context.store
        if folder.servers.count == 1 && folder.chats.isEmpty, let server = store.server(folder.servers[0]) {
            return server.name
        }
        if folder.working && folder.servers.isEmpty && folder.chats.isEmpty && !folder.unread {
            return "Working"
        }
        if folder.unread && folder.servers.isEmpty && folder.chats.isEmpty && !folder.working {
            return "Unread"
        }
        return folder.title
    }

    private func pick(_ mode: ChatFolderPickerController.Mode) {
        let picker = ChatFolderPickerController(context: self.context, folder: self.folder, mode: mode, apply: { [weak self] folder in
            guard let self else {
                return
            }
            var folder = folder
            if !self.nameEdited {
                folder.title = self.suggestedName(folder)
            }
            self.folder = folder
            self.updateDone()
            self.reload()
        })
        (self.navigationController as? NavigationController)?.pushViewController(picker)
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let store = self.context.store
        let accent = theme.presentationTheme.list.itemAccentColor
        let plus = PresentationResourcesItemList.plusIconImage(theme.presentationTheme).map { centeredIcon($0) }
        var items: [ListViewItem] = []
        if self.isNew {
            items.append(SettingsAnimationHeaderItem(theme: theme, animation: "ChatListNewFolder", text: "Choose the chats this folder shows: whole servers or single chats."))
        }
        items.append(SettingsTextItem(theme: theme, text: "Folder Name", kind: .header))
        items.append(SettingsInputItem(theme: theme, text: self.folder.title, placeholder: "Folder Name", maxLength: 24, changed: { [weak self] text in
            self?.folder.title = text
            self?.nameEdited = !text.isEmpty
            self?.updateDone()
        }))

        let known = Dictionary(self.dialogs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rows(_ parts: [(UIImage?, String, String?)], add: String, mode: ChatFolderPickerController.Mode) {
            items.append(SettingsRowItem(theme: theme, icon: plus, title: add, titleColor: accent, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: parts.isEmpty), action: { [weak self] in
                self?.pick(mode)
            }))
            for (index, part) in parts.enumerated() {
                items.append(SettingsRowItem(theme: theme, icon: part.0, title: part.1, subtitle: part.2, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: index == parts.count - 1), action: { [weak self] in
                    self?.pick(mode)
                }))
            }
        }

        items.append(SettingsTextItem(theme: theme, text: "Included Chats", kind: .header))
        var included: [(UIImage?, String, String?)] = []
        if self.folder.working {
            included.append((ChatFolderIcons.working, "Working", nil))
        }
        if self.folder.unread {
            included.append((ChatFolderIcons.unread, "Unread", nil))
        }
        for slot in self.folder.servers {
            included.append((SettingsIcon.server, store.server(slot)?.name ?? "Server", "Server"))
        }
        for id in self.folder.chats {
            if let dialog = known[id] {
                included.append((Avatar.image(letters: Avatar.letters(dialog.title), colorIndex: dialog.id, diameter: 30.0), dialog.title, dialog.serverName))
            }
        }
        rows(included, add: "Add Chats", mode: .include)
        items.append(SettingsTextItem(theme: theme, text: "Choose chats or servers that will appear in this folder.", kind: .footer))

        items.append(SettingsTextItem(theme: theme, text: "Excluded Chats", kind: .header))
        var excluded: [(UIImage?, String, String?)] = []
        if self.folder.excludeRead {
            excluded.append((ChatFolderIcons.read, "Read", nil))
        }
        if self.folder.excludeArchived {
            excluded.append((ChatFolderIcons.archived, "Archived", nil))
        }
        for id in self.folder.excludedChats {
            if let dialog = known[id] {
                excluded.append((Avatar.image(letters: Avatar.letters(dialog.title), colorIndex: dialog.id, diameter: 30.0), dialog.title, dialog.serverName))
            }
        }
        rows(excluded, add: "Remove Chats", mode: .exclude)
        items.append(SettingsTextItem(theme: theme, text: "Choose chats or types of chats that will never appear in this folder.", kind: .footer))

        if !self.isNew {
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Delete Folder", titleColor: theme.presentationTheme.list.itemDestructiveColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
                guard let self else {
                    return
                }
                ChatFolderStore.shared.remove(self.folder.id)
                (self.navigationController as? NavigationController)?.popViewController(animated: true)
            }))
        }
        return items
    }
}

/// Add Chats, or Remove Chats, as Telegram's chat picker for a folder: the types of chats first (Working and Unread to
/// take in; Read and Archived to leave out), then servers to take in, then each chat, with a check on
/// what is picked. Done gives the folder back.
final class ChatFolderPickerController: SettingsListController {
    enum Mode {
        case include
        case exclude
    }

    private var folder: ChatFolder
    private let mode: Mode
    private let apply: (ChatFolder) -> Void
    private var dialogs: [DialogModel] = []
    private var disposable: Disposable?

    init(context: AppContext, folder: ChatFolder, mode: Mode, apply: @escaping (ChatFolder) -> Void) {
        self.folder = folder
        self.mode = mode
        self.apply = apply
        super.init(context: context, title: mode == .include ? "Add Chats" : "Remove Chats")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: context.theme.presentationStrings.Common_Done, style: .done, target: self, action: #selector(self.donePressed))
        self.disposable = (context.store.dialogsSignal() |> take(1) |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            self?.dialogs = dialogs.filter { $0.parentConversationId == nil }
            self?.reload()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable?.dispose()
    }

    @objc private func donePressed() {
        self.apply(self.folder)
        (self.navigationController as? NavigationController)?.popViewController(animated: true)
    }

    private func toggle<T: Equatable>(_ list: inout [T], _ value: T) {
        if let index = list.firstIndex(of: value) {
            list.remove(at: index)
        } else {
            list.append(value)
        }
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let store = self.context.store
        var items: [ListViewItem] = []
        func section(_ title: String, _ rows: [(UIImage?, String, String?, Bool, () -> Void)]) {
            guard !rows.isEmpty else {
                return
            }
            items.append(SettingsTextItem(theme: theme, text: title, kind: .header))
            for (index, row) in rows.enumerated() {
                let action = row.4
                items.append(SettingsRowItem(theme: theme, icon: row.0, title: row.1, subtitle: row.2, accessory: .checkmark(row.3), position: SettingsRowPosition(isFirst: index == 0, isLast: index == rows.count - 1), action: { [weak self] in
                    action()
                    self?.reload()
                }))
            }
        }
        switch self.mode {
        case .include:
            section("Chat Types", [
                (ChatFolderIcons.working, "Working", "Chats an agent is working in", self.folder.working, { [weak self] in self?.folder.working.toggle() }),
                (ChatFolderIcons.unread, "Unread", "Chats with answers you have not seen", self.folder.unread, { [weak self] in self?.folder.unread.toggle() }),
            ])
            if store.servers.count > 1 {
                section("Servers", store.servers.map { server in
                    let slot = server.slot
                    let count = self.dialogs.filter { $0.serverSlot == slot }.count
                    return (SettingsIcon.server, server.name, count == 1 ? "1 chat" : "\(count) chats", self.folder.servers.contains(slot), { [weak self] in
                        guard let self else {
                            return
                        }
                        self.toggle(&self.folder.servers, slot)
                    })
                })
            }
        case .exclude:
            section("Chat Types", [
                (ChatFolderIcons.read, "Read", "Chats with nothing new", self.folder.excludeRead, { [weak self] in self?.folder.excludeRead.toggle() }),
                (ChatFolderIcons.archived, "Archived", "Chats in Archived Chats", self.folder.excludeArchived, { [weak self] in self?.folder.excludeArchived.toggle() }),
            ])
        }
        let visible = self.dialogs.filter { !$0.archived || self.mode == .exclude || self.folder.chats.contains($0.id) }
        section("Chats", ChatListControllerNode.pinnedFirst(visible).map { dialog in
            let id = dialog.id
            let selected = self.mode == .include ? self.folder.chats.contains(id) : self.folder.excludedChats.contains(id)
            return (Avatar.image(letters: Avatar.letters(dialog.title), colorIndex: dialog.id, diameter: 30.0), dialog.title, dialog.serverName, selected, { [weak self] in
                guard let self else {
                    return
                }
                switch self.mode {
                case .include:
                    self.toggle(&self.folder.chats, id)
                    self.folder.excludedChats.removeAll { $0 == id }
                case .exclude:
                    self.toggle(&self.folder.excludedChats, id)
                    self.folder.chats.removeAll { $0 == id }
                }
            })
        })
        return items
    }
}
