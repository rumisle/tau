import UIKit

/// The share extension's own connection to a tau server (docs/protocol.md): hello, then the requests, over a
/// WebSocket that lives as long as the share. The app's ServerStore and outbox are too much to bring here; what this
/// cannot send it leaves for the app (ShareBridge).
final class ShareConnection {
    enum Failure: Error {
        case connection(String)
        case server(String)
    }

    private let task: URLSessionWebSocketTask
    private var nextId = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()

    init?(address: String, token: String?) {
        guard var components = URLComponents(string: address) else {
            return nil
        }
        if let token, !token.isEmpty {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        }
        guard let url = components.url else {
            return nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15.0
        self.task = URLSession(configuration: configuration).webSocketTask(with: url)
        self.task.maximumMessageSize = 96 * 1024 * 1024
        self.task.resume()
        self.receive()
    }

    func close() {
        self.task.cancel(with: .goingAway, reason: nil)
        self.failAll(Failure.connection("closed"))
    }

    private func receive() {
        self.task.receive { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case let .success(message):
                if case let .string(text) = message, let data = text.data(using: .utf8), let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = (frame["id"] as? NSNumber)?.intValue {
                    self.lock.lock()
                    let continuation = self.waiting.removeValue(forKey: id)
                    self.lock.unlock()
                    if let error = frame["error"] as? [String: Any] {
                        continuation?.resume(throwing: Failure.server(error["message"] as? String ?? "error"))
                    } else {
                        continuation?.resume(returning: frame["result"] as? [String: Any] ?? [:])
                    }
                }
                self.receive()
            case let .failure(error):
                self.failAll(Failure.connection(error.localizedDescription))
            }
        }
    }

    private func failAll(_ error: Error) {
        self.lock.lock()
        let all = self.waiting
        self.waiting = [:]
        self.lock.unlock()
        for continuation in all.values {
            continuation.resume(throwing: error)
        }
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        self.lock.lock()
        let id = self.nextId
        self.nextId += 1
        self.lock.unlock()
        let frame: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: frame)
        return try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.waiting[id] = continuation
            self.lock.unlock()
            self.task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                if let error {
                    self?.lock.lock()
                    let waiting = self?.waiting.removeValue(forKey: id)
                    self?.lock.unlock()
                    waiting?.resume(throwing: Failure.connection(error.localizedDescription))
                }
            }
        }
    }
}

enum ShareSender {
    /// Sends the share to each chat (as a follow-up when its agent is working: a share must not turn a run aside) and
    /// to a new chat, grouped by server. A server that keeps files (docs/files.md) gets the photos and files uploaded,
    /// once for all its chats, and named by the messages; one from before, the photos inline and no files. Returns what
    /// could not be sent, and why when the server said.
    static func send(text: String, images: [Data], files: [URL], chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.Project?, servers: [ShareSnapshot.Server]) async -> (chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.Project?, reason: String?) {
        var failedChats: [ShareSnapshot.Chat] = []
        var failedNew: ShareSnapshot.Project?
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
            let hello: [String: Any]
            do {
                hello = try await connection.request("hello", ["protocol": 1])
            } catch {
                failedChats += chatsHere
                failedNew = newHere ?? failedNew
                continue
            }
            var content: Any = text
            var attachments: [[String: Any]] = []
            if (hello["files"] as? Bool) == true {
                do {
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
            } else {
                if !files.isEmpty {
                    reason = "\(server.name) does not take files: update it"
                    failedChats += chatsHere
                    failedNew = newHere ?? failedNew
                    continue
                }
                if !images.isEmpty {
                    let blocks: [[String: Any]] = images.map { ["type": "image", "data": $0.base64EncodedString(), "mimeType": "image/jpeg"] }
                    content = (text.isEmpty ? [] : [["type": "text", "text": text]]) + blocks
                }
            }
            func submit(_ conversationId: Int, busy: String?) async throws {
                var params: [String: Any] = ["conversationId": conversationId, "requestId": UUID().uuidString, "content": content]
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
                    let created = try await connection.request("conversation.create", ["requestId": UUID().uuidString, "title": title.isEmpty ? "Shared" : title, "autoTitle": true, "agent": ["cwd": project.path]])
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
    static func leaveForApp(text: String, images: [Data], chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.Project?) {
        let small = images.prefix(4).compactMap { data -> Data? in
            return UIImage(data: data).flatMap { ImageEncoding.jpeg($0, maxPixels: 1280.0, quality: 0.7) }
        }
        let share = PendingShare(id: UUID().uuidString, text: text, images: Array(small), chatIds: chats.map(\.id), newChat: newChat, date: Date())
        if let data = try? JSONEncoder().encode(share) {
            ShareGroup.write(data, account: "pending-\(share.id)")
        }
    }
}
