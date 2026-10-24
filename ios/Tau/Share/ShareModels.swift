import Foundation

import Security

/// The app's bundle ID (`TAU_BUNDLE_ID`, ios/Config/Tau.xcconfig), the same in its extensions: their keychain items
/// are named under it.
let tauBundleID = Bundle.main.object(forInfoDictionaryKey: "TauBundleID") as? String ?? "tau"

/// What the app and its share extension (TauShare) exchange, in a keychain group both are in: the app writes the servers
/// and chats for the share sheet to list; the extension sends itself, and leaves what it could not send for the app.
/// A keychain group rather than an App Group: a free developer account's profiles allow the team's keychain groups,
/// not App Groups.
enum ShareGroup {
    private static let service = tauBundleID + ".share"

    private static var accessGroup: String? {
        return Bundle.main.object(forInfoDictionaryKey: "TauKeychainGroup") as? String
    }

    private static func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.service, kSecAttrAccount as String: account]
        if let group = self.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    static func write(_ data: Data, account: String) {
        let query = self.query(account)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func read(account: String) -> Data? {
        var query = self.query(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    static func delete(account: String) {
        SecItemDelete(self.query(account) as CFDictionary)
    }

    /// The accounts of every unsent share.
    static func pendingAccounts() -> [String] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.service, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        if let group = self.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix("pending-") }
    }

    static var snapshot: ShareSnapshot? {
        get {
            return self.read(account: "snapshot").flatMap { try? JSONDecoder().decode(ShareSnapshot.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                self.write(data, account: "snapshot")
            }
        }
    }
}

/// The app's servers and chats, as the share sheet lists them.
struct ShareSnapshot: Codable {
    struct Server: Codable {
        var slot: Int
        var name: String
        var address: String
        var token: String?
        /// Its database's ID (`hello.serverId`), which its pushes name it by; nil until it said.
        var serverId: String?
    }

    struct Chat: Codable {
        /// The app's global ID.
        var id: Int
        var slot: Int
        /// Its ID on its server.
        var localId: Int
        var title: String
        /// Its server's name while there are several, else empty.
        var server: String
        var busy: Bool
        var date: Date?
        var pinned: Bool
    }

    /// A server a new chat can start on.
    struct NewChat: Codable {
        var slot: Int
        var title: String
    }

    var servers: [Server]
    /// Pinned first, then by activity, as the chat list.
    var chats: [Chat]
    /// Where a new chat can start: the servers, the one with the latest chat first.
    var newChats: [NewChat]
}

/// A share to deliver: to chats that exist (`chatIds`, global), and to a new chat in `newChat` when set.
struct PendingShare: Codable {
    var id: String
    var text: String
    /// JPEGs, made small enough to keep in the keychain.
    var images: [Data]
    var chatIds: [Int]
    var newChat: ShareSnapshot.NewChat?
    var date: Date
}
