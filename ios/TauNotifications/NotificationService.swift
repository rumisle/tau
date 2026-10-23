import UserNotifications
import Intents
import UIKit

/// Shows a server's push (server/src/notifier.ts) as its chat's message, as Telegram's NotificationService does: a
/// communication notification from the chat, with the chat's letter avatar where the app icon would be.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.original = request.content
        guard let tau = request.content.userInfo["tau"] as? [String: Any], let serverId = tau["server"] as? String, let local = tau["id"] as? Int else {
            contentHandler(request.content)
            return
        }
        let title = request.content.title
        let thread = "\(serverId):\(local)"
        // The chat list's colors go by the app's ID for the chat, which takes the server's slot.
        let slot = ShareGroup.snapshot?.servers.first(where: { $0.serverId == serverId })?.slot ?? 0
        let avatar = LetterAvatar.image(title: title, colorIndex: appId(slot: slot, local: local), diameter: 120.0)
        let image = avatar.pngData().map { INImage(imageData: $0) }
        let handle = INPersonHandle(value: thread, type: .unknown)
        let sender = INPerson(personHandle: handle, nameComponents: nil, displayName: title, image: image, contactIdentifier: nil, customIdentifier: thread)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: request.content.body, speakableGroupName: nil, conversationIdentifier: thread, serviceName: nil, sender: sender, attachments: nil)
        if let image {
            intent.setImage(image, forParameterNamed: \.sender)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { [weak self] _ in
            guard let self else {
                return
            }
            let updated = (try? request.content.updating(from: intent)) ?? request.content
            self.finish(updated)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let original = self.original {
            self.finish(original)
        }
    }

    private func finish(_ content: UNNotificationContent) {
        guard let handler = self.contentHandler else {
            return
        }
        self.contentHandler = nil
        handler(content)
    }

    /// MultiStore.global: a slot's chats are apart by 2^40.
    private func appId(slot: Int, local: Int) -> Int {
        return slot == 0 ? local : (slot << 40) | local
    }
}
