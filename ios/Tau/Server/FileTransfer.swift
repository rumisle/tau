import Foundation
import SwiftSignalKit

/// Where a file of the chat is: on the server only, on its way up or down, or here.
enum FileTransferStatus: Equatable {
    case remote
    case uploading(Double)
    case downloading(Double)
    case local(URL)
}

/// One server's files over HTTP (server/src/http-files.ts, docs/files.md): uploads for the outbox, and downloads of what
/// the chat shows, kept in Caches by the file's ID (a kept file never changes) under its name, so it opens and shares as
/// itself. Each transfer's status is a signal the chat's file rows follow.
final class FileTransfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    struct Uploaded {
        let id: String
        let name: String
        let bytes: Int64
        let mimeType: String
    }

    enum Failure: Error {
        /// No answer: tried again later.
        case network
        /// The server answered no: `status` is its HTTP status.
        case refused(status: Int, message: String)
    }

    private let connection: TauConnection
    private let directory: URL
    private var session: URLSession!
    private var statuses: [String: ValuePromise<FileTransferStatus>] = [:]
    private var current: [String: FileTransferStatus] = [:]
    private var downloads: [String: URLSessionDownloadTask] = [:]
    private var downloadNames: [Int: (id: String, name: String)] = [:]
    private var uploads: [Int: (key: String, data: Data, completion: (Result<Uploaded, Failure>) -> Void)] = [:]

    init(connection: TauConnection, namespace: String) {
        self.connection = connection
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = namespace.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        self.directory = base.appendingPathComponent("tau-files/\(safe)", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        // A large file over a slow link takes as long as it takes; a stalled one fails after a minute.
        configuration.timeoutIntervalForRequest = 60.0
        configuration.timeoutIntervalForResource = 24.0 * 60.0 * 60.0
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }

    // MARK: - Status

    /// A file's status by its ID, or a transfer's by its key.
    func status(_ key: String) -> Signal<FileTransferStatus, NoError> {
        if let promise = self.statuses[key] {
            return promise.get()
        }
        let promise = ValuePromise<FileTransferStatus>(self.current[key] ?? self.initialStatus(key), ignoreRepeated: true)
        self.statuses[key] = promise
        return promise.get()
    }

    private func initialStatus(_ key: String) -> FileTransferStatus {
        return self.localURL(id: key).map { .local($0) } ?? .remote
    }

    private func set(_ key: String, _ status: FileTransferStatus) {
        self.current[key] = status
        self.statuses[key]?.set(status)
    }

    /// What a file's row shows now.
    func currentStatus(of file: FileAttachment) -> FileTransferStatus {
        if let key = file.transferKey, let status = self.current[key] {
            return status
        }
        if let id = file.serverId {
            return self.current[id] ?? self.initialStatus(id)
        }
        return file.localURL.map { .local($0) } ?? .remote
    }

    // MARK: - Downloads

    /// The file here, when it was fetched.
    func localURL(id: String) -> URL? {
        let folder = self.directory.appendingPathComponent(id, isDirectory: true)
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first(where: { !$0.hasPrefix(".") }) else {
            return nil
        }
        return folder.appendingPathComponent(name)
    }

    /// Fetch a file the server has; its status says how far it got. Nothing when it is here or on its way.
    func download(_ file: FileAttachment) {
        guard let id = file.serverId, self.downloads[id] == nil, self.localURL(id: id) == nil else {
            return
        }
        var request = URLRequest(url: self.connection.httpBase.appendingPathComponent("files/\(id)"))
        self.connection.authorize(&request)
        let task = self.session.downloadTask(with: request)
        self.downloads[id] = task
        self.downloadNames[task.taskIdentifier] = (id, file.name)
        self.set(id, .downloading(0.0))
        task.resume()
    }

    func cancelDownload(_ id: String) {
        guard let task = self.downloads.removeValue(forKey: id) else {
            return
        }
        task.cancel()
        self.downloadNames[task.taskIdentifier] = nil
        self.set(id, .remote)
    }

    /// A file this phone has already (its own upload, the outbox's copy), so it is never fetched back.
    func seed(id: String, name: String, from url: URL) {
        guard self.localURL(id: id) == nil else {
            return
        }
        let folder = self.directory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))) != nil {
            self.set(id, .local(folder.appendingPathComponent(name)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, _) = self.downloadNames[downloadTask.taskIdentifier], totalBytesExpectedToWrite > 0 else {
            return
        }
        self.set(id, .downloading(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, name) = self.downloadNames[downloadTask.taskIdentifier] else {
            return
        }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            return
        }
        let folder = self.directory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name.isEmpty ? "file" : name)
        try? FileManager.default.removeItem(at: destination)
        if (try? FileManager.default.moveItem(at: location, to: destination)) != nil {
            self.downloadNames[downloadTask.taskIdentifier] = nil
            self.downloads[id] = nil
            self.set(id, .local(destination))
        }
    }

    // MARK: - Uploads

    /// Send the file at `url` to the server as `name`; `key` names the transfer for its row's progress.
    func upload(_ url: URL, name: String, key: String, completion: @escaping (Result<Uploaded, Failure>) -> Void) {
        var components = URLComponents(url: self.connection.httpBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        self.connection.authorize(&request)
        let task = self.session.uploadTask(with: request, fromFile: url)
        self.uploads[task.taskIdentifier] = (key, Data(), completion)
        self.set(key, .uploading(0.0))
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let upload = self.uploads[task.taskIdentifier], totalBytesExpectedToSend > 0 else {
            return
        }
        self.set(upload.key, .uploading(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.uploads[dataTask.taskIdentifier]?.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let (id, _) = self.downloadNames.removeValue(forKey: task.taskIdentifier) {
            // Finished downloads were moved in place already; this is a failed or refused one.
            self.downloads[id] = nil
            if self.localURL(id: id) == nil {
                self.set(id, .remote)
            }
            return
        }
        guard let upload = self.uploads.removeValue(forKey: task.taskIdentifier) else {
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if error != nil || status == nil {
            self.set(upload.key, .uploading(0.0))
            upload.completion(.failure(.network))
            return
        }
        let body = (try? JSONSerialization.jsonObject(with: upload.data)) as? JSONObject
        if status == 201, let body, let id = body.string("id") {
            self.set(upload.key, .uploading(1.0))
            upload.completion(.success(Uploaded(id: id, name: body.string("name") ?? "", bytes: Int64(body.double("bytes") ?? 0.0), mimeType: body.string("mimeType") ?? "application/octet-stream")))
        } else {
            self.set(upload.key, .uploading(0.0))
            upload.completion(.failure(.refused(status: status ?? 0, message: body?.object("error")?.string("message") ?? "The server refused the file")))
        }
    }

    // MARK: - Storage

    var diskBytes: Int64 {
        guard let enumerator = FileManager.default.enumerator(at: self.directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func clear() {
        try? FileManager.default.removeItem(at: self.directory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        for key in Array(self.current.keys) where self.downloads[key] == nil {
            if case .local = self.current[key] {
                self.set(key, .remote)
            }
        }
    }
}
