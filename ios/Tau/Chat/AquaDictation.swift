import Foundation
import AVFoundation
import SwiftSignalKit

/// Dictation through Aqua Voice's realtime API (unofficial, with the
/// sign-in of the user's own Aqua app, which ios/scripts/aqua_secrets.py writes into the build).
///
/// One session is one WebSocket to wss://realtime.aquavoice.com: a `start` message, then, once the server says
/// `ready`, the microphone as 16 kHz mono 16-bit PCM in 100 ms frames, each behind an 8-byte header. The server answers
/// with `document_update`s, each the whole text so far. Stopping turns the microphone off at once, sends a second of
/// silence (so the last word is finished, as Aqua's SDK does) and `stop_request`, and waits for the update marked final.
/// The audio captured before `ready` is kept and sent then, so the first words are not lost to the connection.
final class AquaDictationEngine: DictationEngine {
    struct Config {
        var token: String
        var language: String
        var model: String
        var dictionary: [String]
        var replacements: [[String: String]]

        /// What the build carries, from the Mac's Aqua app; the language and model as Settings > Dictation sets them.
        static func load() -> Config? {
            guard let plist = Config.bundled(), let token = plist["token"] as? String, !token.isEmpty else {
                return nil
            }
            return Config(
                token: token,
                language: DictationSettings.language,
                model: DictationSettings.model,
                dictionary: plist["dictionary"] as? [String] ?? [],
                replacements: plist["replacements"] as? [[String: String]] ?? []
            )
        }

        static func bundled() -> [String: Any]? {
            guard let url = Bundle.main.url(forResource: "Aqua", withExtension: "plist"), let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }

        /// When the build's sign-in expires, read from the token (a JWT's `exp`).
        static func signInExpiry() -> Date? {
            guard let token = Config.bundled()?["token"] as? String else {
                return nil
            }
            let parts = token.split(separator: ".")
            guard parts.count == 3 else {
                return nil
            }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let exp = claims["exp"] as? Double else {
                return nil
            }
            return Date(timeIntervalSince1970: exp)
        }
    }

    private var session: AquaSession?

    func start() -> Signal<DictationEvent, NoError> {
        return Signal { [weak self] subscriber in
            guard let config = Config.load() else {
                subscriber.putNext(.failed("This build has no Aqua Voice sign-in. Sign in to Aqua Voice on the Mac and build again."))
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let session = AquaSession(config: config, emit: { event in
                subscriber.putNext(event)
            }, completed: {
                subscriber.putCompletion()
            })
            self?.session = session
            session.begin()
            return ActionDisposable { [weak self] in
                session.cancel()
                if self?.session === session {
                    self?.session = nil
                }
            }
        }
    }

    func stop() {
        self.session?.finish()
    }
}

/// One dictation. Its state lives on `queue`; events go out from there, and the composer delivers them on the main
/// queue.
private final class AquaSession: NSObject, URLSessionWebSocketDelegate {
    private enum Phase {
        case connecting
        case streaming
        /// The microphone is off; the rest of the audio and the stop request are going out.
        case stopping
        case done
    }

    private static let url = "wss://realtime.aquavoice.com"
    private static let sampleRate: Double = 16_000
    /// 100 ms of 16-bit mono at 16 kHz, the frame Aqua's own client sends.
    private static let chunkBytes = 3_200
    /// After the stop request, how long to wait for the final text before keeping the last one heard.
    private static let finalTimeout: Double = 8.0
    /// How long the connection may take before dictation gives up.
    private static let connectTimeout: Double = 10.0

    private let config: AquaDictationEngine.Config
    private let emit: (DictationEvent) -> Void
    private let completed: () -> Void
    private let queue = DispatchQueue(label: "tau.dictation.aqua")
    private var phase: Phase = .connecting
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private let audio = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    /// Audio not sent yet: before `ready`, all of it; after, what is short of a whole frame.
    private var pending = Data()
    private var chunks = 0
    private var lastText = ""
    private var stopRequestSent = false
    private var finalTimer: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(config: AquaDictationEngine.Config, emit: @escaping (DictationEvent) -> Void, completed: @escaping () -> Void) {
        self.config = config
        self.emit = emit
        self.completed = completed
        super.init()
    }

