import Foundation
import UIKit
import SwiftSignalKit

/// What a chat's input field holds while nothing is sent, as Telegram's ChatInterfaceState keeps it: the message being
/// written and, while a sent message is being edited, the edit beside it. It survives leaving the chat, the app being
/// killed, and a crash.
struct InputDraft: Codable, Equatable {
    /// The message being written. While editing, what was being written before the edit began, which comes back after.
    var text: String = ""
    /// Editing the sent message from this entry, with this text so far.
    var editEntryId: Int?
    var editText: String?
    var date: Date = Date()

    var isEmpty: Bool {
        return self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && self.editEntryId == nil
    }
}

/// Drafts on disk, one file per server: written a moment after each change and whenever the app leaves the
/// foreground, so at most the last keystrokes before a crash are lost.
final class InputDraftStorage {
    /// The draft of the chat not created yet (New Chat): there is one at a time.
    static let newChatKey = "new"

    private let fileURL: URL
    private var drafts: [String: InputDraft] = [:]
    private var saveScheduled = false
    /// The key of a draft that changed.
    var changed: ((String) -> Void)?

    init(namespace: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = namespace.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        let directory = base.appendingPathComponent("tau/drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("\(safe).json")
        if let data = try? Data(contentsOf: self.fileURL), let stored = try? JSONDecoder().decode([String: InputDraft].self, from: data) {
            self.drafts = stored
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.flush), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.flush), name: UIApplication.willTerminateNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var diskBytes: Int64 {
        return Int64((try? self.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func key(_ conversationId: Int) -> String {
        return conversationId < 0 ? InputDraftStorage.newChatKey : String(conversationId)
    }

    func draft(_ key: String) -> InputDraft? {
        return self.drafts[key]
    }

    func set(_ draft: InputDraft?, for key: String) {
        let value = draft.flatMap { $0.isEmpty ? nil : $0 }
        guard self.drafts[key] != value else {
            return
        }
        self.drafts[key] = value
        self.changed?(key)
        if !self.saveScheduled {
            self.saveScheduled = true
            Queue.mainQueue().after(0.3) { [weak self] in
                self?.flush()
            }
        }
    }

    @objc func flush() {
        self.saveScheduled = false
        if let data = try? JSONEncoder().encode(self.drafts) {
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }
}
