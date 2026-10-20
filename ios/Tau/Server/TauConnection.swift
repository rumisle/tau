import Foundation
import Network
import SwiftSignalKit

/// What the chat list title shows, as Telegram's "Connecting..." / "Updating...".
enum ConnectionStatus: Equatable {
    /// The device has no network path: Telegram's "Waiting for network".
    case waitingForNetwork
    case connecting
    case updating
    case online
}

struct RequestError: Error, CustomStringConvertible {
    let code: String
    let message: String

    var description: String {
        return "\(self.code): \(self.message)"
    }

    static let disconnected = RequestError(code: "disconnected", message: "Not connected to the server")
    static let timeout = RequestError(code: "timeout", message: "The server did not answer")
}

/// One WebSocket to a tau server (docs/protocol.md): JSON requests answered by id, pushes without one. Reconnects with
/// backoff; every (re)connection starts with `hello` and then calls `onConnected`, where stores resubscribe.
final class TauConnection: NSObject, URLSessionWebSocketDelegate {
    struct Hello {
        let serverId: String
        let defaultModel: String
        let defaultCwd: String
        let home: String
    }

    let url: URL
    private let token: String?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var pending: [Int: (Result<JSONObject, RequestError>) -> Void] = [:]
    private var generation = 0
    private var retryDelay: Double = 0.5
    private var isClosed = false
    private(set) var hello: Hello?
    private var pingTimer: SwiftSignalKit.Timer?
    /// Requests with a big frame, not answered yet.
    private var largeRequests: Set<Int> = []

    /// No answer this long after a request is out means the socket is dead without knowing it (a half-open TCP
    /// connection after a network change): reconnect, and callers resend idempotently.
    private static let responseTimeout: Double = 45.0
    private static let pingInterval: Double = 15.0
    private static let pongTimeout: Double = 10.0

    /// Connected and greeted: requests go out now.
    var isReady: Bool {
        return self.task != nil && self.hello != nil
    }

    private let statusPromise = ValuePromise<ConnectionStatus>(.connecting, ignoreRepeated: true)
    var status: Signal<ConnectionStatus, NoError> {
        return self.statusPromise.get()
    }
    /// What the socket is doing; `status` adds whether the device has a network at all.
    private var socketStatus: ConnectionStatus = .connecting
    private let pathMonitor = NWPathMonitor()
    private var hasNetwork = true

    /// Pushes, on the main queue.
    var onPush: ((JSONObject) -> Void)?
    /// After `hello` succeeded on a new socket.
    var onConnected: ((Hello) -> Void)?