    func begin() {
        // -dictationFile <16 kHz mono 16-bit WAV>: the file instead of the microphone, at the pace of speech, to try the
        // connection where there is no microphone to speak into (the simulator).
        if let path = UserDefaults.standard.string(forKey: "dictationFile"), let file = FileManager.default.contents(atPath: path), file.count > 44 {
            self.queue.async {
                self.connect()
                self.play(file.subdata(in: 44 ..< file.count), from: 0)
            }
            return
        }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else {
                return
            }
            self.queue.async {
                guard self.phase == .connecting else {
                    return
                }
                guard granted else {
                    self.fail("tau has no access to the microphone. Allow it in Settings > Apps > tau.")
                    return
                }
                do {
                    try self.startAudio()
                } catch {
                    self.fail("The microphone could not start: \(error.localizedDescription)")
                    return
                }
                self.connect()
            }
        }
    }

    /// Stop listening and finish the text.
    func finish() {
        self.queue.async {
            switch self.phase {
            case .connecting, .streaming:
                let wasStreaming = self.phase == .streaming
                self.phase = .stopping
                self.stopAudio()
                // Before `ready`, the rest goes out once it comes.
                if wasStreaming {
                    self.sendTail()
                }
            case .stopping, .done:
                break
            }
        }
    }

    /// Dropped: nothing more is wanted.
    func cancel() {
        self.queue.async {
            self.close()
        }
    }

