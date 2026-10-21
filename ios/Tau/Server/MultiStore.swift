import Foundation
import SwiftSignalKit

/// A configured server: where it is, its token, and the name the user gave it.
struct ServerConfig: Codable, Equatable {
    var slot: Int
    var address: String
    var token: String?
    var name: String?
}

/// The servers on disk (UserDefaults). `-server.url` (and `-server2.url`, ...) on the command line replace them for
/// that launch, as the UI tests do, without saving.
enum ServerConfigStorage {
    private static let key = "servers"

    static var isOverridden: Bool {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return arguments["server.url"] != nil
    }

    static func load() -> [ServerConfig] {
        let defaults = UserDefaults.standard
        if self.isOverridden {
            var configs = [ServerConfig(slot: 0, address: defaults.string(forKey: "server.url") ?? defaultServerURL, token: defaults.string(forKey: "server.token"), name: nil)]
            var index = 2
            while let address = defaults.string(forKey: "server\(index).url") {
                configs.append(ServerConfig(slot: index - 1, address: address, token: defaults.string(forKey: "server\(index).token"), name: nil))
                index += 1
            }
            return configs
        }
        if let data = defaults.data(forKey: self.key), let configs = try? JSONDecoder().decode([ServerConfig].self, from: data), !configs.isEmpty {
            return configs
        }
        // Before there were several: the one server's address, as Settings saved it.
        return [ServerConfig(slot: 0, address: defaults.string(forKey: "server.url") ?? defaultServerURL, token: defaults.string(forKey: "server.token"), name: nil)]
    }

    static func save(_ configs: [ServerConfig]) {
        guard !self.isOverridden, let data = try? JSONEncoder().encode(configs) else {
            return
        }
        UserDefaults.standard.set(data, forKey: self.key)
    }
}

/// Every configured server at once: one ServerStore each, connected together, their chats in one list. A
/// conversation's ID carries its server's slot above bit 40, so the first server's IDs are its own (MultiStore.global).
final class MultiStore: TauStore {
    private static let shift = 40
    private static let mask = (1 << 40) - 1

    private var configs: [ServerConfig]
    private var stores: [Int: ServerStore] = [:]
    private let serversPromise = Promise<[TauServer]>()
    private let storesPromise = ValuePromise<[Int]>([], ignoreRepeated: true)

    init(configs: [ServerConfig]) {
        self.configs = configs
        for config in configs {
            self.start(config)
        }
        self.publishServers()
    }

    /// The global ID of conversation `local` on server `slot`; drafts stay negative.
    static func global(_ slot: Int, _ local: Int) -> Int {
        if slot == 0 {
            return local
        }
        return local >= 0 ? (slot << MultiStore.shift) | local : -((slot << MultiStore.shift) | -local)
    }

    static func split(_ id: Int) -> (slot: Int, local: Int) {
        if id >= 0 {
            return (id >> MultiStore.shift, id & MultiStore.mask)
        }
        let value = -id
        return (value >> MultiStore.shift, -(value & MultiStore.mask))
    }

    private func start(_ config: ServerConfig) {
        guard let url = URL(string: config.address) else {
            return
        }
        let store = ServerStore(url: url, token: config.token, slot: config.slot, name: config.name)
        store.infoChanged = { [weak self] in
            self?.publishServers()
        }
        self.stores[config.slot] = store
    }

    private func publishServers() {
        self.serversPromise.set(.single(self.servers))
        self.storesPromise.set(self.configs.map(\.slot).filter { self.stores[$0] != nil })
    }

    private func route(_ id: Int) -> (ServerStore, Int)? {
        let (slot, local) = MultiStore.split(id)
        guard let store = self.stores[slot] else {
            return nil
        }
        return (store, local)
    }

