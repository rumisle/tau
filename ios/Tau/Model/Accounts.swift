import Foundation

/// A server's logins to model providers, their logins in progress and their plan usage (docs/accounts.md): what
/// `accounts.subscribe` gives and each `accounts` event replaces.
struct AccountsState: Equatable {
    var accounts: [ProviderAccount] = []
    /// Providers with a key from the server's environment, not an account.
    var ambient: [AmbientLogin] = []
    var logins: [LoginSession] = []
    var providers: [ProviderEntry] = []

    /// Something to do: an account to sign in to again, or the one in use out of a limit. The tab's badge.
    var needsAttention: Bool {
        return self.accounts.contains { $0.problem != nil || ($0.active && ($0.usage?.windows.contains { $0.usedPercent >= 100 } ?? false)) }
    }

    init() {}

    init(json: JSONObject) {
        self.accounts = json.objects("accounts").map(ProviderAccount.init(json:))
        self.ambient = json.objects("ambient").map { AmbientLogin(provider: $0.string("provider") ?? "", providerName: $0.string("providerName") ?? "", source: $0.string("source") ?? "") }
        self.logins = json.objects("logins").map(LoginSession.init(json:))
        self.providers = json.objects("providers").map(ProviderEntry.init(json:))
    }

    func account(_ id: String) -> ProviderAccount? {
        return self.accounts.first { $0.id == id }
    }

    func login(_ id: String) -> LoginSession? {
        return self.logins.first { $0.id == id }
    }
}

struct ProviderAccount: Equatable {
    var id: String
    var provider: String
    var providerName: String
    /// "oauth" (a subscription's sign-in) or "api_key".
    var type: String
    var label: String?
    var email: String?
    var plan: String?
    var keyHint: String?
    var active: Bool
    var addedAt: Date
    /// Its sign-in no longer refreshes.
    var problem: String?
    var usage: PlanUsage?

    init(id: String, provider: String, providerName: String, type: String, label: String? = nil, email: String? = nil, plan: String? = nil, keyHint: String? = nil, active: Bool, addedAt: Date = Date(), problem: String? = nil, usage: PlanUsage? = nil) {
        self.id = id
        self.provider = provider
        self.providerName = providerName
        self.type = type
        self.label = label
        self.email = email
        self.plan = plan
        self.keyHint = keyHint
        self.active = active
        self.addedAt = addedAt
        self.problem = problem
        self.usage = usage
    }

    init(json: JSONObject) {
        self.id = json.string("id") ?? ""
        self.provider = json.string("provider") ?? ""
        self.providerName = json.string("providerName") ?? self.provider
        self.type = json.string("type") ?? "oauth"
        self.label = json.string("label")
        self.email = json.string("email")
        self.plan = json.string("plan")
        self.keyHint = json.string("keyHint")
        self.active = json.bool("active") ?? false
        self.addedAt = Date(timeIntervalSince1970: (json.double("addedAt") ?? 0) / 1000.0)
        self.problem = json.string("problem")
        self.usage = json.object("usage").map(PlanUsage.init(json:))
    }

    /// What the account is called: the user's name for it, else who it is, else its key or its kind.
    var title: String {
        if let label = self.label, !label.isEmpty {
            return label
        }
        if let email = self.email, !email.isEmpty {
            return email
        }
        if let hint = self.keyHint {
            return "Key ending \(hint)"
        }
        return self.type == "api_key" ? "API Key" : "Account"
    }

    /// The provider as people know it: Claude for Anthropic's subscription sign-in, ChatGPT for OpenAI's.
    var serviceName: String {
        return ProviderAccount.serviceName(provider: self.provider, providerName: self.providerName, subscription: self.type == "oauth")
    }

    static func serviceName(provider: String, providerName: String, subscription: Bool) -> String {
        switch (provider, subscription) {
        case ("anthropic", true):
            return "Claude"
        case ("openai-codex", _):
            return "ChatGPT"
        default:
            return providerName
        }
    }
}

struct PlanUsage: Equatable {
    var at: Date
    var windows: [UsageWindow]
    var credits: String?
    var error: String?

    init(at: Date, windows: [UsageWindow], credits: String? = nil, error: String? = nil) {
        self.at = at
        self.windows = windows
        self.credits = credits
        self.error = error
    }

    init(json: JSONObject) {
        self.at = Date(timeIntervalSince1970: (json.double("at") ?? 0) / 1000.0)
        self.windows = json.objects("windows").map(UsageWindow.init(json:))
        self.credits = json.string("credits")
        self.error = json.string("error")
    }
}

struct UsageWindow: Equatable {
    var id: String
    /// Short: "5h", "Week", "Opus".
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var seconds: Double?

    init(id: String, label: String, usedPercent: Double, resetsAt: Date? = nil, seconds: Double? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.seconds = seconds
    }

    init(json: JSONObject) {
        self.id = json.string("id") ?? ""
        self.label = json.string("label") ?? ""
        self.usedPercent = json.double("usedPercent") ?? 0.0
        self.resetsAt = json.double("resetsAt").map { Date(timeIntervalSince1970: $0 / 1000.0) }
        self.seconds = json.double("seconds")
    }

    /// How much of the window's time has gone, 0 to 1: where an even pace would be now. Nil when it is not known.
    func elapsed(now: Date = Date()) -> Double? {
        guard let resetsAt = self.resetsAt, let seconds = self.seconds, seconds > 0 else {
            return nil
        }
        return min(1.0, max(0.0, 1.0 - resetsAt.timeIntervalSince(now) / seconds))
    }

