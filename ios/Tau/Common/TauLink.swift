import Foundation

/// tau's own links (docs/links.md). A chat or one of its messages, on a server named by the first eight characters of
/// its ID, which stays as the server's address changes:
///
///     tau://d0003019/1523            the chat
///     tau://d0003019/1523/880        its entry 880 (history only grows, so an entry is for good)
///     tau://d0003019/1523/880?q=...  and words of it, marked
///     tau://new?text=...&server=d0003019&model=anthropic/claude-opus-5-5
///                                    a new chat, its field filled in; the server and model when given and there
enum TauLink: Equatable {
    case chat(server: String, conversation: Int, entry: Int?, quote: String?)
    case newChat(text: String?, server: String?, model: String?)

    /// How much of a server's ID names it in a link.
    static let serverPrefixLength = 8

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "tau", let host = url.host, !host.isEmpty else {
            return nil
        }
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if host == "new" {
            self = .newChat(text: query["text"], server: query["server"], model: query["model"])
            return
        }
        let parts = url.path.split(separator: "/").compactMap { Int($0) }
        guard let conversation = parts.first else {
            return nil
        }
        self = .chat(server: host.lowercased(), conversation: conversation, entry: parts.count > 1 ? parts[1] : nil, quote: query["q"])
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "tau"
        switch self {
        case let .chat(server, conversation, entry, quote):
            components.host = server
            components.path = "/\(conversation)" + (entry.map { "/\($0)" } ?? "")
            if let quote {
                components.queryItems = [URLQueryItem(name: "q", value: quote)]
            }
        case let .newChat(text, server, model):
            components.host = "new"
            let items = [("text", text), ("server", server), ("model", model)].compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            components.queryItems = items.isEmpty ? nil : items
        }
        return components.url
    }

    /// The link of a chat of the app (a global ID), or of one of its entries; nil until its server has said who it is.
    static func chat(_ id: Int, entry: Int? = nil, store: TauStore) -> URL? {
        // A new chat keeps its draft's ID on screen; its link is the conversation it became.
        let id = store.dialog(id)?.id ?? id
        guard let serverId = store.server(of: id)?.serverInfo?.serverId, !serverId.isEmpty else {
            return nil
        }
        let local = MultiStore.split(id).local
        guard local > 0 else {
            return nil
        }
        return TauLink.chat(server: String(serverId.prefix(TauLink.serverPrefixLength)).lowercased(), conversation: local, entry: entry, quote: nil).url
    }

    /// The server a link names: the one whose ID begins with it.
    static func server(_ prefix: String, in store: TauStore) -> TauServer? {
        let prefix = prefix.lowercased()
        return store.servers.first { ($0.serverInfo?.serverId.lowercased() ?? "").hasPrefix(prefix) }
    }
}