    private func mapped(_ dialog: DialogModel, _ slot: Int) -> DialogModel {
        var dialog = dialog
        dialog.id = MultiStore.global(slot, dialog.id)
        dialog.parentConversationId = dialog.parentConversationId.map { MultiStore.global(slot, $0) }
        dialog.serverSlot = slot
        dialog.serverName = self.configs.count > 1 ? self.stores[slot]?.name : nil
        return dialog
    }

    private func mapped(_ message: ChatMessage, _ slot: Int) -> ChatMessage {
        guard slot != 0, let child = message.tool?.childConversationId else {
            return message
        }
        var message = message
        message.tool?.childConversationId = MultiStore.global(slot, child)
        return message
    }

    // MARK: - Servers

    var servers: [TauServer] {
        return self.configs.compactMap { self.stores[$0.slot] }
    }

    var serversSignal: Signal<[TauServer], NoError> {
        return self.serversPromise.get()
    }

    func server(_ slot: Int) -> TauServer? {
        return self.stores[slot]
    }

    func server(of id: Int) -> TauServer? {
        return self.route(id)?.0
    }

    var isDemo: Bool {
        return false
    }

    func serverToken(_ slot: Int) -> String? {
        return self.configs.first(where: { $0.slot == slot })?.token
    }

    func addServer(address: String, token: String?, name: String?) {
        // Slots are never reused: a removed server's IDs must not name another's conversations.
        let used = self.configs.map(\.slot).max() ?? -1
        let stored = UserDefaults.standard.integer(forKey: "servers.nextSlot")
        let slot = max(used + 1, stored)
        UserDefaults.standard.set(slot + 1, forKey: "servers.nextSlot")
        let config = ServerConfig(slot: slot, address: address, token: token, name: name)
        self.configs.append(config)
        ServerConfigStorage.save(self.configs)
        self.start(config)
        self.publishServers()
    }

    func updateServer(_ slot: Int, address: String, token: String?, name: String?) {
        guard let index = self.configs.firstIndex(where: { $0.slot == slot }) else {
            return
        }
        let previous = self.configs[index]
        self.configs[index] = ServerConfig(slot: slot, address: address, token: token, name: name)
        ServerConfigStorage.save(self.configs)
        if previous.address != address || previous.token != token {
            self.stores[slot]?.close()
            self.stores[slot] = nil
            self.start(self.configs[index])
        } else {
            self.stores[slot]?.configuredName = name
        }
        self.publishServers()
    }

    func removeServer(_ slot: Int) {
        self.configs.removeAll { $0.slot == slot }
        ServerConfigStorage.save(self.configs)
        self.stores[slot]?.close()
        self.stores[slot] = nil
        self.publishServers()
    }

    func moveServer(from: Int, to: Int) {
        guard from != to, self.configs.indices.contains(from), self.configs.indices.contains(to) else {
            return
        }
        let config = self.configs.remove(at: from)
        self.configs.insert(config, at: to)
        ServerConfigStorage.save(self.configs)
        self.publishServers()
    }

    /// Telegram's title for all of them: waiting for network or connecting only while no server is reachable,
    /// updating while a reachable one catches up.
    var connectionStatus: Signal<ConnectionStatus, NoError> {
        return self.storesPromise.get() |> mapToSignal { [weak self] slots -> Signal<ConnectionStatus, NoError> in
            guard let self else {
                return .single(.online)
            }
            let signals = slots.compactMap { self.stores[$0]?.connectionStatus }
            if signals.isEmpty {
                return .single(.online)
            }
            return combineLatest(signals) |> map { statuses -> ConnectionStatus in
                if statuses.contains(.updating) {
                    return .updating
                }
                if statuses.contains(.online) {
                    return .online
                }
                return statuses.allSatisfy { $0 == .waitingForNetwork } ? .waitingForNetwork : .connecting
            }
        } |> distinctUntilChanged
    }

    // MARK: - Conversations

    func close() {
        for store in self.stores.values {
            store.close()
        }
    }

