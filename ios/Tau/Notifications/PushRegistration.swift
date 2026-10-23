import UIKit
import UserNotifications
import ActivityKit
import SwiftSignalKit

/// This phone's registration for Apple's pushes (docs/notifications.md): the permission, the device token, and the
/// token that lets a server start a Live Activity, which every server with the account's APNs key is given
/// (`devices.register`), with whether the user wants its answers.
final class PushRegistration {
    static let shared = PushRegistration()

    /// The category of a server's answer push: Reply, as Telegram's notifications have.
    static let chatCategory = "chat"
    static let replyAction = "reply"

    /// Posted when a token or a setting changed: each server is told again.
    static let changed = Notification.Name("tau.push.changed")

    /// One per install: a server keeps a registration per device, and a reinstall's replaces the old by its token.
    let deviceId: String
    /// The APNs environment the build was signed for: Xcode's builds go through the sandbox.
    let environment: String
    let topic: String
    private(set) var deviceToken: String?
    private(set) var pushToStartToken: String?
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "push.deviceId") {
            self.deviceId = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "push.deviceId")
            self.deviceId = id
        }
        self.environment = PushRegistration.signedEnvironment()
        self.topic = Bundle.main.bundleIdentifier ?? "com.rumisle.tau"
    }

    /// At launch: the categories, the permission (asked once), the device token, and the push-to-start token.
    func start() {
        let center = UNUserNotificationCenter.current()
        let reply = UNTextInputNotificationAction(identifier: PushRegistration.replyAction, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories([UNNotificationCategory(identifier: PushRegistration.chatCategory, actions: [reply], intentIdentifiers: ["INSendMessageIntent"], options: [])])
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.authorization = settings.authorizationStatus
                // Not under the UI tests (servers from the command line), whose taps the question would block.
                if settings.authorizationStatus == .notDetermined, !ServerConfigStorage.isOverridden {
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                        center.getNotificationSettings { settings in
                            DispatchQueue.main.async {
                                self.authorization = settings.authorizationStatus
                                self.post()
                            }
                        }
                    }
                }
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        if #available(iOS 17.2, *) {
            Task { @MainActor in
                for await data in Activity<TauActivityAttributes>.pushToStartTokenUpdates {
                    self.pushToStartToken = PushRegistration.hex(data)
                    self.post()
                }
            }
        }
    }

    /// Back in the foreground: the permission may have changed in Settings.
    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus != self.authorization {
                    self.authorization = settings.authorizationStatus
                    self.post()
                }
            }
        }
    }

    func didRegister(_ token: Data) {
        let hex = PushRegistration.hex(token)
        guard hex != self.deviceToken else {
            return
        }
        self.deviceToken = hex
        self.post()
    }

    /// Settings > Notifications: a server's answers as notifications, on unless turned off.
    static func alerts(serverId: String) -> Bool {
        return UserDefaults.standard.object(forKey: "push.alerts.\(serverId)") as? Bool ?? true
    }

    static func setAlerts(_ value: Bool, serverId: String) {
        UserDefaults.standard.set(value, forKey: "push.alerts.\(serverId)")
        NotificationCenter.default.post(name: PushRegistration.changed, object: nil)
    }

    /// `devices.register` for a server.
    func registration(serverId: String) -> JSONObject {
        let denied = self.authorization == .denied
        var params: JSONObject = [
            "deviceId": self.deviceId,
            "environment": self.environment,
            "topic": self.topic,
            "alerts": PushRegistration.alerts(serverId: serverId) && !denied,
        ]
        if let token = self.deviceToken {
            params["token"] = token
        }
        if let token = self.pushToStartToken {
            params["pushToStart"] = token
        }
        return params
    }

    /// The chat was opened: its notifications have been read, as Telegram clears a chat's.
    func clearDelivered(serverId: String, localId: Int) {
        let thread = "\(serverId):\(localId)"
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    private func post() {
        NotificationCenter.default.post(name: PushRegistration.changed, object: nil)
    }

    static func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// `aps-environment` of the provisioning profile the app was signed with. TestFlight's and the App Store's builds
    /// have no profile in them, and get production pushes; the simulator gets the sandbox's.
    private static func signedEnvironment() -> String {
        #if targetEnvironment(simulator)
        return "development"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let data = try? Data(contentsOf: url) else {
            return "production"
        }
        // The profile is a signed message around a property list.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.upperBound ..< text.endIndex) else {
            return "development"
        }
        let plist = Data(text[start.lowerBound ..< end.upperBound].utf8)
        let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        let entitlements = object?["Entitlements"] as? [String: Any]
        return entitlements?["aps-environment"] as? String ?? "development"
        #endif
    }
}
