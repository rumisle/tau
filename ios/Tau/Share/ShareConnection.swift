import Foundation

/// An extension's own connection to a tau server (docs/protocol.md): hello, then the requests, over a WebSocket that
/// lives as long as the share or the widget's update. The app's ServerStore and outbox are too much to bring there;
/// what the share extension cannot send it leaves for the app (ShareBridge).
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
