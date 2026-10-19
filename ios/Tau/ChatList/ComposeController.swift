import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

/// New Chat: where the agent works. Telegram's compose screen lists contacts; tau lists the projects of recent chats
/// and a browser for any folder on the server.
final class ComposeController: SettingsListController {
    private let open: (String?) -> Void

    init(context: AppContext, open: @escaping (String?) -> Void) {
        self.open = open
        super.init(context: context, title: "New Chat")
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var recentProjects: [String] = []
    private var dialogsDisposable: Disposable?

    override func displayNodeDidLoad() {
        super.displayNodeDidLoad()
        self.dialogsDisposable = (self.context.store.dialogsSignal() |> take(1) |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            var seen = Set<String>()
            self?.recentProjects = dialogs.compactMap { dialog in
                seen.insert(dialog.cwd).inserted ? dialog.cwd : nil
            }
            self?.reload()
        })
    }

    deinit {
        self.dialogsDisposable?.dispose()
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        var items: [ListViewItem] = []
        let defaultCwd = "Default folder"
        items.append(SettingsTextItem(theme: theme, text: "Start in", kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.model, title: defaultCwd, accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: true, isLast: false), action: { [weak self] in
            self?.open(nil)
        }))
        items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.projects, title: "Browse…", accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: false, isLast: true), action: { [weak self] in
            guard let self else {
                return
            }
            self.push(FolderBrowserController(context: self.context, path: nil, open: self.open))
        }))
        if !self.recentProjects.isEmpty {
            items.append(SettingsTextItem(theme: theme, text: "Recent Projects", kind: .header))
            for (index, path) in self.recentProjects.prefix(12).enumerated() {
                let position = SettingsRowPosition(isFirst: index == 0, isLast: index == min(self.recentProjects.count, 12) - 1)
                items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.projectIcon(for: path), title: (path as NSString).lastPathComponent, accessory: .disclosure(label: abbreviate(path)), position: position, action: { [weak self] in
                    self?.open(path)
                }))
            }
        }
        items.append(SettingsTextItem(theme: theme, text: "The agent runs commands and edits files in this folder on the server.", kind: .footer))
        return items
    }
}

/// One folder of the server, from `fs.list`: subfolders to go into, and a row to start the chat here.
final class FolderBrowserController: SettingsListController {
    private let path: String?
    private let open: (String?) -> Void
    private var listing: DirectoryListing?
    private var error: String?
    private let disposable = MetaDisposable()

    init(context: AppContext, path: String?, open: @escaping (String?) -> Void) {
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
        self.disposable.set((self.context.store.listDirectory(self.path) |> deliverOnMainQueue).start(next: { [weak self] listing in
            guard let self else {
                return
            }
            self.listing = listing
            self.title = (listing.path as NSString).lastPathComponent
            self.reload()
        }, error: { [weak self] error in
            self?.error = error.message
            self?.reload()
        }))
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        guard let listing = self.listing else {
            return [SettingsTextItem(theme: theme, text: self.error ?? "Loading…", kind: .footer)]
        }
        var items: [ListViewItem] = []
        items.append(SettingsTextItem(theme: theme, text: abbreviate(listing.path), kind: .header))
        items.append(SettingsRowItem(theme: theme, icon: SettingsIcon.model, title: "Start Chat Here", titleColor: theme.list.itemAccentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
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
                    self.push(FolderBrowserController(context: self.context, path: path, open: self.open))
                }))
            }
        }
        return items
    }
}

/// `~` for the home directory, as a shell shows paths.
func abbreviate(_ path: String) -> String {
    if let range = path.range(of: #"^/(Users|home)/[^/]+"#, options: .regularExpression) {
        return "~" + path[range.upperBound...]
    }
    return path
}