    /// Used faster than the time going: more than 15 points past an even pace, from a third of the window used (the
    /// usage monitor's "ahead" rule, with its floors).
    func isAhead(now: Date = Date()) -> Bool {
        guard let elapsed = self.elapsed(now: now) else {
            return false
        }
        let floor = (self.seconds ?? 0) > 86_400 ? 30.0 : 50.0
        return self.usedPercent >= floor && self.usedPercent > elapsed * 100.0 + 15.0
    }

    /// The window's level, as its bar's color says it.
    func level(now: Date = Date()) -> UsageLevel {
        if self.usedPercent >= 100 {
            return .out
        }
        if self.usedPercent >= 90 {
            return .high
        }
        return self.isAhead(now: now) ? .ahead : .normal
    }
}

enum UsageLevel {
    case normal
    case ahead
    case high
    case out
}

struct AmbientLogin: Equatable {
    var provider: String
    var providerName: String
    /// Where the key comes from: "ANTHROPIC_API_KEY", "~/.aws/credentials".
    var source: String
}

/// A provider an account can be added for.
struct ProviderEntry: Equatable {
    var id: String
    var name: String
    /// Its subscription sign-in, when it has one: "Anthropic (Claude Pro/Max)".
    var oauthName: String?
    var subscription: Bool
    /// Its API key, when it takes one: "Anthropic API key".
    var apiKeyName: String?

    init(id: String, name: String, oauthName: String? = nil, subscription: Bool = false, apiKeyName: String? = nil) {
        self.id = id
        self.name = name
        self.oauthName = oauthName
        self.subscription = subscription
        self.apiKeyName = apiKeyName
    }

    init(json: JSONObject) {
        self.id = json.string("id") ?? ""
        self.name = json.string("name") ?? self.id
        self.oauthName = json.object("oauth")?.string("name")
        self.subscription = json.object("oauth")?.bool("subscription") ?? false
        self.apiKeyName = json.object("apiKey")?.string("name")
    }
}

/// A login the server runs (pi's login flows), which the app shows and answers.
struct LoginSession: Equatable {
    enum Event: Equatable {
        case info(String, links: [URL])
        /// A page to sign in on; the flow then asks for what it shows, or for the address it ends on.
        case authURL(URL, instructions: String?)
        /// A code to enter on a page.
        case deviceCode(code: String, url: URL, expiresIn: Double?)
        case progress(String)
    }

    struct Option: Equatable {
        var id: String
        var label: String
        var detail: String?
    }

    struct Prompt: Equatable {
        enum Kind: Equatable {
            case text
            case secret
            /// A code or an address to paste back from the sign-in page.
            case manualCode
            case select([Option])
        }

        var id: String
        var kind: Kind
        var message: String
        var placeholder: String?
    }

    enum Done: Equatable {
        case account(String)
        case failed(String)
        case cancelled
    }

    var id: String
    var provider: String
    var providerName: String
    var type: String
    var events: [Event]
    var prompt: Prompt?
    var done: Done?

    init(id: String, provider: String, providerName: String, type: String, events: [Event] = [], prompt: Prompt? = nil, done: Done? = nil) {
        self.id = id
        self.provider = provider
        self.providerName = providerName
        self.type = type
        self.events = events
        self.prompt = prompt
        self.done = done
    }

    init(json: JSONObject) {
        self.id = json.string("id") ?? ""
        self.provider = json.string("provider") ?? ""
        self.providerName = json.string("providerName") ?? self.provider
        self.type = json.string("type") ?? "oauth"
        self.events = json.objects("events").compactMap { event -> Event? in
            switch event.string("type") {
            case "info":
                return .info(event.string("message") ?? "", links: event.objects("links").compactMap { $0.string("url").flatMap(URL.init(string:)) })
            case "auth_url":
                return event.string("url").flatMap(URL.init(string:)).map { .authURL($0, instructions: event.string("instructions")) }
            case "device_code":
                guard let code = event.string("userCode"), let url = event.string("verificationUri").flatMap(URL.init(string:)) else {
                    return nil
                }
                return .deviceCode(code: code, url: url, expiresIn: event.double("expiresInSeconds"))
            case "progress":
                return .progress(event.string("message") ?? "")
            default:
                return nil
            }
        }
        if let prompt = json.object("prompt"), let id = prompt.string("id") {
            let kind: Prompt.Kind
            switch prompt.string("type") {
            case "secret":
                kind = .secret
            case "manual_code":
                kind = .manualCode
            case "select":
                kind = .select(prompt.objects("options").map { Option(id: $0.string("id") ?? "", label: $0.string("label") ?? "", detail: $0.string("description")) })
            default:
                kind = .text
            }
            self.prompt = Prompt(id: id, kind: kind, message: prompt.string("message") ?? "", placeholder: prompt.string("placeholder"))
        }
        if let done = json.object("done") {
            if let account = done.string("accountId") {
                self.done = .account(account)
            } else if let error = done.string("error") {
                self.done = .failed(error)
            } else {
                self.done = .cancelled
            }
        }
    }

    /// The latest page and code to show: a device code wins over a page, as the flow shows the code on that page.
    var deviceCode: (code: String, url: URL)? {
        for event in self.events.reversed() {
            if case let .deviceCode(code, url, _) = event {
                return (code, url)
            }
        }
        return nil
    }

    var authURL: (url: URL, instructions: String?)? {
        for event in self.events.reversed() {
            if case let .authURL(url, instructions) = event {
                return (url, instructions)
            }
        }
        return nil
    }

    var progress: String? {
        for event in self.events.reversed() {
            if case let .progress(message) = event {
                return message
            }
        }
        return nil
    }
}
