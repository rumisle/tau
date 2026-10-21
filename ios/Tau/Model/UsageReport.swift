import Foundation

/// Tokens, dollars and answers over a span (server/src/search/usage.ts).
struct UsageTotals: Equatable {
    var cost = 0.0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var replies = 0

    var tokens: Int {
        return self.input + self.output + self.cacheRead + self.cacheWrite
    }

    static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        return UsageTotals(cost: lhs.cost + rhs.cost, input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite, replies: lhs.replies + rhs.replies)
    }

    init(cost: Double = 0.0, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, replies: Int = 0) {
        self.cost = cost
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.replies = replies
    }

    init(_ object: JSONObject) {
        self.init(cost: object.double("cost") ?? 0.0, input: object.int("input") ?? 0, output: object.int("output") ?? 0, cacheRead: object.int("cacheRead") ?? 0, cacheWrite: object.int("cacheWrite") ?? 0, replies: object.int("replies") ?? 0)
    }
}

/// What the models cost, by day, model and conversation, over the last days; one server's, or every server's merged.
struct UsageReport: Equatable {
    struct Day: Equatable {
        /// `2026-10-21`, in this phone's time zone.
        var day: String
        var models: [String: UsageTotals]

        var total: UsageTotals {
            return self.models.values.reduce(UsageTotals(), +)
        }
    }

    var days: [Day]
    /// By `provider/modelId`, the costliest first.
    var models: [(model: String, totals: UsageTotals)]
    /// The costliest conversations, by global ID.
    var conversations: [(conversationId: Int, totals: UsageTotals)]
    var total: UsageTotals
    var conversationCount: Int
    /// The span just before, for the change.
    var previous: UsageTotals

    static func == (lhs: UsageReport, rhs: UsageReport) -> Bool {
        return lhs.days == rhs.days && lhs.total == rhs.total && lhs.previous == rhs.previous && lhs.models.map(\.model) == rhs.models.map(\.model) && lhs.conversations.map(\.conversationId) == rhs.conversations.map(\.conversationId)
    }

    static let empty = UsageReport(days: [], models: [], conversations: [], total: UsageTotals(), conversationCount: 0, previous: UsageTotals())

    init(days: [Day], models: [(model: String, totals: UsageTotals)], conversations: [(conversationId: Int, totals: UsageTotals)], total: UsageTotals, conversationCount: Int, previous: UsageTotals) {
        self.days = days
        self.models = models
        self.conversations = conversations
        self.total = total
        self.conversationCount = conversationCount
        self.previous = previous
    }

    init(_ object: JSONObject, globalId: (Int) -> Int) {
        self.days = object.objects("days").map { day in
            var models: [String: UsageTotals] = [:]
            for (model, value) in day.object("models") ?? [:] {
                if let value = value as? JSONObject {
                    models[model] = UsageTotals(value)
                }
            }
            return Day(day: day.string("day") ?? "", models: models)
        }
        self.models = object.objects("models").map { ($0.string("model") ?? "", UsageTotals($0)) }
        self.conversations = object.objects("conversations").compactMap { row in row.int("conversationId").map { (globalId($0), UsageTotals(row)) } }
        let total = object.object("total") ?? [:]
        self.total = UsageTotals(total)
        self.conversationCount = total.int("conversations") ?? 0
        self.previous = UsageTotals(object.object("previous") ?? [:])
    }

    /// Several servers' reports as one: days by date, models and conversations summed and sorted again.
    static func merged(_ reports: [UsageReport]) -> UsageReport {
        guard reports.count > 1 else {
            return reports.first ?? .empty
        }
        var days: [String: [String: UsageTotals]] = [:]
        var order: [String] = []
        for report in reports {
            for day in report.days {
                if days[day.day] == nil {
                    order.append(day.day)
                    days[day.day] = [:]
                }
                var models = days[day.day] ?? [:]
                for (model, totals) in day.models {
                    models[model] = (models[model] ?? UsageTotals()) + totals
                }
                days[day.day] = models
            }
        }
        var models: [String: UsageTotals] = [:]
        for report in reports {
            for (model, totals) in report.models {
                models[model] = (models[model] ?? UsageTotals()) + totals
            }
        }
        return UsageReport(
            days: order.sorted().map { Day(day: $0, models: days[$0] ?? [:]) },
            models: models.map { ($0.key, $0.value) }.sorted { $0.totals.cost > $1.totals.cost || ($0.totals.cost == $1.totals.cost && $0.totals.tokens > $1.totals.tokens) },
            conversations: reports.flatMap(\.conversations).sorted { $0.totals.cost > $1.totals.cost }.prefix(20).map { $0 },
            total: reports.map(\.total).reduce(UsageTotals(), +),
            conversationCount: reports.map(\.conversationCount).reduce(0, +),
            previous: reports.map(\.previous).reduce(UsageTotals(), +)
        )
    }
}
