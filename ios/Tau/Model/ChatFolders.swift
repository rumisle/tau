import Foundation
import SwiftSignalKit

/// A chat folder, as Telegram's ChatListFilter (docs/folders.md): a tab over the chat list that shows the chats it
/// takes in and leaves out the ones it excludes. Telegram takes in chat types (contacts, groups, bots); tau's chats
/// differ by where they run, so a folder takes in servers and projects, plus chats by hand and two live categories:
/// chats an agent is working in, and unread ones.
struct ChatFolder: Codable, Equatable {
    struct Project: Codable, Hashable {
        var slot: Int
        var path: String
    }

    var id: Int32
    var title: String
    /// Every chat on these servers (TauServer.slot).
    var servers: [Int] = []
    /// Every chat in these projects.
    var projects: [Project] = []
    /// These chats (global IDs), wherever they are.
    var chats: [Int] = []
    /// Chats an agent is working in now.
    var working = false
    /// Chats with an answer not seen.
    var unread = false
    /// Never these chats.
    var excludedChats: [Int] = []
    /// Telegram's "Read" exclusion: only chats with something new.
    var excludeRead = false
    /// Telegram's "Archived" exclusion: on unless the folder is meant to show the archive too.
    var excludeArchived = true

    /// Whether it takes in anything at all.
    var isEmpty: Bool {
        return self.servers.isEmpty && self.projects.isEmpty && self.chats.isEmpty && !self.working && !self.unread
    }

    func contains(_ dialog: DialogModel) -> Bool {
        if self.excludedChats.contains(dialog.id) {
            return false
        }
        if self.excludeArchived && dialog.archived {
            return false
        }
        if self.excludeRead && !dialog.isUnread {
            return false
        }
        if self.chats.contains(dialog.id) || self.servers.contains(dialog.serverSlot) {
            return true
        }
        if self.working && (dialog.busy || !dialog.workingSubagents.isEmpty) {
            return true
        }
        if self.unread && dialog.isUnread {
            return true
        }
        return self.projects.contains(Project(slot: dialog.serverSlot, path: dialog.cwd))
    }
}

/// The user's folders, in their order, on this phone (UserDefaults): they span servers, so no one server keeps them.
/// The first time the list has chats, tau suggests its own: one a server while there are several, and the project
/// most chats are in.
final class ChatFolderStore {
    static let shared = ChatFolderStore()

    private static let key = "chatFolders"
    private static let seededKey = "chatFoldersSeeded"
    private let promise: ValuePromise<[ChatFolder]>
    private(set) var folders: [ChatFolder]
    private let isEphemeral: Bool

    private init() {
        // UI tests (servers from the command line) have no folders unless they ask: -folders YES starts from none, seeded
        // as on a first launch; -folders keep has the ones an earlier launch left.
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["folders"] as? String
        self.isEphemeral = ServerConfigStorage.isOverridden && argument == nil
        if argument == "YES" {
            UserDefaults.standard.removeObject(forKey: ChatFolderStore.key)
            UserDefaults.standard.removeObject(forKey: ChatFolderStore.seededKey)
        }
        if !self.isEphemeral, let data = UserDefaults.standard.data(forKey: ChatFolderStore.key), let folders = try? JSONDecoder().decode([ChatFolder].self, from: data) {
            self.folders = folders
        } else {
            self.folders = []
        }
        self.promise = ValuePromise(self.folders, ignoreRepeated: true)
    }

    var signal: Signal<[ChatFolder], NoError> {
        return self.promise.get()
    }

    func set(_ folders: [ChatFolder]) {
        self.folders = folders
        if !self.isEphemeral, let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: ChatFolderStore.key)
        }
        self.promise.set(folders)
    }

    func update(_ folder: ChatFolder) {
        var folders = self.folders
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        } else {
            folders.append(folder)
        }
        self.set(folders)
    }

    func remove(_ id: Int32) {
        self.set(self.folders.filter { $0.id != id })
    }

    func folder(_ id: Int32) -> ChatFolder? {
        return self.folders.first { $0.id == id }
    }

    var nextId: Int32 {
        return (self.folders.map(\.id).max() ?? 1) + 1
    }

    /// Folders worth having for these chats that the user does not have yet, as Telegram's recommended folders: each
    /// server while there are several, then the projects with the most chats, then the live categories.
    func suggestions(store: TauStore, dialogs: [DialogModel]) -> [ChatFolder] {
        var suggested: [ChatFolder] = []
        var id = self.nextId
        func add(_ folder: ChatFolder) {
            guard !self.folders.contains(where: { $0.servers == folder.servers && $0.projects == folder.projects && $0.working == folder.working && $0.unread == folder.unread && $0.chats.isEmpty }) else {
                return
            }
            suggested.append(folder)
            id += 1
        }
        let visible = dialogs.filter { !$0.archived && $0.parentConversationId == nil }
        if store.servers.count > 1 {
            for server in store.servers where visible.contains(where: { $0.serverSlot == server.slot }) {
                add(ChatFolder(id: id, title: server.name, servers: [server.slot]))
            }
        }
        var counts: [ChatFolder.Project: Int] = [:]
        for dialog in visible {
            counts[ChatFolder.Project(slot: dialog.serverSlot, path: dialog.cwd), default: 0] += 1
        }
        let projects = counts.filter { $0.value >= 2 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.path < $1.key.path }
        for (project, _) in projects.prefix(3) {
            add(ChatFolder(id: id, title: store.projectTitle(ProjectLocation(slot: project.slot, path: project.path)), projects: [project]))
        }
        add(ChatFolder(id: id, title: "Working", working: true))
        add(ChatFolder(id: id, title: "Unread", unread: true))
        return suggested
    }

    /// The first time there are chats: the servers and the biggest project as folders, so the tabs start useful.
    func seedIfNeeded(store: TauStore, dialogs: [DialogModel]) {
        guard !store.isDemo, !self.isEphemeral, !UserDefaults.standard.bool(forKey: ChatFolderStore.seededKey), !dialogs.isEmpty else {
            return
        }
        UserDefaults.standard.set(true, forKey: ChatFolderStore.seededKey)
        guard self.folders.isEmpty else {
            return
        }
        let suggestions = self.suggestions(store: store, dialogs: dialogs)
        let servers = suggestions.filter { !$0.servers.isEmpty }
        let project = suggestions.first { !$0.projects.isEmpty }
        self.set(servers + (project.map { [$0] } ?? []))
    }
}
