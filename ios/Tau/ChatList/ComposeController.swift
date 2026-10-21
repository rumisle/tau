import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

/// Where a chat runs: a folder on one server.
struct ProjectLocation: Equatable {
    var slot: Int
    var path: String
}

extension TauStore {
    /// `~/work/tau`, or `nest:~/work/tau` once there is more than one server, as a shell prompt names a host.
    func describe(_ location: ProjectLocation) -> String {
        let home = self.server(location.slot)?.home
        let path = abbreviate(location.path, home: home)
        if self.servers.count > 1, let server = self.server(location.slot) {
            return "\(server.name):\(path)"
        }
        return path
    }

    /// The folder's own name, or Home for the home directory.
    func projectTitle(_ location: ProjectLocation) -> String {
        if let home = self.server(location.slot)?.home, location.path == home {
            return "Home"
        }
        return (location.path as NSString).lastPathComponent
    }

    /// The projects of recent chats, newest first, one entry per folder on each server.
    func recentProjects(_ dialogs: [DialogModel]) -> [ProjectLocation] {
        var seen = Set<String>()
        var result: [ProjectLocation] = []
        for dialog in dialogs where dialog.parentConversationId == nil {
            let key = "\(dialog.serverSlot):\(dialog.cwd)"
            if seen.insert(key).inserted, self.server(dialog.serverSlot) != nil {
                result.append(ProjectLocation(slot: dialog.serverSlot, path: dialog.cwd))
            }
        }
        return result
    }

    /// Where a new chat starts: the most recent project, else the first server's home.
    func defaultLocation(_ dialogs: [DialogModel]) -> ProjectLocation? {
        if let recent = self.recentProjects(dialogs).first {
            return recent
        }
        guard let server = self.servers.first else {
            return nil
        }
        return ProjectLocation(slot: server.slot, path: server.home ?? "~")
    }
}

/// Choose Project: the projects of recent chats from every server, then each server's folders from its home. Modal,
/// with Cancel, as the model picker; choosing closes it.
final class ProjectPickerController: SettingsListController {
    private let current: ProjectLocation?
    private let choose: (ProjectLocation) -> Void
    private var recent: [ProjectLocation] = []
    private var dialogsDisposable: Disposable?

    init(context: AppContext, current: ProjectLocation?, choose: @escaping (ProjectLocation) -> Void) {
        self.current = current
        self.choose = choose
        super.init(context: context, title: "Project")
        self.navigationPresentation = .modal
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: context.theme.presentationStrings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.dialogsDisposable?.dispose()
    }

    @objc private func cancelPressed() {
        self.dismiss()
    }

    override func displayNodeDidLoad() {
        super.displayNodeDidLoad()
        self.dialogsDisposable = (self.context.store.dialogsSignal() |> take(1) |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            guard let self else {
                return
            }
            self.recent = self.context.store.recentProjects(dialogs)
            self.reload()
        })
    }

    private func picked(_ location: ProjectLocation) {
        self.choose(location)
        self.dismiss()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let store = self.context.store
        var items: [ListViewItem] = []
        if !self.recent.isEmpty {
            items.append(SettingsTextItem(theme: theme, text: "Recent Projects", kind: .header))
            let shown = Array(self.recent.prefix(12))
            for (index, location) in shown.enumerated() {
                items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.projectIcon(for: location.path), title: store.projectTitle(location), subtitle: store.describe(location), accessory: .checkmark(location == self.current), position: SettingsRowPosition(isFirst: index == 0, isLast: index == shown.count - 1), action: { [weak self] in
                    self?.picked(location)
                }))
            }
        }
        let servers = store.servers
        items.append(SettingsTextItem(theme: theme, text: servers.count > 1 ? "Servers" : "Browse", kind: .header))
        for (index, server) in servers.enumerated() {
            let home = ProjectLocation(slot: server.slot, path: server.home ?? "~")
            items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.projects, title: servers.count > 1 ? server.name : "Home", subtitle: store.describe(home), accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: index == 0, isLast: index == servers.count - 1), action: { [weak self] in
                guard let self else {
                    return
                }
                self.push(FolderBrowserController(context: self.context, server: server, path: server.home, open: { [weak self] path in
                    self?.picked(ProjectLocation(slot: server.slot, path: path))
                }))
            }))
        }
        items.append(SettingsTextItem(theme: theme, text: "The agent runs commands and edits files in this folder on the server.", kind: .footer))
        return items
    }
}

/// One folder of a server, from `fs.list`: subfolders to go into, and a row to choose this one.
final class FolderBrowserController: SettingsListController {
    private let server: TauServer
    private let path: String?
    private let open: (String) -> Void
    private var listing: DirectoryListing?
    private var error: String?
    private let disposable = MetaDisposable()

    init(context: AppContext, server: TauServer, path: String?, open: @escaping (String) -> Void) {
        self.server = server
        self.path = path
        self.open = open
        super.init(context: context, title: path.map { ($0 as NSString).lastPathComponent } ?? "Home")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposable.dispose()
    }

    override func displayNodeDidLoad() {
        super.displayNodeDidLoad()
        self.disposable.set((self.server.listDirectory(self.path) |> deliverOnMainQueue).start(next: { [weak self] (listing: DirectoryListing) in
            guard let self else {
                return
            }
            self.listing = listing
            self.title = (listing.path as NSString).lastPathComponent
            self.reload()
        }, error: { [weak self] (error: RequestError) in
            self?.error = error.message
            self?.reload()
        }))
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        guard let listing = self.listing else {
            return [SettingsTextItem(theme: theme, text: self.error ?? "Loading…", kind: .footer)]
        }
        var items: [ListViewItem] = []
        items.append(SettingsTextItem(theme: theme, text: self.context.store.describe(ProjectLocation(slot: self.server.slot, path: listing.path)), kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.model, title: "Use This Folder", titleColor: theme.list.itemAccentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
            self?.open(listing.path)
        }))
        let folders = listing.entries.filter(\.isDirectory)
        if !folders.isEmpty {
            items.append(SettingsTextItem(theme: theme, text: "Folders", kind: .header))
            for (index, entry) in folders.enumerated() {
                let position = SettingsRowPosition(isFirst: index == 0, isLast: index == folders.count - 1)
                let path = (listing.path as NSString).appendingPathComponent(entry.name)
                items.append(SettingsRowItem(theme: theme, icon: entry.isRepository ? SettingsIcon.repository : SettingsIcon.projects, title: entry.name, accessory: .disclosure(label: entry.isRepository ? "git" : ""), position: position, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.push(FolderBrowserController(context: self.context, server: self.server, path: path, open: self.open))
                }))
            }
        }
        return items
    }
}

/// `~` for the home directory, as a shell shows paths.
func abbreviate(_ path: String, home: String? = nil) -> String {
    if let home, !home.isEmpty, path == home || path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    if let range = path.range(of: #"^/(Users|home)/[^/]+"#, options: .regularExpression) {
        return "~" + path[range.upperBound...]
    }
    return path
}
