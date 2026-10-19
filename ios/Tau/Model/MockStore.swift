import UIKit
import SwiftSignalKit

/// In-memory stand-in for the tau server. Sending a message streams a canned answer the way the server does: a partial
/// message that grows every ~100 ms (one `pi.live` commit each), then a final entry.
final class MockStore {
    private var dialogs: [Int: DialogModel] = [:]
    private var conversations: [Int: ConversationState] = [:]
    private var nextId = 10_000

    private let dialogsPromise = ValuePromise<[DialogModel]>([], ignoreRepeated: true)
    private var conversationPromises: [Int: ValuePromise<ConversationState>] = [:]
    private var streams: [Int: SwiftSignalKit.Timer] = [:]
    /// Where the user left each chat, as Telegram keeps it in the chat's interface state.
    private var scrollStates: [Int: ChatScrollState] = [:]
    /// New conversations with no message yet: not in the chat list, and gone if left empty.
    private var drafts = Set<Int>()

    init() {
        let now = Date()
        let seeds: [(String, String, [(MessageRole, String)])] = [
            ("Fix flaky login test", "~/work/webapp", [
                (.user, "The login test fails about one run in five on CI. Can you find out why?"),
                (.assistant, "I'll look at the test and the code it exercises."),
                (.tool(name: "bash"), "$ npm test -- login --repeat 20\n4 of 20 runs failed: expected redirect to /home, got /login"),
                (.assistant, "The test clicks **Sign in** before the CSRF token request resolves. When the token arrives late, the form posts without it and the server redirects back to `/login`.\n\nI'll make the test wait for the token request first."),
                (.tool(name: "edit"), "test/login.spec.ts: +2 -0"),
                (.assistant, "Done. 50 consecutive runs pass now."),
            ]),
            ("tau server", "~/work/tau", [
                (.user, "Add a cwd picker to the protocol"),
                (.assistant, "Added `fs.list`, validated `cwd` on create and configure, and put each conversation's cwd in its dialog."),
            ]),
            ("Rust borrow checker", "~/src/engine", [
                (.user, "Why does this not compile? `let a = &mut v; v.push(1); a.len()`"),
                (.assistant, "`a` holds a mutable borrow of `v` until its last use, `a.len()`. `v.push(1)` needs a second mutable borrow while the first is still alive, which Rust forbids. Move `a.len()` before the push, or take the borrow after it."),
            ]),
            ("Release notes", "~/work/webapp", [
                (.user, "Draft release notes for 2.4 from the merged PRs"),
                (.assistant, "Here's a draft:\n\n**2.4**\n- Faster search on large projects\n- Dark mode for the settings page\n- Fixed: uploads over 2 GB failed silently"),
                (.user, "Compare the three storage backends in a table"),
                (.assistant, MockStore.tableAnswer),
            ]),
        ]
        for (index, seed) in seeds.enumerated() {
            let id = index + 1
            var messages: [ChatMessage] = []
            var date = now.addingTimeInterval(-Double(index) * 3_600 * 7 - 600)
            for (role, text) in seed.2 {
                messages.append(ChatMessage(id: self.mintId(), role: role, text: text, date: date))
                date = date.addingTimeInterval(20)
            }
            self.conversations[id] = ConversationState(messages: messages, streaming: nil, busy: false)
            self.dialogs[id] = DialogModel(id: id, title: seed.0, cwd: seed.1, model: "claude-opus-5-5", last: nil, busy: false)
            self.refreshDialog(id)
        }

        // A long conversation, to scroll.
        let longId = seeds.count + 1
        var messages: [ChatMessage] = []
        var date = now.addingTimeInterval(-86_400 * 3)
        for i in 0 ..< 300 {
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            let text = i % 2 == 0
                ? "Question \(i / 2 + 1): \(MockStore.questions[(i / 2) % MockStore.questions.count])"
                : MockStore.answers[(i / 2) % MockStore.answers.count]
            messages.append(ChatMessage(id: self.mintId(), role: role, text: text, date: date))
            date = date.addingTimeInterval(97)
        }
        self.conversations[longId] = ConversationState(messages: messages, streaming: nil, busy: false)
        self.dialogs[longId] = DialogModel(id: longId, title: "Long conversation", cwd: "~", model: "claude-opus-5-5", last: nil, busy: false)
        self.refreshDialog(longId)
        self.publishDialogs()
    }