    func dialogsSignal() -> Signal<[DialogModel], NoError> {
        return self.storesPromise.get() |> mapToSignal { [weak self] slots -> Signal<[DialogModel], NoError> in
            guard let self else {
                return .single([])
            }
            let signals = slots.compactMap { slot in self.stores[slot].map { store in store.dialogsSignal() |> map { dialogs in dialogs.map { self.mapped($0, slot) } } } }
            if signals.count == 1 {
                return signals[0]
            }
            if signals.isEmpty {
                return .single([])
            }
            // Each server's list is in its own order; together, the newest first.
            return combineLatest(signals) |> map { lists -> [DialogModel] in
                return lists.flatMap { $0 }.sorted { MultiStore.activity($0) > MultiStore.activity($1) }
            }
        }
    }

    private static func activity(_ dialog: DialogModel) -> Date {
        return [dialog.last?.date, dialog.outgoing?.date].compactMap { $0 }.max() ?? .distantPast
    }

    func dialog(_ id: Int) -> DialogModel? {
        guard let (store, local) = self.route(id), let dialog = store.dialog(local) else {
            return nil
        }
        return self.mapped(dialog, store.slot)
    }

    func conversationSignal(_ id: Int) -> Signal<ConversationState, NoError> {
        guard let (store, local) = self.route(id) else {
            return .never()
        }
        let slot = store.slot
        return store.conversationSignal(local) |> map { [weak self] state -> ConversationState in
            guard let self, slot != 0 else {
                return state
            }
            var state = state
            state.messages = state.messages.map { self.mapped($0, slot) }
            return state
        }
    }

    func createConversation(cwd: String?) -> Int {
        return self.createConversation(server: self.configs.first?.slot ?? 0, cwd: cwd)
    }

    func createConversation(server slot: Int, cwd: String?) -> Int {
        guard let store = self.stores[slot] else {
            return 0
        }
        return MultiStore.global(slot, store.createConversation(cwd: cwd ?? store.home))
    }

    func relocateDraft(_ id: Int, to location: ProjectLocation) -> Int {
        guard let (store, local) = self.route(id) else {
            return id
        }
        if store.slot == location.slot, store.setDraftCwd(local, cwd: location.path) {
            return id
        }
        let moved = self.createConversation(server: location.slot, cwd: location.path)
        self.setInputDraft(store.inputDraft(local), for: moved)
        return moved
    }

    var answers: Signal<ChatAnswer, NoError> {
        return self.storesPromise.get() |> mapToSignal { [weak self] slots -> Signal<ChatAnswer, NoError> in
            guard let self else {
                return .never()
            }
            let signals = slots.compactMap { slot in self.stores[slot].map { store in store.answers |> map { answer -> ChatAnswer in
                var answer = answer
                answer.conversationId = MultiStore.global(slot, answer.conversationId)
                return answer
            } } }
            // Every server's answers as they come.
            return Signal { subscriber in
                let disposables = DisposableSet()
                for signal in signals {
                    disposables.add(signal.start(next: { subscriber.putNext($0) }))
                }
                return disposables
            }
        }
    }

    func inputDraft(_ id: Int) -> InputDraft? {
        guard let (store, local) = self.route(id) else {
            return nil
        }
        return store.inputDraft(local)
    }

    func setInputDraft(_ draft: InputDraft?, for id: Int) {
        self.route(id).map { $0.0.setInputDraft(draft, for: $0.1) }
    }

    func discardIfDraft(_ id: Int) {
        self.route(id).map { $0.0.discardIfDraft($0.1) }
    }

    func deleteConversation(_ id: Int) {
        self.route(id).map { $0.0.deleteConversation($0.1) }
    }

    func duplicateConversation(_ id: Int, completion: @escaping (Int) -> Void) {
        guard let (store, local) = self.route(id) else {
            return
        }
        let slot = store.slot
        store.duplicateConversation(local, completion: { completion(MultiStore.global(slot, $0)) })
    }

