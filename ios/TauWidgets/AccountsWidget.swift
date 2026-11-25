import SwiftUI
import WidgetKit

// The usage widget (docs/accounts.md): the plan usage of the accounts in use, as bars with the pace tick, on the home
// and lock screens. It asks the servers itself, with the addresses and tokens the app leaves in the shared keychain
// group (ShareModels.swift), every quarter of an hour; the reset times count down on their own in between.

struct AccountsEntry: TimelineEntry {
    struct Account: Codable, Equatable {
        var id: String
        var service: String
        var title: String
        var plan: String?
        var windows: [Window]
    }

    struct Window: Codable, Equatable {
        var label: String
        var usedPercent: Double
        var resetsAt: Date?
        var seconds: Double?

        var elapsed: Double? {
            guard let resetsAt, let seconds, seconds > 0 else {
                return nil
            }
            return min(1.0, max(0.0, 1.0 - resetsAt.timeIntervalSinceNow / seconds))
        }

        var color: Color {
            if self.usedPercent >= 90 {
                return .red
            }
            if let elapsed = self.elapsed, self.usedPercent >= ((self.seconds ?? 0) > 86_400 ? 30 : 50), self.usedPercent > elapsed * 100 + 15 {
                return .orange
            }
            return .accentColor
        }

        var percent: String {
            return "\(self.usedPercent >= 100 ? 100 : min(99, Int(self.usedPercent.rounded())))%"
        }
    }

    let date: Date
    let accounts: [Account]
    /// Why there is nothing to show.
    let note: String?

    static let placeholder = AccountsEntry(date: Date(), accounts: [
        Account(id: "1", service: "Claude", title: "me@example.com", plan: "Max", windows: [
            Window(label: "5h", usedPercent: 42, resetsAt: Date().addingTimeInterval(8_000), seconds: 18_000),
            Window(label: "Week", usedPercent: 71, resetsAt: Date().addingTimeInterval(300_000), seconds: 604_800),
        ]),
        Account(id: "2", service: "ChatGPT", title: "me@example.com", plan: "Plus", windows: [
            Window(label: "5h", usedPercent: 12, resetsAt: Date().addingTimeInterval(4_000), seconds: 18_000),
            Window(label: "Week", usedPercent: 31, resetsAt: Date().addingTimeInterval(500_000), seconds: 604_800),
        ]),
    ], note: nil)
}

struct AccountsProvider: TimelineProvider {
    private static let cacheKey = "accountsWidget.last"

    func placeholder(in context: Context) -> AccountsEntry {
        return .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (AccountsEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        Task {
            completion(await self.load())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccountsEntry>) -> Void) {
        Task {
            let entry = await self.load()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    /// Every server's accounts in use with plan usage, in the order each server has them; the last ones had when no
    /// server answers.
    private func load() async -> AccountsEntry {
        guard let snapshot = ShareGroup.snapshot, !snapshot.servers.isEmpty else {
            return AccountsEntry(date: Date(), accounts: [], note: "Open tau to connect it to a server.")
        }
        var accounts: [AccountsEntry.Account] = []
        var answered = false
        for server in snapshot.servers {
            guard let connection = ShareConnection(address: server.address, token: server.token) else {
                continue
            }
            defer {
                connection.close()
            }
            do {
                _ = try await connection.request("hello", ["protocol": 1])
                let state = AccountsState(json: try await connection.request("accounts.subscribe", [:]))
                answered = true
                for account in state.accounts where account.active {
                    // Limits only: spend without one has no bar to show and nothing to run out of.
                    let windows = (account.usage?.windows ?? []).compactMap { window in
                        window.usedPercent.map { AccountsEntry.Window(label: window.label, usedPercent: $0, resetsAt: window.resetsAt, seconds: window.seconds) }
                    }
                    guard !windows.isEmpty else {
                        continue
                    }
                    accounts.append(AccountsEntry.Account(id: account.id, service: account.serviceName, title: account.title, plan: account.plan, windows: windows))
                }
            } catch {
                continue
            }
        }
        let defaults = UserDefaults.standard
        if answered {
            if let data = try? JSONEncoder().encode(accounts) {
                defaults.set(data, forKey: AccountsProvider.cacheKey)
            }
            return AccountsEntry(date: Date(), accounts: accounts, note: accounts.isEmpty ? "No account in use has plan usage." : nil)
        }
        if let data = defaults.data(forKey: AccountsProvider.cacheKey), let cached = try? JSONDecoder().decode([AccountsEntry.Account].self, from: data), !cached.isEmpty {
            return AccountsEntry(date: Date(), accounts: cached, note: nil)
        }
        return AccountsEntry(date: Date(), accounts: [], note: "Can't reach the server.")
    }
}

/// A bar: the used part in its color over a track, and a tick where an even pace would be now.
struct UsageBar: View {
    let window: AccountsEntry.Window
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(self.window.color)
                    .frame(width: self.window.usedPercent > 0 ? max(self.height, width * min(1, self.window.usedPercent / 100)) : 0)
                if let elapsed = self.window.elapsed, elapsed > 0, elapsed < 1 {
                    Capsule().fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: self.height + 4)
                        .offset(x: width * elapsed - 1)
                }
            }
        }
        .frame(height: self.height + 4)
    }
}

