import AppIntents

/// tau's App Shortcuts: listed under the app in Shortcuts, in Spotlight, for Siri, and for the Action button
/// (Settings, Action Button, Shortcut).
struct TauShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewChatIntent(),
            phrases: ["New \(.applicationName) chat", "New chat in \(.applicationName)", "Start a \(.applicationName) chat"],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
    }
}
