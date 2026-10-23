import UIKit
import SwiftSignalKit

/// A message this device sent, from the tap on Send until the server has it in the transcript or refused it
/// (docs/sending.md). Kept on disk, so neither a lost connection nor a killed app loses it.
struct OutgoingMessage: Codable, Equatable {
    enum Mode: String, Codable {
        case steer
        case followUp
    }

    enum State: Codable, Equatable {
        /// Not acknowledged: the submit goes (again) when its turn comes.
        case pending
        /// In the server's inbox.
        case queued(submissionId: Int)
        /// In the transcript; kept until the entry reaches the replica, so the row keeps its ID.
        case placed(entryId: Int)
        /// Refused for good; the row offers Resend and Delete.
        case failed(code: String, message: String)
        /// Cancelled by the user; the withdraw goes when its turn comes.
        case withdrawing
    }

    struct File: Codable, Equatable {
        let name: String
        let size: Int64
    }

    /// A photo or file the message carries (docs/files.md): uploaded before the submit, which names it by its ID.
    struct Upload: Codable, Equatable {
        enum Kind: String, Codable {
            /// Shown to the model too, when it takes images.
            case photo
            /// Only named.
            case file
        }

        let kind: Kind
        /// The device's copy, beside the outbox; nil for one the server has already (an edited message's).
        var localName: String?
        let name: String
        let size: Int64
        let mimeType: String
        /// The server's ID, once uploaded.
        var serverId: String?
    }

    let requestId: String
    /// Nil until the draft conversation it starts exists; `createRequestId` names that draft.
    var conversationId: Int?
    var createRequestId: String?
    /// The chat row's ID, the same before and after the message is in the transcript.
    let rowId: Int
    let text: String
    /// JPEG files next to the outbox, in order, sent inline: an outbox written before files were uploaded.
    let imageFiles: [String]
    let files: [File]
    /// Photos and files, uploaded first; nil in an outbox written before.
    var uploads: [Upload]? = nil
    var mode: Mode
    let date: Date
    var state: State
    var submissionId: Int?
    /// Written to a socket at least once: the server may have it, so cancelling needs a withdraw.
    var wasSent: Bool = false
    /// `internal` errors so far; transient up to a point.
    var attempts: Int = 0
    /// Shown in the input panel's queue rather than the chat: the agent was working when it was sent, or the server
    /// queued it.
    var showsInQueue: Bool
    /// Position among this conversation's operations; each runs after every lower one.
    var seq: Int
    /// Put the text back in the input field once withdrawn (Stop, Edit).
    var restoresOnWithdraw: Bool = false
    /// Submitted only once this request ID was withdrawn: the second half of moving a queued message (Send as
    /// Follow-up, Send Now). If the original reached the model first, this one is dropped.
    var replaces: String?
    /// Acknowledged before a reconnect: the submit is repeated (same request ID, no side effect) to learn what
    /// became of it while pushes could not arrive.
    var needsRefresh: Bool = false

    var isSettledInChat: Bool {
        if case .placed = self.state {
            return true
        }
        return false
    }

    var photoCount: Int {
        return self.imageFiles.count + (self.uploads ?? []).filter { $0.kind == .photo }.count
    }

    /// Its photos and files, as its entry's attachments block counts them (or its image blocks, inline).
    var attachmentCount: Int {
        return self.imageFiles.count + (self.uploads ?? []).count
    }
}

/// A draft conversation being created for the messages sent to it, idempotent through its request ID.
struct PendingCreate: Codable, Equatable {
    let requestId: String
    let cwd: String?
    var title: String
    /// False once the user named it: the server does not name it after its first answer.
    var autoTitle: Bool?
    /// The model and thinking level chosen in the draft before it was sent; nil for the server's defaults.
    var provider: String?
    var modelId: String?
    var thinkingLevel: String?
    /// A fork of this conversation at this entry, as an edit makes, instead of a new conversation.
    var forkOf: Int?
    var forkAt: Int?
    var conversationId: Int?
    var attempts: Int = 0
}

/// Sends the outbox, one operation per conversation at a time, in the order the user made them, through any number of
/// reconnects (docs/sending.md). Network failures and timeouts never fail a message; only the server refusing it does.
final class Outbox {
    private let connection: TauConnection
    private let directory: URL
    private let fileURL: URL

    private(set) var items: [OutgoingMessage] = []
    private(set) var creates: [PendingCreate] = []
    /// What became of withdrawn request IDs that a replacement waits on: true when the original reached the model.
    private var withdrawOutcomes: [String: Bool] = [:]
    private var nextSeq = 1
    private var nextRowId = 1_000_000_000
    /// The storage the messages were written for: a server with another database must not get them, as its
    /// conversation IDs mean other conversations.
    private var serverId: String?

    /// Requests not persisted: an abort, a reset, a compaction, a configure, a withdraw of another device's message.
    private struct Transient {
        let seq: Int
        /// Nil while it waits for its conversation to be created.
        var conversationId: Int?
        var createRequestId: String? = nil
        let method: String
        var params: JSONObject
        /// Repeat after a lost connection; false for what must not happen twice (a compaction).
        let repeatable: Bool
        /// Dropped if still not sent by then: a Stop that waited out a long disconnection would stop a later run.
        var deadline: Double? = nil
        let completion: ((Result<JSONObject, RequestError>) -> Void)?
    }
    private var transients: [Transient] = []
    /// Keys with a request in flight: `c<id>` per conversation, `create` for creates.
    private var inFlight: Set<String> = []
    /// The create on the wire, which can no longer take changes.
    private var sendingCreate: String?
    /// Keys waiting out a backoff after an `internal` error.
    private var backoff: Set<String> = []
    private var attachmentsByRequest: [String: [MessageAttachment]] = [:]

