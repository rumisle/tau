import Foundation
import Security
import SwiftSignalKit

/// What dictation hears, as it goes: the words so far of what is being said, which may still change, then what was
/// said, fixed, after which a new stretch begins. And how loud the microphone is, for the listening button's blob, and
/// why it could not listen.
enum DictationEvent: Equatable {
    case partial(String)
    case final(String)
    /// The microphone's level, 0 to 1.
    case level(Float)
    /// Dictation could not start or went wrong: what to tell the user. The session completes after it.
    case failed(String)
}

/// Speech to text for the composer. A session runs while subscribed: `stop` asks it to end, after which the engine
/// sends what is left of the speech, a last `final`, and completes; disposing of it drops whatever is still to come.
protocol DictationEngine: AnyObject {
    func start() -> Signal<DictationEvent, NoError>
    func stop()
}

/// A stand-in for tests and the mock store: it "hears" a sentence a word at a time, as partial results, and fixes it
/// every few words.
final class MockDictationEngine: DictationEngine {
    private static let sentences = [
        "Let's also check that the build still passes on the device",
        "and when that is done write a short note about what changed",
    ]
    private var stopRequested: (() -> Void)?

    func start() -> Signal<DictationEvent, NoError> {
        return Signal { [weak self] subscriber in
            let words = MockDictationEngine.sentences.joined(separator: " ").split(separator: " ").map(String.init)
            var index = 0
            var heard: [String] = []
            var timer: SwiftSignalKit.Timer?
            let finish = {
                timer?.invalidate()
                if !heard.isEmpty {
                    subscriber.putNext(.final(heard.joined(separator: " ")))
                    heard = []
                }
                subscriber.putCompletion()
            }
            self?.stopRequested = finish
            timer = SwiftSignalKit.Timer(timeout: 0.28, repeat: true, completion: {
                guard index < words.count else {
                    finish()
                    return
                }
                heard.append(words[index])
                index += 1
                subscriber.putNext(.level(Float.random(in: 0.2 ... 0.9)))
                // A stretch is fixed at a pause: every six words here.
                if heard.count >= 6 {
                    subscriber.putNext(.final(heard.joined(separator: " ")))
                    heard = []
                } else {
                    subscriber.putNext(.partial(heard.joined(separator: " ")))
                }
            }, queue: Queue.mainQueue())
            timer?.start()
            return ActionDisposable {
                timer?.invalidate()
            }
        }
    }

    func stop() {
        self.stopRequested?()
        self.stopRequested = nil
    }
}

/// Who turns speech into text. Dictation is off until the user picks one in Settings > Dictation and gives it what it
/// needs; more can come, each an engine of its own.
enum DictationProvider: String, CaseIterable {
    case aqua

    var title: String {
        switch self {
        case .aqua:
            return "Aqua Voice"
        }
    }

    /// Whether it has what it needs to listen.
    var isReady: Bool {
        switch self {
        case .aqua:
            return AquaSessionKey.current != nil
        }
    }

    func makeEngine() -> DictationEngine {
        switch self {
        case .aqua:
            return AquaDictationEngine()
        }
    }
}

/// Settings > Dictation, on the phone.
enum DictationSettings {
    /// Posted when the provider or its settings change: the composer shows its microphone or not.
    static let changed = Notification.Name("tau.dictation.changed")
    private static let providerKey = "dictation.provider"

    /// Nil: dictation is off, and the composer has no microphone.
    static var provider: DictationProvider? {
        get {
            return UserDefaults.standard.string(forKey: providerKey).flatMap(DictationProvider.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: providerKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The stand-in engine, for tests: under `-mockDictation YES`, or with the mock store unless `-mockDictation NO`.
    static var usesMock: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "mockDictation") != nil ? defaults.bool(forKey: "mockDictation") : defaults.bool(forKey: "mock")
    }

    /// Whether the composer shows its microphone.
    static var isEnabled: Bool {
        return self.usesMock || self.provider != nil
    }
}

/// The engine the composer uses: the provider's, or the stand-in for tests. Nil while dictation is off.
func makeDictationEngine() -> DictationEngine? {
    if DictationSettings.usesMock {
        return MockDictationEngine()
    }
    return DictationSettings.provider?.makeEngine()
}

/// A secret of dictation's, in the keychain (this device only).
enum DictationKeychain {
    private static let service = tauBundleID + ".dictation"

    private static func query(_ account: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var query = self.query(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, account: String) {
        let query = self.query(account)
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }
}