    func markSeen(_ id: Int) {
        self.route(id).map { $0.0.markSeen($0.1) }
    }

    func setUnread(_ id: Int, _ unread: Bool) {
        self.route(id).map { $0.0.setUnread($0.1, unread) }
    }

    func setArchived(_ id: Int, _ archived: Bool) {
        self.route(id).map { $0.0.setArchived($0.1, archived) }
    }

    func send(_ text: String, attachments: [MessageAttachment], to id: Int, mode: SendMode) {
        self.route(id).map { $0.0.send(text, attachments: attachments, to: $0.1, mode: mode) }
    }

    func edit(messageId: Int, text: String, in id: Int, completion: @escaping (Int) -> Void) {
        guard let (store, local) = self.route(id) else {
            return
        }
        let slot = store.slot
        store.edit(messageId: messageId, text: text, in: local, completion: { completion(MultiStore.global(slot, $0)) })
    }

    func stop(_ id: Int) {
        self.route(id).map { $0.0.stop($0.1) }
    }

    func stopAndSend(_ text: String, attachments: [MessageAttachment], in id: Int) {
        self.route(id).map { $0.0.stopAndSend(text, attachments: attachments, in: $0.1) }
    }

    func sendNow(_ queued: QueuedMessage, in id: Int) {
        self.route(id).map { $0.0.sendNow(queued, in: $0.1) }
    }

    func withdraw(_ queued: QueuedMessage, in id: Int, restore: Bool) {
        self.route(id).map { $0.0.withdraw(queued, in: $0.1, restore: restore) }
    }

    func move(_ queued: QueuedMessage, in id: Int, to mode: SendMode) {
        self.route(id).map { $0.0.move(queued, in: $0.1, to: mode) }
    }

    func resend(_ outgoingId: String, in id: Int) {
        self.route(id).map { $0.0.resend(outgoingId, in: $0.1) }
    }

    func discard(_ outgoingId: String, in id: Int) {
        self.route(id).map { $0.0.discard(outgoingId, in: $0.1) }
    }

    func chatEvents(_ id: Int) -> Signal<ChatEvent, NoError> {
        guard let (store, local) = self.route(id) else {
            return .never()
        }
        return store.chatEvents(local)
    }

    func loadOlder(_ id: Int) {
        self.route(id).map { $0.0.loadOlder($0.1) }
    }

    func agent(_ id: Int) -> AgentSettings {
        guard let (store, local) = self.route(id) else {
            return AgentSettings(provider: nil, modelId: nil, thinkingLevel: nil)
        }
        return store.agent(local)
    }

    func configure(_ id: Int, model: ModelInfo?, thinkingLevel: String?) {
        self.route(id).map { $0.0.configure($0.1, model: model, thinkingLevel: thinkingLevel) }
    }

    func compact(_ id: Int) {
        self.route(id).map { $0.0.compact($0.1) }
    }

    func rename(_ id: Int, title: String) {
        self.route(id).map { $0.0.rename($0.1, title: title) }
    }

    func resetContext(_ id: Int) {
        self.route(id).map { $0.0.resetContext($0.1) }
    }

    func usage(_ id: Int) -> ConversationUsage {
        guard let (store, local) = self.route(id) else {
            return ConversationUsage(models: [], contextTokens: nil, contextWindow: nil)
        }
        return store.usage(local)
    }

    func scrollState(_ id: Int) -> ChatScrollState? {
        guard let (store, local) = self.route(id) else {
            return nil
        }
        return store.scrollState(local)
    }

    func setScrollState(_ state: ChatScrollState?, for id: Int) {
        self.route(id).map { $0.0.setScrollState(state, for: $0.1) }
    }

    func mintAttachmentId() -> Int {
        return self.stores[self.configs.first?.slot ?? 0]?.mintAttachmentId() ?? 0
    }
}
