import AppIntents
import SwiftUI
import WidgetKit

/// New Chat as a control (iOS 18): for the Action button (Settings, Action Button, Controls), Control Center and the
/// Lock Screen. It runs NewChatIntent, which opens the app at a new chat.
struct NewChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "newChat") {
            ControlWidgetButton(action: NewChatIntent()) {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Chat")
        .description("Opens a new chat in tau.")
    }
}