    func dialogsSignal() -> Signal<[DialogModel], NoError> {
        return self.dialogsPromise.get()
    }

    func dialog(_ id: Int) -> DialogModel? {
        return self.dialogs[id]
    }

    func conversationSignal(_ id: Int) -> Signal<ConversationState, NoError> {
        return self.promise(id).get()
    }

    func createConversation(cwd: String) -> Int {
        let id = (self.dialogs.keys.max() ?? 0) + 1
        self.conversations[id] = ConversationState(messages: [], streaming: nil, busy: false)
        self.dialogs[id] = DialogModel(id: id, title: "New chat", cwd: cwd, model: "claude-opus-5-5", last: nil, busy: false)
        self.drafts.insert(id)
        return id
    }

    /// Drops a new conversation the user left without writing anything.
    func discardIfDraft(_ id: Int) {
        guard self.drafts.contains(id) else {
            return
        }
        self.drafts.remove(id)
        self.dialogs[id] = nil
        self.conversations[id] = nil
    }

    func scrollState(_ id: Int) -> ChatScrollState? {
        return self.scrollStates[id]
    }

    func setScrollState(_ state: ChatScrollState?, for id: Int) {
        self.scrollStates[id] = state
    }

    func deleteConversation(_ id: Int) {
        self.streams[id]?.invalidate()
        self.streams[id] = nil
        self.dialogs[id] = nil
        self.conversations[id] = nil
        self.publishDialogs()
    }

    func duplicateConversation(_ id: Int) -> Int? {
        guard let state = self.conversations[id], let dialog = self.dialogs[id] else {
            return nil
        }
        let newId = (self.dialogs.keys.max() ?? 0) + 1
        var copy = state
        copy.streaming = nil
        copy.busy = false
        copy.messages = copy.messages.map { message in
            var message = message
            message.id = self.mintId()
            return message
        }
        self.conversations[newId] = copy
        var newDialog = dialog
        newDialog.id = newId
        newDialog.title = dialog.title + " (copy)"
        self.dialogs[newId] = newDialog
        self.refreshDialog(newId)
        self.publishDialogs()
        return newId
    }

    func deleteMessages(_ ids: Set<Int>, in id: Int) {
        guard var state = self.conversations[id] else {
            return
        }
        state.messages.removeAll(where: { ids.contains($0.id) })
        self.conversations[id] = state
        self.publish(id)
    }

    /// Replace a user message and run again from there, as editing works on the server: a fork at the message before
    /// it, with the new text submitted.
    func edit(messageId: Int, text: String, in id: Int) {
        guard var state = self.conversations[id], let index = state.messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        self.streams[id]?.invalidate()
        self.streams[id] = nil
        let attachments = state.messages[index].attachments
        state.messages.removeSubrange(index...)
        state.streaming = nil
        self.conversations[id] = state
        self.send(text, attachments: attachments, to: id)
    }

    func send(_ text: String, attachments: [MessageAttachment] = [], to id: Int) {
        guard var state = self.conversations[id] else {
            return
        }
        state.messages.append(ChatMessage(id: self.mintId(), role: .user, text: text, date: Date(), attachments: attachments))
        if self.dialogs[id]?.title == "New chat" {
            self.dialogs[id]?.title = String(text.prefix(40))
        }
        self.drafts.remove(id)
        state.busy = true
        self.conversations[id] = state
        self.publish(id)
        if self.streams[id] == nil {
            Queue.mainQueue().after(0.6) {
                self.startStreaming(id, prompt: text.isEmpty ? "this attachment" : text)
            }
        }
    }

