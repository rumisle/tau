import Foundation
import SwiftSignalKit

/// What dictation hears, as it goes: the words so far of what is being said, which may still change, then what was
/// said, fixed, after which a new stretch begins.
enum DictationEvent: Equatable {
    case partial(String)
    case final(String)
}

/// Speech to text for the composer. The session runs while subscribed; `stop` ends it after a last `final`.
protocol DictationEngine: AnyObject {
    func start() -> Signal<DictationEvent, NoError>
    func stop()
}

/// A stand-in until a real engine (SpeechAnalyzer on the phone, or a transcription model on the server): it "hears" a
/// sentence a word at a time, as partial results, and fixes it every few words.
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
