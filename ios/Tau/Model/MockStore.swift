import UIKit
import SwiftSignalKit

/// In-memory stand-in for the tau server. Sending a message streams a canned answer the way the server does: a partial
/// message that grows every ~100 ms (one `pi.live` commit each), then a final entry.
final class MockStore: TauStore, TauServer {
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
        // Formulas as models write them, in every place Markdown puts them.
        let mathId = seeds.count + 2
        let mathMessages = MockStore.mathAnswers.enumerated().map { index, text in
            ChatMessage(id: self.mintId(), role: index % 2 == 0 ? .user : .assistant, text: text, date: now.addingTimeInterval(-7_200 + Double(index) * 30))
        }
        self.conversations[mathId] = ConversationState(messages: mathMessages, streaming: nil, busy: false)
        self.dialogs[mathId] = DialogModel(id: mathId, title: "Math stress", cwd: "~", model: "claude-opus-5-5", last: nil, busy: false)
        self.refreshDialog(mathId)
        // Some unread answers, and one chat in the archive, to show the badges and Archived Chats.
        self.dialogs[2]?.unreadCount = 2
        self.dialogs[3]?.markedUnread = true
        self.dialogs[seeds.count]?.archived = true
        self.publishDialogs()
    }

    static let mathAnswers: [String] = [
        "Show me some calculus",
        #"""
        The Gaussian integral is $\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}$, and the limit $\lim_{x \to 0} \frac{\sin x}{x} = 1$.

        $$
        \frac{d}{dx}\left( \int_{a}^{x} f(t)\,dt \right) = f(x)
        $$

        Taylor: \( e^x = \sum_{n=0}^{\infty} \frac{x^n}{n!} \) and display \[ \sin x = x - \frac{x^3}{3!} + \frac{x^5}{5!} - \cdots \]
        """#,
        "Linear algebra and probability",
        #"""
        1. The normal equations give $\hat{\boldsymbol{\beta}} = (X^\top X)^{-1} X^\top \mathbf{y}$.
        2. For a matrix $A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}$, $\det A = ad - bc$.
        3. Bayes: $P(A \mid B) = \dfrac{P(B \mid A)\,P(A)}{P(B)}$

        - Expectation $\mathbb{E}[X] = \sum_x x\,p(x)$, variance $\operatorname{Var}(X) = \mathbb{E}[X^2] - \mathbb{E}[X]^2$
        - Markov: $\Pr[X \ge t] \le \frac{\mathbb{E}[X]}{t}$ for $t > 0$

        > Note: $\|\mathbf{x}\|_2 = \sqrt{\sum_i x_i^2}$ inside a quote.

        | Quantity | Formula |
        |---|---|
        | Mean | $\mu = \frac{1}{n}\sum_i x_i$ |
        | Std | $\sigma = \sqrt{\frac{1}{n}\sum_i (x_i - \mu)^2}$ |
        """#,
        "Piecewise and aligned",
        #"""
        $$
        f(x) = \begin{cases}
        x^2 & \text{if } x \ge 0 \\
        -x & \text{otherwise}
        \end{cases}
        $$

        $$
        \begin{align}
        (a+b)^2 &= a^2 + 2ab + b^2 \\
        &\le 2(a^2 + b^2)
        \end{align}
        $$

        $$\begin{equation} E = mc^2 \tag{1} \end{equation}$$

        $$\operatorname*{arg\,max}_{\theta} \; \mathcal{L}(\theta) \quad\text{and}\quad \underbrace{a + \cdots + a}_{n \text{ times}} = na$$

        $$x \xrightarrow{f} y \implies \overset{?}{=} \quad \boxed{42}$$
        """#,
        "Edge cases",
        #"""
        Prices like $5 and $10 stay text, as does a lone $ sign. Escaped \$ too.

        Inline at the end of a sentence $a^2+b^2=c^2$. Then $x$, $y$ and $z$ with punctuation.

        Code is untouched: `$not math$` and

        ```python
        cost = "$" + str(x)  # $y$
        ```

        A long display formula that must shrink to fit the column:

        $$\sum_{i=1}^{n} \sum_{j=1}^{m} \left( a_{ij} + b_{ij} \right)^2 = \sum_{i=1}^{n} \sum_{j=1}^{m} a_{ij}^2 + 2 \sum_{i,j} a_{ij} b_{ij} + \sum_{i,j} b_{ij}^2$$

        Sets: $\{x \in \mathbb{R} \mid x > 0\}$, $A \subseteq B$, $\emptyset$, $\forall \epsilon > 0\ \exists \delta > 0$.
        Logic: $p \land q \Rightarrow \neg r$, $\therefore$ done. Not equal $a \not\equiv b \pmod{n}$.
        Greek $\alpha, \beta, \gamma, \Gamma, \varphi, \omega$ and $45^\circ$.
        Typed as Unicode: $x ∈ ℝ, a ≤ b, α → β$. Symbols $A \vdash B$, $f \hookrightarrow g$, $a \lesssim b$, $\checkmark$.
        """#,
    ]

    func dialogsSignal() -> Signal<[DialogModel], NoError> {
        return self.dialogsPromise.get()
    }

    func dialog(_ id: Int) -> DialogModel? {
        return self.dialogs[id]
    }

    func conversationSignal(_ id: Int) -> Signal<ConversationState, NoError> {
        return self.promise(id).get()
    }

    var connectionStatus: Signal<ConnectionStatus, NoError> {
        return .single(.online)
    }

    var serverInfo: ServerInfo? {
        return nil
    }

    private var inputDrafts: [String: InputDraft] = [:]

    func inputDraft(_ id: Int) -> InputDraft? {
        return self.inputDrafts[InputDraftStorage.key(id)]
    }

    func setInputDraft(_ draft: InputDraft?, for id: Int) {
        self.inputDrafts[InputDraftStorage.key(id)] = draft.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - One demo server

    let slot = 0
    let name = "demo"
    let address = "demo"
    let status: ConnectionStatus = .online
    let latency: Double? = 0.012
    let home: String? = "/Users/you"
    private(set) var defaultThinkingLevel = "off"

    func setDefaultThinkingLevel(_ level: String) {
        self.defaultThinkingLevel = level
    }

    private(set) var cacheWarming = "idle"

    func setCacheWarming(_ mode: String) {
        self.cacheWarming = mode
    }

    private(set) var compaction = CompactionThreshold.standard

    func setCompaction(_ threshold: CompactionThreshold) {
        self.compaction = threshold
    }

    var servers: [TauServer] {
        return [self]
    }

    var serversSignal: Signal<[TauServer], NoError> {
        return .single([self])
    }

    func server(_ slot: Int) -> TauServer? {
        return self
    }

    func server(of id: Int) -> TauServer? {
        return self
    }

    func createConversation(server slot: Int, cwd: String?) -> Int {
        return self.createConversation(cwd: cwd)
    }

    let isDemo = true

    var answers: Signal<ChatAnswer, NoError> {
        return .never()
    }

    func storageUsage() -> StorageUsage {
        return StorageUsage(chats: self.dialogs.keys.sorted().map { ($0, Int64(40_000 * $0)) }, unsentBytes: 0, draftBytes: 120)
    }

    func clearCache() {
    }

    var canPush: Bool {
        return false
    }

    var pushAlerts: Bool {
        return false
    }

    func setPushAlerts(_ value: Bool) {}

    func relocateDraft(_ id: Int, to location: ProjectLocation) -> Int {
        self.dialogs[id]?.cwd = location.path
        self.publish(id)
        return id
    }

    func addServer(address: String, token: String?, name: String?) {
    }

    func updateServer(_ slot: Int, address: String, token: String?, name: String?) {
    }

    func removeServer(_ slot: Int) {
    }

    func moveServer(from: Int, to: Int) {
    }

    func serverToken(_ slot: Int) -> String? {
        return nil
    }

    private(set) var defaultModel: String? = "anthropic/claude-opus-5-5"

    func setDefaultModel(_ model: ModelInfo) {
        self.defaultModel = "\(model.provider)/\(model.id)"
    }

    func markSeen(_ id: Int) {
        guard let dialog = self.dialogs[id], dialog.isUnread else {
            return
        }
        self.dialogs[id]?.unreadCount = 0
        self.dialogs[id]?.markedUnread = false
        self.publishDialogs()
    }

    func setUnread(_ id: Int, _ unread: Bool) {
        self.dialogs[id]?.markedUnread = unread
        if !unread {
            self.dialogs[id]?.unreadCount = 0
        }
        self.publishDialogs()
    }

    func setArchived(_ id: Int, _ archived: Bool) {
        self.dialogs[id]?.archived = archived
        self.publishDialogs()
    }

    func setPinned(_ id: Int, _ pinned: Bool) {
        self.dialogs[id]?.pinned = pinned ? Date().timeIntervalSince1970 * 1000.0 : nil
        self.publishDialogs()
    }

    func close() {
        for stream in self.streams.values {
            stream.invalidate()
        }
    }

    func stop(_ id: Int) {
        let queued = self.conversations[id]?.queued ?? []
        self.conversations[id]?.queued = []
        self.abortStream(id)
        for message in queued {
            self.emit(id, .restoreInput(message.text))
        }
    }

    func stopAndSend(_ text: String, attachments: [MessageAttachment], in id: Int) {
        self.stop(id)
        self.send(text, attachments: attachments, to: id, mode: .steer)
    }

    func sendNow(_ queued: QueuedMessage, in id: Int) {
        let others = (self.conversations[id]?.queued ?? []).filter { $0.id != queued.id }
        self.conversations[id]?.queued = []
        self.abortStream(id)
        for message in others {
            self.emit(id, .restoreInput(message.text))
        }
        self.send(queued.text, attachments: [], to: id, mode: .steer)
    }

    func withdraw(_ queued: QueuedMessage, in id: Int, restore: Bool) {
        self.conversations[id]?.queued.removeAll { $0.id == queued.id }
        self.publish(id)
        if restore {
            self.emit(id, .restoreInput(queued.text))
        }
    }

    func move(_ queued: QueuedMessage, in id: Int, to mode: SendMode) {
        guard let index = self.conversations[id]?.queued.firstIndex(where: { $0.id == queued.id }) else {
            return
        }
        self.conversations[id]?.queued[index].mode = mode == .steer ? .steer : .followUp
        self.publish(id)
    }

    func resend(_ outgoingId: String, in id: Int) {
    }

    func discard(_ outgoingId: String, in id: Int) {
    }

    private var eventSubscribers: [Int: Bag<(ChatEvent) -> Void>] = [:]

    private func emit(_ id: Int, _ event: ChatEvent) {
        for subscriber in self.eventSubscribers[id]?.copyItems() ?? [] {
            subscriber(event)
        }
    }

    func chatEvents(_ id: Int) -> Signal<ChatEvent, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                return EmptyDisposable
            }
            let bag = self.eventSubscribers[id] ?? Bag()
            self.eventSubscribers[id] = bag
            let index = bag.add { subscriber.putNext($0) }
            return ActionDisposable { [weak bag] in
                Queue.mainQueue().async {
                    bag?.remove(index)
                }
            }
        } |> runOn(Queue.mainQueue())
    }

    private func abortStream(_ id: Int) {
        self.streams[id]?.invalidate()
        self.streams[id] = nil
        if var state = self.conversations[id] {
            if let streaming = state.streaming {
                state.messages.append(streaming)
            }
            state.streaming = nil
            state.busy = false
            self.conversations[id] = state
            self.publish(id)
        }
    }

    func loadHistory(_ id: Int, through entryId: Int) {
    }

    func search(_ query: String, typing: Bool, offset: Int) -> Signal<SearchPage, NoError> {
        return .single(SearchPage(matches: [], hasMore: false, terms: []))
    }

    func searchConversation(_ id: Int, query: String, typing: Bool) -> Signal<ChatSearchResult, NoError> {
        return .single(ChatSearchResult(entryIds: [], terms: []))
    }

    func loadOlder(_ id: Int) {
    }

    func cachedModel(provider: String, id: String) -> ModelInfo? {
        return ModelInfo(provider: provider, id: id, name: id, reasoning: true, thinkingLevels: ["off", "minimal", "low", "medium", "high"])
    }

    func models() -> Signal<[ModelInfo], NoError> {
        return .single([
            ModelInfo(provider: "anthropic", id: "claude-opus-5-5", name: "Claude Opus 5.5", reasoning: true),
            ModelInfo(provider: "anthropic", id: "claude-haiku-5-5", name: "Claude Haiku 5.5", reasoning: true),
        ])
    }

    func agent(_ id: Int) -> AgentSettings {
        return AgentSettings(provider: "anthropic", modelId: self.dialogs[id]?.model, thinkingLevel: nil)
    }

    func configure(_ id: Int, model: ModelInfo?, thinkingLevel: String?) {
        if let model {
            self.dialogs[id]?.model = model.id
            self.publish(id)
        }
    }

    func compact(_ id: Int) {
    }

    func usage(_ id: Int) -> ConversationUsage {
        return ConversationUsage(models: [("anthropic/claude-opus-5-5", TokenUsage(input: 1_204, output: 18_330, cacheRead: 412_900, cacheWrite: 38_200, cost: 0.87))], contextTokens: 41_200, contextWindow: 200_000, cache: PromptCache(at: Date().addingTimeInterval(-48.0), ttl: 300.0, warming: true, warms: 4, cost: 0.12, saved: 1.30))
    }

    func usageReport(days: Int) -> Signal<UsageReport?, NoError> {
        return .single(nil)
    }

    func listDirectory(_ path: String?) -> Signal<DirectoryListing, RequestError> {
        let path = path ?? "/Users/you"
        let entries = ["work", "tau", "webapp", "engine", "notes"].map { DirectoryListing.Entry(name: $0, isDirectory: true, isRepository: $0 != "work" && $0 != "notes") }
        return .single(DirectoryListing(path: path, parent: path == "/" ? nil : (path as NSString).deletingLastPathComponent, entries: entries))
    }

    func resetContext(_ id: Int) {
    }

    func rename(_ id: Int, title: String) {
        self.dialogs[id]?.title = title
        self.publishDialogs()
        self.publish(id)
    }

    func edit(messageId: Int, text: String, attachments: [MessageAttachment], in id: Int, completion: @escaping (Int) -> Void) {
        self.edit(messageId: messageId, text: text, in: id)
        completion(id)
    }

    func createConversation(cwd: String?) -> Int {
        let cwd = cwd ?? "~/work/tau"
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

    func forkBefore(entryId: Int, in id: Int) -> Int? {
        return nil
    }

    func subagents(of id: Int) -> [DialogModel] {
        return []
    }

    func duplicateConversation(_ id: Int, completion: @escaping (Int) -> Void) {
        guard let state = self.conversations[id], let dialog = self.dialogs[id] else {
            return
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
        newDialog.unreadCount = 0
        newDialog.markedUnread = false
        newDialog.archived = false
        self.dialogs[newId] = newDialog
        self.refreshDialog(newId)
        self.publishDialogs()
        completion(newId)
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
        self.send(text, attachments: attachments, to: id, mode: .steer)
    }

    func send(_ text: String, attachments: [MessageAttachment], to id: Int, mode: SendMode) {
        guard var state = self.conversations[id] else {
            return
        }
        if self.streams[id] != nil {
            // Queued until the answer ends, as the server's inbox holds it.
            state.queued.append(QueuedMessage(id: "mock\(self.mintId())", mode: mode == .steer ? .steer : .followUp, text: text, imageCount: 0, isSending: false, outgoingId: nil, submissionId: nil))
            self.conversations[id] = state
            self.publish(id)
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
                if !state.queued.isEmpty {
                    // The run's end delivers the next queued message.
                    let next = state.queued.removeFirst()
                    self.conversations[id] = state
                    self.send(next.text, attachments: [], to: id, mode: .steer)
                    return
                }
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
