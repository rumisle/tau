import UIKit
import SwiftSignalKit

/// A tau link in a message, as the message shows it (docs/links.md): under the text, in Telegram's quote, the chat it
/// names and what it says there: the message's own words for a message's link, the chat's latest for a chat's.
struct LinkReference: Equatable {
    var url: String
    var title: String
    var text: String
}

/// The links of messages to chats this phone has, from what it knows of them. A linked message it has not seen comes
/// from its server, once; `updated` says when, so the rows show it.
final class LinkReferenceResolver {
    private let store: TauStore
    /// Linked messages' words by link, once had; links asked for meanwhile; links that had none.
    private var entryTexts: [String: String] = [:]
    private var pending = Set<String>()
    private var missing = Set<String>()
    /// Links to chats the phone did not have yet, as at launch before its list came: when it comes, their cards.
    private var unknownChats = Set<String>()
    private var dialogsDisposable: Disposable?
    var updated: (() -> Void)?

    /// At most this many cards a message.
    private static let maxReferences = 8
    private static let pattern = try! NSRegularExpression(pattern: "tau://[A-Za-z0-9]+/[0-9]+(?:/[0-9]+)?(?:\\?[^\\s)>\\]\"']*)?")

    init(store: TauStore) {
        self.store = store
        // Its list, or its servers (whose IDs name them in links) once they say hello.
        let changes = combineLatest(store.dialogsSignal() |> map { _ in Void() }, store.serversSignal |> map { _ in Void() })
        self.dialogsDisposable = (changes |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self, !self.unknownChats.isEmpty else {
                return
            }
            let known = self.unknownChats.filter { self.dialog(for: $0) != nil }
            if !known.isEmpty {
                self.unknownChats.subtract(known)
                self.updated?()
            }
        })
    }

    deinit {
        self.dialogsDisposable?.dispose()
    }

    private func dialog(for string: String) -> DialogModel? {
        guard let url = URL(string: string), let link = TauLink(url), case let .chat(server, conversation, _, _) = link, let found = TauLink.server(server, in: self.store) else {
            return nil
        }
        return self.store.dialog(MultiStore.global(found.slot, conversation))
    }

    /// The tau links in `text` that name a chat of a configured server.
    static func links(in text: String) -> [String] {
        guard text.contains("tau://") else {
            return []
        }
        var seen = Set<String>()
        return self.pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).compactMap { match in
            let link = (text as NSString).substring(with: match.range)
            return seen.insert(link).inserted ? link : nil
        }
    }

    func references(in text: String) -> [LinkReference] {
        var result: [LinkReference] = []
        for string in LinkReferenceResolver.links(in: text).prefix(LinkReferenceResolver.maxReferences) {
            if let reference = self.reference(string) {
                result.append(reference)
            }
        }
        return result
    }

    func reference(_ string: String) -> LinkReference? {
        guard let url = URL(string: string), let link = TauLink(url), case let .chat(server, conversation, entry, _) = link else {
            return nil
        }
        // Its server not known yet (connecting at launch): as a chat not had yet.
        guard let found = TauLink.server(server, in: self.store) else {
            self.unknownChats.insert(string)
            return nil
        }
        let id = MultiStore.global(found.slot, conversation)
        guard let dialog = self.store.dialog(id) else {
            self.unknownChats.insert(string)
            return nil
        }
        // A chat's last words while its message's come, or with none.
        var text = dialog.last?.text ?? ""
        if let entry, !self.missing.contains(string) {
            if let found = self.entryTexts[string] {
                text = found
            } else {
                text = "…"
                if self.pending.insert(string).inserted {
                    // The store answers at once for a message it has: then the row takes the text now. Only a later
                    // answer reloads the rows, since this runs while they are being made (ChatControllerNode.item(for:)
                    // in update(state:)), and a reload from inside that update crashed the list.
                    var synchronous = true
                    self.store.linkedEntryText(id, entryId: entry) { [weak self] found in
                        guard let self else {
                            return
                        }
                        self.pending.remove(string)
                        if let found, !found.isEmpty {
                            self.entryTexts[string] = found
                        } else {
                            self.missing.insert(string)
                        }
                        if !synchronous {
                            self.updated?()
                        }
                    }
                    synchronous = false
                    if let found = self.entryTexts[string] {
                        text = found
                    } else if self.missing.contains(string) {
                        text = dialog.last?.text ?? ""
                    }
                }
            }
        }
        // As the chat list shows a message: its words without Markdown's marks.
        return LinkReference(url: string, title: dialog.title, text: text == "…" ? text : plainPreview(text))
    }
}
