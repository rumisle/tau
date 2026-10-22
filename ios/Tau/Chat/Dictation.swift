import Foundation
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

/// The engine the composer uses: Aqua Voice when this build has its sign-in (ios/scripts/aqua_secrets.py), the
/// stand-in under `-mockDictation YES`, or with the mock store unless `-mockDictation NO`.
func makeDictationEngine() -> DictationEngine {
    let defaults = UserDefaults.standard
    let mock = defaults.object(forKey: "mockDictation") != nil ? defaults.bool(forKey: "mockDictation") : defaults.bool(forKey: "mock")
    if mock {
        return MockDictationEngine()
    }
    return AquaDictationEngine()
}