struct AccountsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AccountsEntry

    var body: some View {
        Group {
            if self.entry.accounts.isEmpty {
                self.empty
            } else {
                switch self.family {
                case .systemSmall:
                    self.small(self.entry.accounts[0])
                case .accessoryRectangular:
                    self.rectangular(self.entry.accounts[0])
                case .accessoryCircular:
                    self.circular(self.entry.accounts[0])
                default:
                    self.medium
                }
            }
        }
        .widgetURL(URL(string: "tau://accounts"))
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Usage").font(.headline)
            Text(self.entry.note ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ account: AccountsEntry.Account) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(account.service).font(.headline)
            if let plan = account.plan {
                Text(plan).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func windowRow(_ window: AccountsEntry.Window, showsReset: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(window.percent).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(window.usedPercent >= 90 ? window.color : .primary)
            }
            UsageBar(window: window)
            if showsReset, let resetsAt = window.resetsAt, resetsAt > Date() {
                Text("Resets in \(resetsAt, style: .relative)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func small(_ account: AccountsEntry.Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            self.header(account)
            Text(account.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.top, -6)
            Spacer(minLength: 0)
            ForEach(Array(account.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                self.windowRow(window, showsReset: false)
            }
            if let soonest = account.windows.prefix(2).compactMap(\.resetsAt).filter({ $0 > Date() }).min() {
                Text("Resets in \(soonest, style: .relative)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(self.entry.accounts.prefix(2), id: \.id) { account in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        self.header(account)
                        Text(account.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        ForEach(Array(account.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                            self.windowRow(window, showsReset: false)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rectangular(_ account: AccountsEntry.Account) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.service).font(.headline).widgetAccentable()
            ForEach(Array(account.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                HStack(spacing: 4) {
                    Text(window.label).font(.caption2).frame(width: 30, alignment: .leading)
                    Gauge(value: min(1, window.usedPercent / 100)) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    Text(window.percent).font(.caption2).monospacedDigit()
                }
            }
        }
    }

    private func circular(_ account: AccountsEntry.Account) -> some View {
        let window = account.windows.max { $0.usedPercent < $1.usedPercent } ?? account.windows[0]
        return Gauge(value: min(1, window.usedPercent / 100)) {
            Text(window.label)
        } currentValueLabel: {
            Text("\(Int(min(100, window.usedPercent.rounded())))")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}

struct AccountsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "accounts", provider: AccountsProvider()) { entry in
            AccountsWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("How much of each plan's limits the accounts in use have used.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}
