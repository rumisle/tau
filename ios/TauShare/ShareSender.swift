import UIKit

enum ShareSender {
    /// Sends the share to each chat (as a follow-up when its agent is working: a share must not turn a run aside) and
    /// to a new chat, grouped by server: its photos and files uploaded once for all the server's chats, and named by the
    /// messages (docs/files.md). Returns what could not be sent, and why when the server said.
    static func send(text: String, images: [Data], files: [URL], chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.NewChat?, servers: [ShareSnapshot.Server]) async -> (chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.NewChat?, reason: String?) {
        var failedChats: [ShareSnapshot.Chat] = []
        var failedNew: ShareSnapshot.NewChat?
        var reason: String?
        let slots = Set(chats.map(\.slot) + (newChat.map { [$0.slot] } ?? []))
        for slot in slots {
            let chatsHere = chats.filter { $0.slot == slot }
            let newHere = newChat?.slot == slot ? newChat : nil
            guard let server = servers.first(where: { $0.slot == slot }), let connection = ShareConnection(address: server.address, token: server.token) else {
                failedChats += chatsHere
                failedNew = newHere ?? failedNew
                continue
            }
            defer {
                connection.close()
            }
            var attachments: [[String: Any]] = []
            do {
                _ = try await connection.request("hello", ["protocol": 1])
                for data in images {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
                    try data.write(to: url)
                    defer {
                        try? FileManager.default.removeItem(at: url)
                    }
                    attachments.append(["id": try await upload(url, name: "photo.jpg", to: server), "as": "image"])
                }
                for url in files {
                    attachments.append(["id": try await upload(url, name: url.lastPathComponent, to: server), "as": "file"])
                }
            } catch {
                if case let ShareConnection.Failure.server(message) = error {
                    reason = message
                }
                failedChats += chatsHere
                failedNew = newHere ?? failedNew
                continue
            }
            func submit(_ conversationId: Int, busy: String?) async throws {
                var params: [String: Any] = ["conversationId": conversationId, "requestId": UUID().uuidString, "content": text]
                if let busy {
                    params["whenBusy"] = busy
                }
                if !attachments.isEmpty {
                    params["attachments"] = attachments
                }
                _ = try await connection.request("conversation.submit", params)
            }
            for chat in chatsHere {
                do {
                    try await submit(chat.localId, busy: "followUp")
                } catch {
                    failedChats.append(chat)
                }
            }
            if let project = newHere {
                do {
                    let title = String(text.split(separator: "\n").first?.prefix(60) ?? Substring(files.first?.lastPathComponent ?? "Shared"))
                    let created = try await connection.request("conversation.create", ["requestId": UUID().uuidString, "title": title.isEmpty ? "Shared" : title, "autoTitle": true])
                    guard let id = ((created["dialog"] as? [String: Any])?["conversation"] as? [String: Any])?["id"] as? NSNumber else {
                        throw ShareConnection.Failure.server("no conversation")
                    }
                    try await submit(id.intValue, busy: nil)
                } catch {
                    failedNew = project
                }
            }
        }
        return (failedChats, failedNew, reason)
    }

    /// One file to a server over HTTP (server/src/http-files.ts), streamed from disk; its ID.
    private static func upload(_ url: URL, name: String, to server: ShareSnapshot.Server) async throws -> String {
        guard var components = URLComponents(string: server.address) else {
            throw ShareConnection.Failure.connection("bad address")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/files"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let endpoint = components.url else {
            throw ShareConnection.Failure.connection("bad address")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token = server.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60.0
        let (data, response) = try await URLSession(configuration: configuration).upload(for: request, fromFile: url)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 201, let id = body?["id"] as? String else {
            throw ShareConnection.Failure.server((body?["error"] as? [String: Any])?["message"] as? String ?? "The server refused \(name)")
        }
        return id
    }

    /// What could not be sent, for the app to send through its outbox when it opens; photos smaller, to fit the keychain.
    static func leaveForApp(text: String, images: [Data], chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.NewChat?) {
        let small = images.prefix(4).compactMap { data -> Data? in
            return UIImage(data: data).flatMap { ImageEncoding.jpeg($0, maxPixels: 1280.0, quality: 0.7) }
        }
        let share = PendingShare(id: UUID().uuidString, text: text, images: Array(small), chatIds: chats.map(\.id), newChat: newChat, date: Date())
        if let data = try? JSONEncoder().encode(share) {
            ShareGroup.write(data, account: "pending-\(share.id)")
        }
    }
}