    /// A conversation's rows or queue changed; nil for creates only.
    var changed: ((Int?) -> Void)?
    /// Withdrawn texts to put back in a conversation's input field, in order.
    var restored: ((Int, String) -> Void)?
    /// A draft conversation exists now.
    var created: ((PendingCreate, JSONObject) -> Void)?
    /// Something the user should hear about, as a toast.
    var notice: ((Int, String) -> Void)?
    var mintAttachmentId: (() -> Int)?
    /// Uploads, and the copies of what was uploaded (Server/FileTransfer.swift).
    var transfer: FileTransfer?
    /// The largest file the server takes, as its `hello` said; 0 when unknown.
    var maxFileBytes: (() -> Int64)?

    /// An upload's transfer, for its row's progress.
    static func transferKey(_ requestId: String, _ index: Int) -> String {
        return "up-\(requestId)-\(index)"
    }

    static let maxAttempts = 5

    init(connection: TauConnection, namespace: String) {
        self.connection = connection
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = namespace.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        self.directory = base.appendingPathComponent("tau/outbox/\(safe)", isDirectory: true)
        self.fileURL = self.directory.appendingPathComponent("outbox.json")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.load()
    }

    /// The outbox's files on disk: messages and their photos.
    var diskBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var items: [OutgoingMessage]
        var creates: [PendingCreate]
        var withdrawOutcomes: [String: Bool]
        var nextSeq: Int
        var nextRowId: Int
        var serverId: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: self.fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return
        }
        self.items = stored.items
        self.creates = stored.creates
        self.withdrawOutcomes = stored.withdrawOutcomes
        self.nextSeq = stored.nextSeq
        self.nextRowId = stored.nextRowId
        self.serverId = stored.serverId
        // Placed messages are entries now; their rows come from the transcript.
        self.items.removeAll { $0.isSettledInChat }
        // Whatever was acknowledged as queued may have moved on while the app was not running.
        for index in self.items.indices {
            if case .queued = self.items[index].state {
                self.items[index].needsRefresh = true
            }
        }
    }

    /// Synchronous and atomic: an operation is on disk before its request goes out.
    private func save() {
        let stored = Stored(items: self.items, creates: self.creates, withdrawOutcomes: self.withdrawOutcomes, nextSeq: self.nextSeq, nextRowId: self.nextRowId, serverId: self.serverId)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }

    private func takeSeq() -> Int {
        let seq = self.nextSeq
        self.nextSeq += 1
        return seq
    }

    // MARK: - Queries

    func items(for conversationId: Int) -> [OutgoingMessage] {
        return self.items.filter { $0.conversationId == conversationId }
    }

    func items(forCreate requestId: String) -> [OutgoingMessage] {
        return self.items.filter { $0.conversationId == nil && $0.createRequestId == requestId }
    }

    func item(_ requestId: String) -> OutgoingMessage? {
        return self.items.first { $0.requestId == requestId }
    }

    /// Something still has to reach the server.
    var hasWork: Bool {
        if !self.transients.isEmpty || self.creates.contains(where: { $0.conversationId == nil }) {
            return true
        }
        return self.items.contains { item in
            switch item.state {
            case .pending, .withdrawing:
                return true
            case .queued:
                return item.needsRefresh
            default:
                return false
            }
        }
    }

    func create(_ requestId: String) -> PendingCreate? {
        return self.creates.first { $0.requestId == requestId }
    }

    /// The photos of a message, decoded once.
    /// The photos of a message as they were sent, in order.
    func imageData(_ requestId: String) -> [Data] {
        guard let item = self.item(requestId) else {
            return []
        }
        if let uploads = item.uploads {
            // Only when this device has each: the entry's images are these, in order.
            let photos = uploads.filter { $0.kind == .photo }
            let data = photos.compactMap { upload in upload.localName.flatMap { try? Data(contentsOf: self.directory.appendingPathComponent($0)) } }
            return data.count == photos.count ? data : []
        }
        return item.imageFiles.compactMap { try? Data(contentsOf: self.directory.appendingPathComponent($0)) }
    }

    /// The device's copy of an upload.
    private func localURL(_ upload: OutgoingMessage.Upload) -> URL? {
        return upload.localName.map { self.directory.appendingPathComponent($0) }
    }

    func attachments(_ item: OutgoingMessage) -> [MessageAttachment] {
        if let cached = self.attachmentsByRequest[item.requestId] {
            return cached
        }
        var result: [MessageAttachment] = []
        for name in item.imageFiles {
            if let data = try? Data(contentsOf: self.directory.appendingPathComponent(name)), let image = UIImage(data: data) {
                result.append(MessageAttachment(id: self.mintAttachmentId?() ?? 0, kind: .image(image)))
            }
        }
        for file in item.files {
            result.append(MessageAttachment(id: self.mintAttachmentId?() ?? 0, kind: .file(FileAttachment(name: file.name, size: file.size, mimeType: "application/octet-stream"))))
        }
        for (index, upload) in (item.uploads ?? []).enumerated() {
            let url = self.localURL(upload)
            if upload.kind == .photo, let url, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                result.append(MessageAttachment(id: self.mintAttachmentId?() ?? 0, kind: .image(image)))
            } else {
                result.append(MessageAttachment(id: self.mintAttachmentId?() ?? 0, kind: .file(FileAttachment(name: upload.name, size: upload.size, mimeType: upload.mimeType, serverId: upload.serverId, localURL: url, transferKey: Outbox.transferKey(item.requestId, index)))))
            }
        }
        self.attachmentsByRequest[item.requestId] = result
        return result
    }

    // MARK: - Making changes

    /// A new message. `conversationId` nil sends it to the draft `createRequestId` once that exists.
    @discardableResult
    func enqueue(text: String, attachments: [MessageAttachment], conversationId: Int?, createRequestId: String?, mode: OutgoingMessage.Mode, showsInQueue: Bool, replaces: String? = nil) -> OutgoingMessage {
        let requestId = UUID().uuidString
        var uploads: [OutgoingMessage.Upload] = []
        var failure: String?
        let maxFileBytes = self.maxFileBytes?() ?? 0
        for attachment in attachments {
            switch attachment.kind {
            case let .image(image):
                guard let data = ImageEncoding.jpeg(image) else {
                    failure = "A photo could not be encoded"
                    continue
                }
                let name = "\(requestId)-\(uploads.count).jpg"
                try? data.write(to: self.directory.appendingPathComponent(name), options: .atomic)
                uploads.append(OutgoingMessage.Upload(kind: .photo, localName: name, name: "photo.jpg", size: Int64(data.count), mimeType: "image/jpeg"))
                if data.count > 5 * 1024 * 1024 {
                    failure = "A photo is larger than 5 MB"
                }
            case let .remote(remote):
                // An edited message's photo: the file the server kept. One sent before files were kept the store
                // fetches first (ServerStore.resolvingRemote), so what is queued has its data on disk.
                guard let fileId = remote.fileId else {
                    failure = "A photo was not loaded"
                    continue
                }
                uploads.append(OutgoingMessage.Upload(kind: .photo, localName: nil, name: "photo.jpg", size: Int64(remote.bytes), mimeType: remote.mimeType, serverId: fileId))
            case let .file(file):
                if let serverId = file.serverId {
                    uploads.append(OutgoingMessage.Upload(kind: .file, localName: nil, name: file.name, size: file.size, mimeType: file.mimeType, serverId: serverId))
                    continue
                }
                // A copy beside the outbox: the picked one may go before it is sent.
                let ext = (file.name as NSString).pathExtension
                let name = "\(requestId)-\(uploads.count)\(ext.isEmpty ? "" : ".\(ext)")"
                guard let source = file.localURL, (try? FileManager.default.copyItem(at: source, to: self.directory.appendingPathComponent(name))) != nil else {
                    failure = "\(file.name) could not be read"
                    continue
                }
                uploads.append(OutgoingMessage.Upload(kind: file.isImage && attachment.isPhoto ? .photo : .file, localName: name, name: file.name, size: file.size, mimeType: file.mimeType))
                if maxFileBytes > 0 && file.size > maxFileBytes {
                    failure = "\(file.name) is larger than \(ByteCountFormatter.string(fromByteCount: maxFileBytes, countStyle: .file))"
                }
            }
        }
        // The server refuses these too.
        if uploads.filter({ $0.kind == .photo }).count > 20 {
            failure = "A message can carry at most 20 photos"
        } else if uploads.count > 20 {
            failure = "A message can carry at most 20 files"
        } else if text.count > 1_000_000 {
            failure = "The message is longer than 1,000,000 characters"
        }
        let item = OutgoingMessage(
            requestId: requestId,
            conversationId: conversationId,
            createRequestId: createRequestId,
            rowId: self.takeRowId(),
            text: text,
            imageFiles: [],
            files: [],
            uploads: uploads,
            mode: mode,
            date: Date(),
            state: failure.map { .failed(code: "too_large", message: $0) } ?? .pending,
            showsInQueue: failure == nil && showsInQueue,
            seq: self.takeSeq(),
            replaces: replaces
        )
        self.attachmentsByRequest[requestId] = attachments
        self.items.append(item)
        self.save()
        self.changed?(conversationId)
        self.pump()
        return item
    }

    private func takeRowId() -> Int {
        let id = self.nextRowId
        self.nextRowId += 1
        return id
    }

    /// A draft conversation to create; its messages wait for it.
    func enqueueCreate(requestId: String, cwd: String?, title: String, agent: AgentSettings?, forkOf: Int? = nil, forkAt: Int? = nil) {
        guard self.create(requestId) == nil else {
            return
        }
        self.creates.append(PendingCreate(requestId: requestId, cwd: cwd, title: title, provider: agent?.provider, modelId: agent?.modelId, thinkingLevel: agent?.thinkingLevel, forkOf: forkOf, forkAt: forkAt))
        self.save()
        self.pump()
    }

    /// Cancel a message that has not reached the model: at once when the server never saw it, else by a withdraw in
    /// its turn. Returns false when it is past cancelling.
    @discardableResult
    func withdraw(_ requestId: String, restore: Bool) -> Bool {
        let result = self.markWithdrawing(requestId, restore: restore)
        self.pump()
        return result
    }

    /// Queue a message again with another mode: withdrawn, then sent anew if the withdraw came first.
    func move(_ requestId: String, to mode: OutgoingMessage.Mode) {
        guard let item = self.item(requestId), let conversationId = item.conversationId, self.markWithdrawing(requestId, restore: false) else {
            return
        }
        self.appendReplacement(of: item, conversationId: conversationId, mode: mode, showsInQueue: true)
        self.save()
        self.pump()
    }

    /// Interrupt the agent, as pi's Escape does: the queued messages `restoring` are withdrawn and come back to the
    /// input field, the run is aborted, and `sendNow`, if given, is sent at once in its place.
    func interrupt(conversationId: Int, restoring: [String], sendNow: String?, completion: @escaping (Result<JSONObject, RequestError>) -> Void) {
        for requestId in restoring where requestId != sendNow {
            self.markWithdrawing(requestId, restore: true)
        }
        var replacing: OutgoingMessage?
        if let sendNow, let item = self.item(sendNow), self.markWithdrawing(sendNow, restore: false) {
            replacing = item
        }
        self.transients.append(Transient(seq: self.takeSeq(), conversationId: conversationId, method: "conversation.abort", params: ["conversationId": conversationId], repeatable: true, deadline: CFAbsoluteTimeGetCurrent() + 20.0, completion: completion))
        if let replacing {
            // The run is over by then: the chat shows it with the clock until it is in the transcript.
            self.appendReplacement(of: replacing, conversationId: conversationId, mode: .steer, showsInQueue: false)
        }
        self.save()
        self.pump()
    }

    private func appendReplacement(of item: OutgoingMessage, conversationId: Int, mode: OutgoingMessage.Mode, showsInQueue: Bool) {
        let requestId = UUID().uuidString
        var imageFiles: [String] = []
        for name in item.imageFiles {
            let copy = "\(requestId)-\(imageFiles.count).jpg"
            try? FileManager.default.copyItem(at: self.directory.appendingPathComponent(name), to: self.directory.appendingPathComponent(copy))
            imageFiles.append(copy)
        }
        // What is uploaded goes again by its ID; what is not, from a copy of its own.
        let uploads = item.uploads.map { uploads in
            uploads.enumerated().map { index, upload -> OutgoingMessage.Upload in
                var copy = upload
                if let name = upload.localName {
                    let ext = (name as NSString).pathExtension
                    let newName = "\(requestId)-\(index)\(ext.isEmpty ? "" : ".\(ext)")"
                    try? FileManager.default.copyItem(at: self.directory.appendingPathComponent(name), to: self.directory.appendingPathComponent(newName))
                    copy.localName = newName
                }
                return copy
            }
        }
        let replacement = OutgoingMessage(
            requestId: requestId,
            conversationId: conversationId,
            createRequestId: nil,
            rowId: self.takeRowId(),
            text: item.text,
            imageFiles: imageFiles,
            files: item.files,
            uploads: uploads,
            mode: mode,
            date: Date(),
            state: .pending,
            showsInQueue: showsInQueue,
            seq: self.takeSeq(),
            replaces: item.requestId
        )
        self.attachmentsByRequest[requestId] = self.attachmentsByRequest[item.requestId]
        self.items.append(replacement)
        self.changed?(conversationId)
    }

    @discardableResult
    private func markWithdrawing(_ requestId: String, restore: Bool) -> Bool {
        guard let index = self.items.firstIndex(where: { $0.requestId == requestId }) else {
            return false
        }
        switch self.items[index].state {
        case .pending, .queued:
            break
        case .withdrawing:
            self.items[index].restoresOnWithdraw = self.items[index].restoresOnWithdraw || restore
            self.save()
            return true
        case .placed, .failed:
            return false
        }
        self.items[index].state = .withdrawing
        self.items[index].restoresOnWithdraw = restore
        self.items[index].needsRefresh = false
        // After everything already asked of this conversation.
        self.items[index].seq = self.takeSeq()
        self.save()
        self.changed?(self.items[index].conversationId)
        return true
    }

    /// Drop a failed message, or one that never left the device.
    func discard(_ requestId: String) {
        guard let index = self.items.firstIndex(where: { $0.requestId == requestId }) else {
            return
        }
        let item = self.items[index]
        if case .failed = item.state {
        } else if item.wasSent {
            return
        }
        self.remove(at: index)
    }

    /// A request in this conversation's order, after every message and request before it.
    func enqueueRequest(_ method: String, conversationId: Int, params: JSONObject, repeatable: Bool, completion: ((Result<JSONObject, RequestError>) -> Void)? = nil) {
        var params = params
        params["conversationId"] = conversationId
        self.transients.append(Transient(seq: self.takeSeq(), conversationId: conversationId, method: method, params: params, repeatable: repeatable, completion: completion))
        self.pump()
    }

    /// A request for a conversation whose create is still on its way: sent once it exists, in order with its messages.
    func enqueueRequest(_ method: String, createRequestId: String, params: JSONObject, repeatable: Bool, completion: ((Result<JSONObject, RequestError>) -> Void)? = nil) {
        self.transients.append(Transient(seq: self.takeSeq(), conversationId: nil, createRequestId: createRequestId, method: method, params: params, repeatable: repeatable, completion: completion))
    }

    /// Names a conversation not created yet, while its create has not gone out. False once it has: rename it instead.
    func renameCreate(_ requestId: String, title: String) -> Bool {
        guard self.sendingCreate != requestId, let index = self.creates.firstIndex(where: { $0.requestId == requestId && $0.conversationId == nil }) else {
            return false
        }
        self.creates[index].title = title
        self.creates[index].autoTitle = false
        self.save()
        return true
    }

    /// Changes the agent a create asks for, while it has not gone out. False once it has: configure it instead.
    func configureCreate(_ requestId: String, provider: String?, modelId: String?, thinkingLevel: String?) -> Bool {
        guard self.sendingCreate != requestId, let index = self.creates.firstIndex(where: { $0.requestId == requestId && $0.conversationId == nil }) else {
            return false
        }
        if let provider, let modelId {
            self.creates[index].provider = provider
            self.creates[index].modelId = modelId
        }
        if let thinkingLevel {
            self.creates[index].thinkingLevel = thinkingLevel
        }
        self.save()
        return true
    }

    private func remove(at index: Int) {
        let item = self.items.remove(at: index)
        for name in item.imageFiles + (item.uploads ?? []).compactMap(\.localName) {
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(name))
        }
        self.attachmentsByRequest[item.requestId] = nil
        if !self.items.contains(where: { $0.replaces == item.requestId }) {
            self.withdrawOutcomes[item.requestId] = nil
        }
        if let original = item.replaces {
            self.withdrawOutcomes[original] = nil
        }
        self.save()
        self.changed?(item.conversationId)
    }

    private func update(_ requestId: String, _ change: (inout OutgoingMessage) -> Void) {
        guard let index = self.items.firstIndex(where: { $0.requestId == requestId }) else {
            return
        }
        change(&self.items[index])
        self.save()
        self.changed?(self.items[index].conversationId)
    }

    // MARK: - What the server says

    /// Acknowledged messages ask again after a reconnect: a push may have been missed. A server with another
    /// database gets nothing written for the old one: those messages fail.
    func connected(serverId: String) {
        if let previous = self.serverId, previous != serverId {
            for index in self.items.indices {
                switch self.items[index].state {
                case .failed, .placed:
                    continue
                default:
                    self.items[index].state = .failed(code: "server_changed", message: "The server's data was replaced")
                    self.items[index].showsInQueue = false
                    self.items[index].needsRefresh = false
                }
            }
            self.items.removeAll { $0.isSettledInChat }
            self.creates.removeAll()
            self.transients.removeAll()
        }
        self.serverId = serverId
        self.save()
        self.changed?(nil)
        for id in Set(self.items.compactMap(\.conversationId)) {
            self.changed?(id)
        }
        var touched = false
        for index in self.items.indices {
            if case .queued = self.items[index].state {
                self.items[index].needsRefresh = true
                touched = true
            }
        }
        if touched {
            self.save()
        }
        self.pump()
    }

    /// A submission record from a push, a subscribe, or a response.
    func apply(record: JSONObject) {
        guard let index = self.items.firstIndex(where: { item in
            (record.int("id") != nil && item.submissionId == record.int("id")) || (record.string("requestId") != nil && item.requestId == record.string("requestId"))
        }) else {
            return
        }
        let requestId = self.items[index].requestId
        // A withdraw in its turn decides what becomes of a message being cancelled.
        if case .withdrawing = self.items[index].state {
            if let entry = record.int("entry") {
                self.items[index].submissionId = record.int("id")
                self.reachedModel(requestId, entryId: entry)
            }
            return
        }
        self.items[index].submissionId = record.int("id") ?? self.items[index].submissionId
        switch record.string("status") {
        case "queued":
            // Records can arrive out of order (a response read before a push that overtook it): never back from the
            // transcript to the queue.
            if case .placed = self.items[index].state {
                return
            }
            if let submissionId = record.int("id") {
                self.update(requestId) {
                    $0.state = .queued(submissionId: submissionId)
                    $0.showsInQueue = true
                    $0.needsRefresh = false
                }
            }
        case "placed", "done":
            if let entry = record.int("entry") {
                self.reachedModel(requestId, entryId: entry)
            }
        case "unanswered":
            if let entry = record.int("entry") {
                // In the transcript; the run that had it ended without an answer, which the transcript shows.
                self.reachedModel(requestId, entryId: entry)
            } else {
                // Withdrawn by someone else: a Stop on another device. It returns to the input, as pi returns queued
                // messages to the editor.
                let text = self.items[index].text
                let conversationId = self.items[index].conversationId
                self.remove(at: index)
                if let conversationId, !text.isEmpty {
                    self.restored?(conversationId, text)
                }
            }
        default:
            break
        }
    }

    /// Messages acknowledged as queued whose submissions the server no longer lists as unsettled: ask again what
    /// became of them.
    func refreshSettled(conversationId: Int, unsettled: Set<Int>) {
        var touched = false
        for index in self.items.indices where self.items[index].conversationId == conversationId {
            if case let .queued(submissionId) = self.items[index].state, !unsettled.contains(submissionId), !self.items[index].needsRefresh {
                self.items[index].needsRefresh = true
                touched = true
            }
        }
        if touched {
            self.save()
            self.pump()
        }
    }

    /// The entries a conversation's replica holds now: messages placed as one of them are rows of the transcript.
    func settle(conversationId: Int, entries: Set<Int>) {
        let done = self.items.filter { item in
            guard item.conversationId == conversationId, case let .placed(entryId) = item.state else {
                return false
            }
            return entries.contains(entryId)
        }
        guard !done.isEmpty else {
            return
        }
        for item in done {
            if let index = self.items.firstIndex(where: { $0.requestId == item.requestId }) {
                self.remove(at: index)
            }
        }
    }

    /// A commit put user entries in the transcript: each is the next inbox item it removed, or, placed straight from a
    /// submit, the oldest message on its way with that text. Matching them here, before the submission records come,
    /// lets a row change from the queue or the clock to the transcript in one step, with no duplicate in between.
    func matchPlacements(conversationId: Int, removedSubmissions: [Int], newUserEntries: [(id: Int, text: String, images: Int)]) {
        var removed = removedSubmissions.sorted()
        var used = Set<String>()
        for entry in newUserEntries.sorted(by: { $0.id < $1.id }) {
            var match: OutgoingMessage?
            if !removed.isEmpty {
                let submissionId = removed.removeFirst()
                match = self.items.first { $0.conversationId == conversationId && $0.submissionId == submissionId }
            } else {
                match = self.items.first { item in
                    guard item.conversationId == conversationId, !used.contains(item.requestId), item.wasSent, case .pending = item.state else {
                        return false
                    }
                    return entry.text.hasPrefix(item.text) && entry.images == item.attachmentCount
                }
            }
            if let match {
                used.insert(match.requestId)
                if case .withdrawing = match.state {
                    // The withdraw in its turn will report it delivered.
                    continue
                }
                self.reachedModel(match.requestId, entryId: entry.id)
            }
        }
    }

    private func reachedModel(_ requestId: String, entryId: Int) {
        self.update(requestId) {
            $0.state = .placed(entryId: entryId)
            $0.needsRefresh = false
        }
        self.placedEntry?(requestId, entryId)
    }

    /// A message became an entry: the store keeps its row ID for it.
    var placedEntry: ((String, Int) -> Void)?

    // MARK: - Sending

    private enum Operation {
        case submit(String)
        case withdraw(String)
        case transient(Int)
        case create(String)
    }

    /// Start the next operation of every conversation that has none in flight.
    func pump() {
        var conversations = Set(self.items.compactMap(\.conversationId))
        conversations.formUnion(self.transients.compactMap(\.conversationId))
        for conversationId in conversations {
            self.pump(conversationId: conversationId)
        }
        self.pumpCreates()
    }

    private func nextOperation(conversationId: Int) -> (seq: Int, operation: Operation)? {
        var best: (seq: Int, operation: Operation)?
        for item in self.items where item.conversationId == conversationId {
            var operation: Operation?
            switch item.state {
            case .pending:
                operation = .submit(item.requestId)
            case .queued where item.needsRefresh:
                operation = .submit(item.requestId)
            case .withdrawing:
                operation = .withdraw(item.requestId)
            default:
                break
            }
            if let operation, best.map({ item.seq < $0.seq }) ?? true {
                best = (item.seq, operation)
            }
        }
        for transient in self.transients where transient.conversationId == conversationId {
            if best.map({ transient.seq < $0.seq }) ?? true {
                best = (transient.seq, .transient(transient.seq))
            }
        }
        return best
    }

    private func pump(conversationId: Int) {
        let key = "c\(conversationId)"
        guard !self.inFlight.contains(key), !self.backoff.contains(key), let (_, operation) = self.nextOperation(conversationId: conversationId) else {
            return
        }
        switch operation {
        case let .withdraw(requestId):
            // Never written to a socket: nothing to ask the server.
            if let item = self.item(requestId), !item.wasSent {
                self.finishWithdraw(requestId, delivered: false, entryId: nil)
                self.pump(conversationId: conversationId)
                return
            }
            guard self.connection.isReady else {
                return
            }
            self.inFlight.insert(key)
            self.connection.request("submission.withdraw", ["conversationId": conversationId, "requestId": requestId]) { [weak self] result in
                guard let self else {
                    return
                }
                self.inFlight.remove(key)
                self.handleWithdraw(requestId, conversationId: conversationId, result: result)
                self.pump(conversationId: conversationId)
            }
        case let .submit(requestId):
            guard let item = self.item(requestId) else {
                return
            }
            // The second half of a move waits on the first.
            if let original = item.replaces {
                if let delivered = self.withdrawOutcomes[original] {
                    if delivered {
                        if let index = self.items.firstIndex(where: { $0.requestId == requestId }) {
                            self.remove(at: index)
                        }
                        self.notice?(conversationId, "The message reached the agent before it could move")
                        self.pump(conversationId: conversationId)
                        return
                    }
                } else if self.item(original) == nil {
                    // Unknown outcome (an older outbox): sending a duplicate is worse than not moving it.
                    if let index = self.items.firstIndex(where: { $0.requestId == requestId }) {
                        self.remove(at: index)
                    }
                    self.pump(conversationId: conversationId)
                    return
                }
            }
            guard self.connection.isReady else {
                return
            }
            if let index = item.uploads?.firstIndex(where: { $0.serverId == nil }), self.connection.hello?.files == true {
                self.upload(requestId, index: index, conversationId: conversationId, key: key)
                return
            }
            guard let content = self.content(item) else {
                let takesFiles = item.uploads == nil || item.uploads!.allSatisfy({ $0.kind == .photo }) || self.connection.hello?.files == true
                self.update(requestId) {
                    $0.state = .failed(code: "bad_request", message: takesFiles ? "A photo of this message is missing" : "This server does not take files: update it")
                }
                self.pump(conversationId: conversationId)
                return
            }
            if !item.wasSent {
                // On disk before it is on the wire: from now on a cancel must ask the server.
                self.update(requestId) {
                    $0.wasSent = true
                }
            }
            var params: JSONObject = ["conversationId": conversationId, "requestId": requestId, "content": content, "whenBusy": item.mode.rawValue]
            if let uploads = item.uploads, !uploads.isEmpty, self.connection.hello?.files == true {
                params["attachments"] = uploads.map { ["id": $0.serverId ?? "", "as": $0.kind == .photo ? "image" : "file"] as JSONObject }
            }
            self.inFlight.insert(key)
            self.connection.request("conversation.submit", params) { [weak self] result in
                guard let self else {
                    return
                }
                self.inFlight.remove(key)
                self.handleSubmit(requestId, conversationId: conversationId, result: result)
                self.pump(conversationId: conversationId)
            }
        case let .transient(seq):
            guard let transient = self.transients.first(where: { $0.seq == seq }) else {
                return
            }
            if let deadline = transient.deadline, CFAbsoluteTimeGetCurrent() > deadline {
                self.transients.removeAll { $0.seq == seq }
                transient.completion?(.failure(.timeout))
                self.pump(conversationId: conversationId)
                return
            }
            guard self.connection.isReady else {
                return
            }
            self.inFlight.insert(key)
            self.connection.request(transient.method, transient.params) { [weak self] result in
                guard let self else {
                    return
                }
                self.inFlight.remove(key)
                if case let .failure(error) = result, error.isConnectionError, transient.repeatable {
                    // Asked again once connected.
                } else {
                    self.transients.removeAll { $0.seq == seq }
                    transient.completion?(result)
                }
                self.pump(conversationId: conversationId)
            }
        case .create:
            break
        }
    }

    /// Upload one of a message's files, then go on with the message: the next upload, or its submit. A file the server
    /// refuses fails the message; no answer is tried again, as a submit is.
    private func upload(_ requestId: String, index: Int, conversationId: Int, key: String) {
        guard let item = self.item(requestId), let upload = item.uploads?[index], let transfer = self.transfer else {
            return
        }
        guard let url = self.localURL(upload), FileManager.default.fileExists(atPath: url.path) else {
            self.update(requestId) {
                $0.state = .failed(code: "bad_request", message: "\(upload.name) is missing")
                $0.showsInQueue = false
            }
            self.pump(conversationId: conversationId)
            return
        }
        self.inFlight.insert(key)
        transfer.upload(url, name: upload.name, key: Outbox.transferKey(requestId, index)) { [weak self] result in
            guard let self else {
                return
            }
            self.inFlight.remove(key)
            guard let current = self.items.firstIndex(where: { $0.requestId == requestId }) else {
                self.pump(conversationId: conversationId)
                return
            }
            switch result {
            case let .success(uploaded):
                self.items[current].uploads?[index].serverId = uploaded.id
                self.items[current].attempts = 0
                self.save()
                // Opened from here, never fetched back.
                transfer.seed(id: uploaded.id, name: upload.name, from: url)
            case .failure(.network):
                self.items[current].attempts = min(self.items[current].attempts + 1, 4)
                self.wait(key: key, attempt: self.items[current].attempts)
                return
            case let .failure(.refused(status, message)):
                if status == 401 {
                    // Its socket is turned away too: tried again when that connects.
                    self.wait(key: key, attempt: 4)
                    return
                }
                if status >= 500 && self.items[current].attempts + 1 < Outbox.maxAttempts {
                    self.items[current].attempts += 1
                    self.save()
                    self.wait(key: key, attempt: self.items[current].attempts)
                    return
                }
                self.update(requestId) {
                    $0.state = .failed(code: status == 413 ? "too_large" : "bad_request", message: message)
                    $0.showsInQueue = false
                }
            }
            self.pump(conversationId: conversationId)
        }
    }

    private func handleSubmit(_ requestId: String, conversationId: Int, result: Result<JSONObject, RequestError>) {
        guard let index = self.items.firstIndex(where: { $0.requestId == requestId }) else {
            return
        }
        switch result {
        case let .success(value):
            self.items[index].attempts = 0
            if let record = value.object("submission") {
                // The user cancelled while the submit was out: the withdraw in its turn settles it.
                if case .withdrawing = self.items[index].state {
                    self.items[index].submissionId = record.int("id")
                    self.save()
                    return
                }
                self.items[index].needsRefresh = false
                self.apply(record: record)
            }
        case let .failure(error):
            if error.isConnectionError {
                // Sent again, with the same request ID, once connected.
                return
            }
            if case .withdrawing = self.items[index].state {
                // Refused or withdrawn either way: nothing reached the model.
                return
            }
            switch error.code {
            case "withdrawn":
                self.remove(at: index)
            case "file_missing" where self.items[index].uploads?.allSatisfy({ $0.localName != nil }) == true && self.items[index].attempts + 1 < Outbox.maxAttempts:
                // Not used for a day, the server swept them: upload them again.
                self.items[index].attempts += 1
                for upload in self.items[index].uploads!.indices {
                    self.items[index].uploads![upload].serverId = nil
                }
                self.save()
            case "internal" where self.items[index].attempts + 1 < Outbox.maxAttempts:
                self.items[index].attempts += 1
                self.save()
                self.wait(key: "c\(conversationId)", attempt: self.items[index].attempts)
            default:
                let message = error.code == "not_found" ? "This chat no longer exists" : error.code == "file_missing" ? "A file of this message is no longer on the server" : error.message
                self.update(requestId) {
                    $0.state = .failed(code: error.code, message: message)
                    $0.showsInQueue = false
                    $0.needsRefresh = false
                }
            }
        }
    }

    private func handleWithdraw(_ requestId: String, conversationId: Int, result: Result<JSONObject, RequestError>) {
        switch result {
        case let .success(value):
            let record = value.object("submission")
            switch value.string("result") {
            case "withdrawn", "aborted":
                self.finishWithdraw(requestId, delivered: false, entryId: nil)
            case "already_placed":
                self.finishWithdraw(requestId, delivered: true, entryId: record?.int("entry"))
            default:
                // Settled before: in the transcript if it has an entry.
                let entry = record?.int("entry")
                self.finishWithdraw(requestId, delivered: entry != nil, entryId: entry)
            }
        case let .failure(error):
            if error.isConnectionError {
                return
            }
            if error.code == "not_found" {
                self.finishWithdraw(requestId, delivered: false, entryId: nil)
            } else {
                // A withdraw is never given up: the message must not stay half cancelled.
                let attempts = (self.item(requestId)?.attempts ?? 0) + 1
                self.update(requestId) {
                    $0.attempts = attempts
                }
                self.wait(key: "c\(conversationId)", attempt: attempts)
            }
        }
    }

    private func finishWithdraw(_ requestId: String, delivered: Bool, entryId: Int?) {
        guard let index = self.items.firstIndex(where: { $0.requestId == requestId }) else {
            return
        }
        let item = self.items[index]
        if self.items.contains(where: { $0.replaces == requestId }) {
            self.withdrawOutcomes[requestId] = delivered
        }
        if delivered {
            if let entryId {
                self.reachedModel(requestId, entryId: entryId)
            } else {
                self.update(requestId) {
                    $0.state = .pending
                    $0.restoresOnWithdraw = false
                }
            }
            if let conversationId = item.conversationId {
                self.notice?(conversationId, "Already delivered")
            }
            return
        }
        self.remove(at: index)
        if item.restoresOnWithdraw, let conversationId = item.conversationId, !item.text.isEmpty {
            self.restored?(conversationId, item.text)
        }
    }

    /// Exponential backoff for one key: 1, 2, 4, 8 s.
    private func wait(key: String, attempt: Int) {
        self.backoff.insert(key)
        Queue.mainQueue().after(pow(2.0, Double(max(0, attempt - 1)))) { [weak self] in
            self?.backoff.remove(key)
            self?.pump()
        }
    }

    private func content(_ item: OutgoingMessage) -> Any? {
        if let uploads = item.uploads, !uploads.isEmpty {
            if self.connection.hello?.files == true {
                return item.text
            }
            // A server from before files: photos inline, as they went then; files it cannot take.
            guard uploads.allSatisfy({ $0.kind == .photo }) else {
                return nil
            }
            var images: [JSONObject] = []
            for upload in uploads {
                guard let url = self.localURL(upload), let data = try? Data(contentsOf: url) else {
                    return nil
                }
                images.append(["type": "image", "data": data.base64EncodedString(), "mimeType": upload.mimeType])
            }
            return (item.text.isEmpty ? [] : [["type": "text", "text": item.text]]) + images
        }
        var images: [JSONObject] = []
        for name in item.imageFiles {
            guard let data = try? Data(contentsOf: self.directory.appendingPathComponent(name)) else {
                return nil
            }
            images.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        let files = item.files.map { "[Attached file: \($0.name), \(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))]" }
        let text = ([item.text] + files).filter { !$0.isEmpty }.joined(separator: "\n")
        if images.isEmpty {
            return text
        }
        return (text.isEmpty ? [] : [["type": "text", "text": text]]) + images
    }

    // MARK: - Creating drafts

    private func pumpCreates() {
        let key = "create"
        guard !self.inFlight.contains(key), !self.backoff.contains(key), self.connection.isReady, let create = self.creates.first(where: { $0.conversationId == nil }) else {
            return
        }
        if let forkOf = create.forkOf, let forkAt = create.forkAt {
            // An edit: the conversation up to the edited message, under the same title.
            self.inFlight.insert(key)
            self.sendingCreate = create.requestId
            self.connection.request("conversation.fork", ["conversationId": forkOf, "at": forkAt, "title": create.title, "requestId": create.requestId]) { [weak self] result in
                guard let self else {
                    return
                }
                self.inFlight.remove(key)
                self.sendingCreate = nil
                self.handleCreate(create.requestId, result: result)
                self.pump()
            }
            return
        }
        var params: JSONObject = ["requestId": create.requestId, "title": create.title, "autoTitle": create.autoTitle ?? true]
        var agent: JSONObject = [:]
        if let cwd = create.cwd {
            agent["cwd"] = cwd
        }
        if let provider = create.provider, let modelId = create.modelId {
            agent["model"] = ["provider": provider, "modelId": modelId]
        }
        if let thinkingLevel = create.thinkingLevel, thinkingLevel != "off" {
            agent["thinkingLevel"] = thinkingLevel
        }
        if !agent.isEmpty {
            params["agent"] = agent
        }
        self.inFlight.insert(key)
        self.sendingCreate = create.requestId
        self.connection.request("conversation.create", params) { [weak self] result in
            guard let self else {
                return
            }
            self.inFlight.remove(key)
            self.sendingCreate = nil
            self.handleCreate(create.requestId, result: result)
            self.pump()
        }
    }

    private func handleCreate(_ requestId: String, result: Result<JSONObject, RequestError>) {
        guard let index = self.creates.firstIndex(where: { $0.requestId == requestId }) else {
            return
        }
        switch result {
        case let .success(value):
            guard let dialog = value.object("dialog"), let conversationId = dialog.object("conversation")?.int("id") else {
                return
            }
            self.creates[index].conversationId = conversationId
            let create = self.creates[index]
            // Done: its messages belong to the conversation now.
            self.creates.remove(at: index)
            for itemIndex in self.items.indices where self.items[itemIndex].conversationId == nil && self.items[itemIndex].createRequestId == requestId {
                self.items[itemIndex].conversationId = conversationId
            }
            for index in self.transients.indices where self.transients[index].createRequestId == requestId {
                self.transients[index].conversationId = conversationId
                self.transients[index].params["conversationId"] = conversationId
            }
            self.save()
            self.created?(create, dialog)
            self.changed?(conversationId)
        case let .failure(error):
            if error.isConnectionError {
                return
            }
            if error.code == "internal" && self.creates[index].attempts + 1 < Outbox.maxAttempts {
                self.creates[index].attempts += 1
                self.save()
                self.wait(key: "create", attempt: self.creates[index].attempts)
                return
            }
            // The conversation cannot be made (its directory is gone, say): its messages fail with the reason.
            self.creates.remove(at: index)
            for itemIndex in self.items.indices where self.items[itemIndex].conversationId == nil && self.items[itemIndex].createRequestId == requestId {
                self.items[itemIndex].state = .failed(code: error.code, message: error.message)
            }
            let waiting = self.transients.filter { $0.createRequestId == requestId && $0.conversationId == nil }
            self.transients.removeAll { $0.createRequestId == requestId && $0.conversationId == nil }
            for transient in waiting {
                transient.completion?(.failure(error))
            }
            self.save()
            self.changed?(nil)
        }
    }
}

extension RequestError {
    /// The connection, not the server, failed: the request may or may not have arrived.
    var isConnectionError: Bool {
        return self.code == "disconnected" || self.code == "timeout"
    }
}