    // MARK: - Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        let input = self.audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "tau.dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone"])
        }
        self.converter = AVAudioConverter(from: format, to: self.outputFormat)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.captured(buffer)
        }
        self.audio.prepare()
        try self.audio.start()
        let center = NotificationCenter.default
        // A call or another app taking the microphone ends dictation, with what was heard.
        self.observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] _ in
            self?.finish()
        })
    }

    private func stopAudio() {
        guard self.audio.isRunning || self.converter != nil else {
            return
        }
        self.audio.inputNode.removeTap(onBus: 0)
        self.audio.stop()
        self.converter = nil
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play(_ pcm: Data, from offset: Int) {
        guard self.phase == .connecting || self.phase == .streaming else {
            return
        }
        guard offset < pcm.count else {
            self.finish()
            return
        }
        let end = min(pcm.count, offset + AquaSession.chunkBytes)
        self.pending.append(pcm.subdata(in: offset ..< end))
        self.emit(.level(Float.random(in: 0.3 ... 0.8)))
        if self.phase == .streaming {
            self.sendWholeChunks()
        }
        self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.play(pcm, from: end)
        }
    }

    /// On the audio thread: the level for the button, the samples converted and queued.
    private func captured(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0.0
            for index in 0 ..< Int(buffer.frameLength) {
                sum += channel[index] * channel[index]
            }
            let rms = sqrt(sum / Float(buffer.frameLength))
            // -50 dB to -10 dB as 0 to 1, roughly what speech spans at the phone's microphone.
            let decibels = 20.0 * log10(max(rms, 1e-6))
            let level = min(1.0, max(0.0, (decibels + 50.0) / 40.0))
            self.emit(.level(level))
        }
        guard let converter = self.converter else {
            return
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * AquaSession.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: capacity) else {
            return
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else {
            return
        }
        let data = Data(bytes: samples, count: Int(output.frameLength) * 2)
        self.queue.async {
            guard self.phase == .connecting || self.phase == .streaming else {
                return
            }
            self.pending.append(data)
            if self.phase == .streaming {
                self.sendWholeChunks()
            }
        }
    }

    // MARK: - Connection

    private func connect() {
        guard var components = URLComponents(string: AquaSession.url) else {
            return
        }
        components.queryItems = [URLQueryItem(name: "token", value: self.config.token)]
        guard let url = components.url else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("AquaVoiceSDK/0.14.3 (tau)", forHTTPHeaderField: "User-Agent")
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = self.queue
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: operationQueue)
        self.urlSession = session
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        self.task = task
        task.resume()
        self.send(json: self.startMessage())
        self.receive()
        self.queue.asyncAfter(deadline: .now() + AquaSession.connectTimeout) { [weak self] in
            guard let self, self.phase == .connecting || (self.phase == .stopping && !self.stopRequestSent && self.chunks == 0) else {
                return
            }
            self.fail("Aqua Voice did not answer.")
        }
    }

    /// The `start` message as Aqua's macOS client builds it, with this user's dictionary and language.
    private func startMessage() -> [String: Any] {
        return [
            "type": "start",
            "client_session_uuid": UUID().uuidString.lowercased(),
            "language_code": self.config.language,
            "sample_rate": Int(AquaSession.sampleRate),
            "channel_count": 1,
            "microphone": "default",
            "audio_format": "pcm_s16le",
            "streaming": true,
            "transcription_model": self.config.model,
            "is_trial": false,
            "initial_text": "",
            "cloud_sync": false,
            "privacy_mode": false,
            "casual_messaging": false,
            "context": [
                "custom_words": self.config.dictionary,
                "replacements": self.config.replacements,
                "app": "terminal",
            ] as [String: Any],
            "metadata": [
                "client": "macOS",
                "version": "0.14.3",
                "location": "localhost",
            ],
        ]
    }

    private func receive() {
        self.task?.receive { [weak self] result in
            guard let self else {
                return
            }
            // On `queue`: the session's delegate queue.
            switch result {
            case let .success(message):
                if case let .string(text) = message, let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(object)
                }
                if self.phase != .done {
                    self.receive()
                }
            case let .failure(error):
                self.connectionEnded(error.localizedDescription)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            guard self.phase == .connecting || self.phase == .stopping else {
                return
            }
            if self.phase == .connecting {
                self.phase = .streaming
                self.sendWholeChunks()
            } else {
                // Stopped while connecting: what was captured goes out now, then the end.
                self.sendTail()
            }
        case "document_update":
            let text = (message["wet_text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (message["dry_text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (message["raw_text"] as? String) ?? ""
            let isFinal = (message["final"] as? Bool ?? false) || (message["is_final"] as? Bool ?? false)
            let cleaned = AquaSession.clean(text)
            if isFinal {
                // The final text only counts once the end was asked for; earlier ones end a stretch the server cut.
                self.lastText = cleaned
                if self.stopRequestSent {
                    self.emit(.final(cleaned))
                    self.close()
                } else if !cleaned.isEmpty {
                    self.emit(.partial(cleaned))
                }
            } else if !cleaned.isEmpty, cleaned != self.lastText {
                self.lastText = cleaned
                self.emit(.partial(cleaned))
            }
        case "error":
            if message["is_fatal"] as? Bool ?? false {
                let details = [message["message"] as? String, message["details"] as? String].compactMap { $0 }.joined(separator: ": ")
                self.connectionEnded(details.isEmpty ? "Aqua Voice failed." : details)
            }
        default:
            break
        }
    }

    /// The connection ended early: what was heard stays; with nothing heard, the user learns why.
    private func connectionEnded(_ reason: String) {
        guard self.phase != .done else {
            return
        }
        if self.lastText.isEmpty {
            self.fail("Dictation failed: \(reason)")
        } else {
            self.emit(.final(self.lastText))
            self.close()
        }
    }

    private func sendWholeChunks() {
        while self.pending.count >= AquaSession.chunkBytes {
            let chunk = self.pending.prefix(AquaSession.chunkBytes)
            self.pending.removeFirst(AquaSession.chunkBytes)
            self.sendAudio(Data(chunk))
        }
    }

    /// The rest of the audio, a second of silence at the pace of speech, then the stop request.
    private func sendTail() {
        self.sendWholeChunks()
        if !self.pending.isEmpty {
            let rest = self.pending
            self.pending = Data()
            self.sendAudio(rest)
        }
        var silence = 10
        func next() {
            guard self.phase == .stopping else {
                return
            }
            if silence > 0 {
                silence -= 1
                self.sendAudio(Data(count: AquaSession.chunkBytes))
                self.queue.asyncAfter(deadline: .now() + 0.1, execute: next)
                return
            }
            self.send(json: ["type": "stop_request", "total_audio_chunks": self.chunks])
            self.stopRequestSent = true
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .stopping else {
                    return
                }
                self.emit(.final(self.lastText))
                self.close()
            }
            self.finalTimer = timeout
            self.queue.asyncAfter(deadline: .now() + AquaSession.finalTimeout, execute: timeout)
        }
        next()
    }

    private func sendAudio(_ payload: Data) {
        var header = Data(count: 8)
        let chunk = UInt16(truncatingIfNeeded: self.chunks)
        let kilobytes = UInt16(truncatingIfNeeded: (payload.count + 1023) / 1024)
        header[0] = 1
        header[1] = 0
        header[2] = UInt8(chunk >> 8)
        header[3] = UInt8(chunk & 0xff)
        header[4] = 0
        header[5] = 0
        header[6] = UInt8(kilobytes >> 8)
        header[7] = UInt8(kilobytes & 0xff)
        self.chunks += 1
        self.task?.send(.data(header + payload)) { [weak self] error in
            if let error {
                self?.queue.async {
                    self?.connectionEnded(error.localizedDescription)
                }
            }
        }
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) else {
            return
        }
        self.task?.send(.string(text)) { _ in }
    }

    private func fail(_ message: String) {
        guard self.phase != .done else {
            return
        }
        self.emit(.failed(message))
        self.close()
    }

    private func close() {
        guard self.phase != .done else {
            return
        }
        self.phase = .done
        self.finalTimer?.cancel()
        self.stopAudio()
        self.task?.cancel(with: .normalClosure, reason: nil)
        self.task = nil
        self.urlSession?.invalidateAndCancel()
        self.urlSession = nil
        self.completed()
    }

    /// Aqua writes Chinese with a space between words; Chinese has none. Spaces between Latin text and Chinese stay.
    static func clean(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == " ", index > 0, index + 1 < scalars.count, isCJK(scalars[index - 1]), isCJK(scalars[index + 1]) {
                continue
            }
            output.append(scalar)
        }
        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000 ... 0x303F, 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0xFF00 ... 0xFFEF, 0x20000 ... 0x2FFFF:
            return true
        default:
            return false
        }
    }
}

