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
    /// Sends `content` to each chat (as a follow-up when its agent is working: a share must not turn a run aside) and
    /// to a new chat, grouped by server. Returns what could not be sent.
    static func send(text: String, images: [Data], chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.Project?, servers: [ShareSnapshot.Server]) async -> (chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.Project?) {
        var content: Any = text
        if !images.isEmpty {
            let blocks: [[String: Any]] = images.map { ["type": "image", "data": $0.base64EncodedString(), "mimeType": "image/jpeg"] }
            content = (text.isEmpty ? [] : [["type": "text", "text": text]]) + blocks
        }
        var failedChats: [ShareSnapshot.Chat] = []
        var failedNew: ShareSnapshot.Project?
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
            do {
                _ = try await connection.request("hello", ["protocol": 1])
            } catch {
                failedChats += chatsHere
                failedNew = newHere ?? failedNew
                continue
            }
            for chat in chatsHere {
                do {
                    _ = try await connection.request("conversation.submit", ["conversationId": chat.localId, "requestId": UUID().uuidString, "content": content, "whenBusy": "followUp"])
                } catch {
                    failedChats.append(chat)
                }
            }
            if let project = newHere {
                do {
                    let title = String(text.split(separator: "\n").first?.prefix(60) ?? "Shared")
                    let created = try await connection.request("conversation.create", ["requestId": UUID().uuidString, "title": title.isEmpty ? "Shared" : title, "autoTitle": true, "agent": ["cwd": project.path]])
                    guard let id = ((created["dialog"] as? [String: Any])?["conversation"] as? [String: Any])?["id"] as? NSNumber else {
                        throw ShareConnection.Failure.server("no conversation")
                    }
                    _ = try await connection.request("conversation.submit", ["conversationId": id.intValue, "requestId": UUID().uuidString, "content": content])
                } catch {
                    failedNew = project
                }
            }
        }
        return (failedChats, failedNew)
    }

    /// What could not be sent, for the app to send through its outbox when it opens; photos smaller, to fit the keychain.
    static func leaveForApp(text: String, images: [Data], chats: [ShareSnapshot.Chat], newChat: ShareSnapshot.Project?) {
        let small = images.prefix(4).compactMap { data -> Data? in
            guard let image = UIImage(data: data) else {
                return nil
            }
            let scale = min(1.0, 1280.0 / max(image.size.width, image.size.height))
            let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
            return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.7)
        }
        let share = PendingShare(id: UUID().uuidString, text: text, images: Array(small), chatIds: chats.map(\.id), newChat: newChat, date: Date())
        if let data = try? JSONEncoder().encode(share) {
            ShareGroup.write(data, account: "pending-\(share.id)")
        }
    }
}
