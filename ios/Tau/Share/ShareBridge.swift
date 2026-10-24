import UIKit
import SwiftSignalKit

/// The app's side of the share extension (TauShare): keeps the App Group's snapshot of servers and chats current, and
/// delivers what the extension left because it could not reach a server.
final class ShareBridge {
    static let shared = ShareBridge()

    private weak var store: TauStore?
    private let dialogsDisposable = MetaDisposable()
    private var pendingWrite = false
    private var latest: [DialogModel] = []

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.deliverPending()
        }
    }

    func attach(store: TauStore) {
        self.store = store
        guard !store.isDemo else {
            return
        }
        self.dialogsDisposable.set((store.dialogsSignal() |> deliverOnMainQueue).start(next: { [weak self] dialogs in
            self?.latest = dialogs
            self?.scheduleWrite()
        }))
        Queue.mainQueue().after(2.0) { [weak self] in
            self?.deliverPending()
        }
    }

    /// At most every two seconds: the list changes with every streamed answer's busy state.
    private func scheduleWrite() {
        guard !self.pendingWrite else {
            return
        }
        self.pendingWrite = true
        Queue.mainQueue().after(2.0) { [weak self] in
            guard let self else {
                return
            }
            self.pendingWrite = false
            self.write()
        }
    }

    private func write() {
        guard let store = self.store else {
            return
        }
        let servers = store.servers.map { server in
            ShareSnapshot.Server(slot: server.slot, name: server.name, address: server.address, token: store.serverToken(server.slot), serverId: server.serverInfo?.serverId)
        }
        // As the chat list orders them, archived and subagents' left out.
        let visible = self.latest.filter { !$0.archived && $0.parentConversationId == nil }
        let ordered = visible.filter { $0.pinned != nil }.sorted { ($0.pinned ?? 0) > ($1.pinned ?? 0) } + visible.filter { $0.pinned == nil }
        let chats = ordered.prefix(60).map { dialog in
            ShareSnapshot.Chat(id: dialog.id, slot: dialog.serverSlot, localId: MultiStore.split(dialog.id).local, title: dialog.title, server: dialog.serverName ?? "", busy: dialog.busy, date: dialog.last?.date, pinned: dialog.pinned != nil)
        }
        let newChats = store.recentServers().map { ShareSnapshot.NewChat(slot: $0.slot, title: $0.name) }
        let snapshot = ShareSnapshot(servers: servers, chats: Array(chats), newChats: newChats)
        DispatchQueue.global(qos: .utility).async {
            ShareGroup.snapshot = snapshot
        }
    }

    /// Shares the extension could not send: through the outbox now, as follow-ups, which send when they can.
    private func deliverPending() {
        guard let store = self.store, !store.isDemo else {
            return
        }
        for account in ShareGroup.pendingAccounts() {
            guard let data = ShareGroup.read(account: account), let share = try? JSONDecoder().decode(PendingShare.self, from: data) else {
                ShareGroup.delete(account: account)
                continue
            }
            ShareGroup.delete(account: account)
            let attachments = share.images.compactMap { data -> MessageAttachment? in
                return UIImage(data: data).map { MessageAttachment(id: store.mintAttachmentId(), kind: .image($0)) }
            }
            for id in share.chatIds {
                store.send(share.text, attachments: attachments, to: id, mode: .followUp)
            }
            if let newChat = share.newChat {
                let id = store.createConversation(server: newChat.slot)
                store.send(share.text, attachments: attachments, to: id, mode: .followUp)
            }
        }
    }
}