    private func startStreaming(_ id: Int, prompt: String) {
        let answer = MockStore.answer(to: prompt)
        let messageId = self.mintId()
        var revealed = 0
        let timer = SwiftSignalKit.Timer(timeout: 0.1, repeat: true, completion: { [weak self] in
            guard let self, var state = self.conversations[id] else {
                return
            }
            // Providers deliver uneven chunks; durable commits whatever arrived every 100 ms.
            revealed = min(answer.count, revealed + Int.random(in: 4 ... 18))
            let text = String(answer.prefix(revealed))
            if revealed < answer.count {
                state.streaming = ChatMessage(id: messageId, role: .assistant, text: text, date: Date())
            } else {
                state.streaming = nil
                state.messages.append(ChatMessage(id: messageId, role: .assistant, text: answer, date: Date()))
                state.busy = false
                self.streams[id]?.invalidate()
                self.streams[id] = nil
            }
            self.conversations[id] = state
            self.publish(id)
        }, queue: Queue.mainQueue())
        self.streams[id] = timer
        timer.start()
    }

    private func publish(_ id: Int) {
        if let state = self.conversations[id] {
            self.promise(id).set(state)
        }
        self.refreshDialog(id)
        self.publishDialogs()
    }

    private func refreshDialog(_ id: Int) {
        guard let state = self.conversations[id], var dialog = self.dialogs[id] else {
            return
        }
        if let last = state.messages.last {
            var text = last.text
            if text.isEmpty, let attachment = last.attachments.first {
                if case let .file(name, _) = attachment.kind {
                    text = name
                } else {
                    text = last.attachments.count > 1 ? "\(last.attachments.count) Photos" : "Photo"
                }
            }
            dialog.last = DialogModel.EntrySummary(id: last.id, role: last.role, text: text, date: last.date)
        }
        dialog.busy = state.busy
        self.dialogs[id] = dialog
    }

    private func publishDialogs() {
        let sorted = self.dialogs.values.filter { !self.drafts.contains($0.id) }.sorted { ($0.last?.date ?? .distantFuture) > ($1.last?.date ?? .distantFuture) }
        self.dialogsPromise.set(sorted)
    }

    private func promise(_ id: Int) -> ValuePromise<ConversationState> {
        if let promise = self.conversationPromises[id] {
            return promise
        }
        let promise = ValuePromise<ConversationState>(self.conversations[id] ?? ConversationState(messages: [], streaming: nil, busy: false), ignoreRepeated: true)
        self.conversationPromises[id] = promise
        return promise
    }

    func mintAttachmentId() -> Int {
        return self.mintId()
    }

    private func mintId() -> Int {
        self.nextId += 1
        return self.nextId
    }

    private static func answer(to prompt: String) -> String {
        let lower = prompt.lowercased()
        if lower.contains("table") {
            return MockStore.tableAnswer
        }
        if lower.contains("hello") || lower.contains("hi") {
            return "Hi! I'm the mock agent. The real one runs on your tau server; this one only streams canned answers so the UI has something to draw."
        }
        return "Here's how I'd approach \"\(prompt.prefix(60))\":\n\n1. Read the relevant code and reproduce the problem.\n2. Write a failing test that captures it.\n3. Make the smallest change that fixes it, then run the whole suite.\n\nThis answer is streamed in uneven chunks every 100 ms, the way durable commits a provider's partial message, so the reveal animation can smooth it out."
    }

    static let tableAnswer = """
Here is how the three storage backends compare:

| Backend | Persists | Crash safety | Best for |
|---|---|---|---|
| Memory | No | — | Tests, previews |
| SQLite | Yes | WAL, commits survive a process crash | Long-running agents |
| JSONL | Yes | Append-only, optional `fsync` | Inspecting history by hand |

SQLite is the default for `tau-server`: it keeps memory flat however long a conversation gets, while JSONL holds the whole history in memory.
"""

    private static let questions = [
        "How do I undo the last git commit but keep the changes?",
        "What's the difference between a process and a thread?",
        "Can you explain what a monad is without the jargon?",
        "Why is my Docker image 2 GB?",
        "How should I structure a Swift package with several modules?",
    ]

    private static let answers = [
        "`git reset --soft HEAD~1` moves the branch back one commit and leaves the changes staged.",
        "A process has its own memory; threads share their process's memory. Switching between threads is cheaper, but they must coordinate access to what they share.",
        "It's a wrapper type with a way to chain steps that each produce a wrapped value: Optional chaining and Promise.then are both examples.",
        "Usually the build toolchain and caches end up in the final image. Use a multi-stage build and copy only the output into a slim base image.",
        "One target per module under Sources/, each with its own folder, and dependencies declared between targets in Package.swift. Keep the public surface of each small.",
    ]
}