    init(url: URL, token: String?) {
        self.url = url
        self.token = token
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.main)
    }

    func start() {
        self.pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Queue.mainQueue().async {
                self?.networkChanged(satisfied)
            }
        }
        self.pathMonitor.start(queue: .global(qos: .utility))
        self.connect()
    }

    /// A network that comes back is tried at once, not after the backoff, as Telegram does.
    private func networkChanged(_ satisfied: Bool) {
        let regained = satisfied && !self.hasNetwork
        self.hasNetwork = satisfied
        self.publishStatus()
        if regained && !self.isReady && !self.isClosed {
            self.retryDelay = 0.5
            self.reconnect(generation: self.generation, delay: 0.0)
        }
    }

    private func publishStatus() {
        if self.socketStatus == .connecting && !self.hasNetwork {
            self.statusPromise.set(.waitingForNetwork)
        } else {
            self.statusPromise.set(self.socketStatus)
        }
    }

    func close() {
        self.isClosed = true
        self.pathMonitor.cancel()
        self.task?.cancel(with: .goingAway, reason: nil)
        self.failPending()
    }

    func setStatus(_ status: ConnectionStatus) {
        self.socketStatus = status
        self.publishStatus()
    }

    private func connect() {
        guard !self.isClosed else {
            return
        }
        self.generation += 1
        let generation = self.generation
        var request = URLRequest(url: self.url)
        if let token = self.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = self.session.webSocketTask(with: request)
        // Long tool outputs and history pages exceed the 1 MB default.
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        self.setStatus(.connecting)
        task.resume()
        self.receive(task: task, generation: generation)
        self.send(method: "hello", params: ["protocol": 1], on: task) { [weak self] result in
            guard let self, generation == self.generation else {
                return
            }
            switch result {
            case let .success(value):
                self.retryDelay = 0.5
                let model = value.object("defaultModel")
                let hello = Hello(
                    serverId: value.string("serverId") ?? "",
                    defaultModel: model.map { "\($0.string("provider") ?? "")/\($0.string("modelId") ?? "")" } ?? "",
                    defaultCwd: value.string("defaultCwd") ?? "~",
                    home: value.string("home") ?? "~"
                )
                self.hello = hello
                self.startPinging(generation: generation)
                self.onConnected?(hello)
            case .failure:
                self.reconnect(generation: generation)
            }
        }
    }

    /// URLSession does not notice a connection that died quietly; a ping that gets no pong in time does.
    private func startPinging(generation: Int) {
        self.pingTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: TauConnection.pingInterval, repeat: true, completion: { [weak self] in
            self?.ping(generation: generation)
        }, queue: Queue.mainQueue())
        self.pingTimer = timer
        timer.start()
    }

    /// Check the socket now, as when the app comes back to the foreground.
    func checkAlive() {
        if self.isReady {
            self.ping(generation: self.generation)
        }
    }

    private func ping(generation: Int) {
        guard generation == self.generation, let task = self.task else {
            return
        }
        // A pong cannot overtake a big frame still going out; the response timeout covers that socket instead.
        if !self.largeRequests.isEmpty {
            return
        }
        var answered = false
        task.sendPing { [weak self] error in
            Queue.mainQueue().async {
                answered = true
                if error != nil {
                    self?.reconnect(generation: generation)
                }
            }
        }
        Queue.mainQueue().after(TauConnection.pongTimeout) { [weak self] in
            if !answered {
                self?.reconnect(generation: generation)
            }
        }
    }

    private func reconnect(generation: Int, delay: Double? = nil) {
        guard generation == self.generation, !self.isClosed else {
            return
        }
        // Later callbacks of this socket are stale.
        self.generation += 1
        self.pingTimer?.invalidate()
        self.pingTimer = nil
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.hello = nil
        self.failPending()
        self.setStatus(.connecting)
        let delay = delay ?? self.retryDelay
        self.retryDelay = min(8.0, self.retryDelay * 2.0)
        let next = self.generation
        Queue.mainQueue().after(delay) { [weak self] in
            guard let self, next == self.generation else {
                return
            }
            self.connect()
        }
    }

    private func failPending() {
        let pending = self.pending
        self.pending.removeAll()
        self.largeRequests.removeAll()
        for completion in pending.values {
            completion(.failure(.disconnected))
        }
    }

    private func receive(task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            guard let self, generation == self.generation else {
                return
            }
            switch result {
            case let .success(message):
                let data: Data?
                switch message {
                case let .string(text):
                    data = text.data(using: .utf8)
                case let .data(value):
                    data = value
                @unknown default:
                    data = nil
                }
                if let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
                    self.handle(object)
                }
                self.receive(task: task, generation: generation)
            case .failure:
                self.reconnect(generation: generation)
            }
        }
    }

    private func handle(_ message: JSONObject) {
        if message["event"] != nil {
            self.onPush?(message)
            return
        }
        guard let id = message.int("id"), let completion = self.pending.removeValue(forKey: id) else {
            return
        }
        self.largeRequests.remove(id)
        if let error = message.object("error") {
            completion(.failure(RequestError(code: error.string("code") ?? "internal", message: error.string("message") ?? "")))
        } else {
            completion(.success((message["result"] as? JSONObject) ?? [:]))
        }
    }

    /// Sends a request on the current socket. Fails immediately while disconnected; callers that must not lose the
    /// request (a submit) retry on reconnect with the same `requestId`.
    func request(_ method: String, _ params: JSONObject = [:], completion: @escaping (Result<JSONObject, RequestError>) -> Void) {
        guard let task = self.task, self.hello != nil || method == "hello" else {
            completion(.failure(.disconnected))
            return
        }
        self.send(method: method, params: params, on: task, completion: completion)
    }

    func request(_ method: String, _ params: JSONObject = [:]) -> Signal<JSONObject, RequestError> {
        return Signal { subscriber in
            Queue.mainQueue().async {
                self.request(method, params) { result in
                    switch result {
                    case let .success(value):
                        subscriber.putNext(value)
                        subscriber.putCompletion()
                    case let .failure(error):
                        subscriber.putError(error)
                    }
                }
            }
            return EmptyDisposable
        }
    }

    private func send(method: String, params: JSONObject, on task: URLSessionWebSocketTask, completion: @escaping (Result<JSONObject, RequestError>) -> Void) {
        let id = self.nextId
        self.nextId += 1
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]), let text = String(data: data, encoding: .utf8) else {
            completion(.failure(RequestError(code: "bad_request", message: "unencodable params")))
            return
        }
        self.pending[id] = completion
        let generation = self.generation
        // A big frame (photos) takes a while on a slow link: its answer may come later, and pings wait behind it.
        let bytes = text.utf8.count
        let timeout = TauConnection.responseTimeout + Double(bytes) / 50_000.0
        if bytes > 256 * 1024 {
            self.largeRequests.insert(id)
        }
        task.send(.string(text)) { [weak self] error in
            Queue.mainQueue().async {
                guard let self else {
                    return
                }
                if error != nil {
                    if let completion = self.pending.removeValue(forKey: id) {
                        completion(.failure(.disconnected))
                    }
                    return
                }
                // Written: from now on the answer is due.
                Queue.mainQueue().after(timeout) { [weak self] in
                    guard let self, generation == self.generation, self.pending[id] != nil else {
                        return
                    }
                    self.reconnect(generation: generation)
                }
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if webSocketTask === self.task {
            self.hello = nil
            self.reconnect(generation: self.generation)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task === self.task, error != nil {
            self.hello = nil
            self.reconnect(generation: self.generation)
        }
    }
}