/// The language and model dictation asks Aqua for: Settings > Dictation's, else what the Mac's Aqua app was set to when
/// the app was built, else Aqua's defaults.
enum DictationSettings {
    struct Option {
        let id: String
        let title: String
        var subtitle: String?
    }

    /// Aqua's language codes (its app's list), the ones likely here; Auto lets the model tell.
    static let languages: [Option] = [
        Option(id: "auto", title: "Auto-Detect"),
        Option(id: "en", title: "English"),
        Option(id: "cmn", title: "Chinese, Simplified", subtitle: "中文（简体）"),
        Option(id: "ja", title: "Japanese", subtitle: "日本語"),
        Option(id: "ko", title: "Korean", subtitle: "한국어"),
        Option(id: "de", title: "German", subtitle: "Deutsch"),
        Option(id: "fr", title: "French", subtitle: "Français"),
        Option(id: "es", title: "Spanish", subtitle: "Español"),
        Option(id: "ru", title: "Russian", subtitle: "Русский"),
    ]

    /// Aqua's cloud models (TranscriptionModelEnum, APIModelSlug), with what docs/aqua-voice-model-analysis.md found.
    static let models: [Option] = [
        Option(id: "avalon-v1.1", title: "Avalon 1.1", subtitle: "Aqua's default; the fastest, English first"),
        Option(id: "avalon-v1.5", title: "Avalon 1.5", subtitle: "Slower; better with Chinese"),
        Option(id: "whisper", title: "Whisper", subtitle: "Many languages"),
    ]

    private static let languageKey = "dictation.language"
    private static let modelKey = "dictation.model"

    static var language: String {
        get {
            return UserDefaults.standard.string(forKey: languageKey) ?? (AquaDictationEngine.Config.bundled()?["language"] as? String) ?? "auto"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: languageKey)
        }
    }

    static var model: String {
        get {
            return UserDefaults.standard.string(forKey: modelKey) ?? (AquaDictationEngine.Config.bundled()?["model"] as? String) ?? "avalon-v1.1"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: modelKey)
        }
    }

    static func title(language: String) -> String {
        return languages.first(where: { $0.id == language })?.title ?? language
    }

    static func title(model: String) -> String {
        return models.first(where: { $0.id == model })?.title ?? model
    }
}
