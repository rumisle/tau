import AppIntents
import Foundation

/// New Chat, for the Action button, Control Center, the Lock Screen, Siri, Spotlight and Shortcuts: opens tau at a new
/// chat, as `tau://new` does (docs/links.md). In the app's target and the widgets' (whose control runs it): with
/// `openAppWhenRun` the system runs it in the app, which hands the link to `TauIntents.handler`.
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Opens a new chat in tau.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        TauIntents.open(URL(string: "tau://new")!)
        return .result()
    }
}

/// Where the app's intents send their links: the app delegate's `application(_:open:)` once it is set up at launch, and
/// until then (an intent that launched the app) kept and sent when it is.
@MainActor
enum TauIntents {
    private static var pending: [URL] = []

    static var handler: ((URL) -> Void)? {
        didSet {
            guard let handler else {
                return
            }
            let urls = pending
            pending = []
            urls.forEach(handler)
        }
    }

    static func open(_ url: URL) {
        if let handler {
            handler(url)
        } else {
            pending.append(url)
        }
    }
}
