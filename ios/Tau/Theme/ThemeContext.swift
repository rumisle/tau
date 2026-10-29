import UIKit
import Display
import SwiftSignalKit

/// The app's current theme, as Telegram picks it: the theme chosen in Settings > Appearance (Classic by default), and
/// when Auto-Night follows the system, a night theme (Night by default, as Telegram's `AutomaticThemeSwitchSetting`)
/// while the phone is in dark mode.
/// Screens subscribe to `theme` and restyle in place, as Telegram's controllers follow `presentationData`.
final class ThemeContext {
    struct Settings: Equatable {
        var theme: TauTheme.Builtin
        var autoNight: Bool
        var nightTheme: TauTheme.Builtin
        /// Long lines in code blocks wrap; otherwise a block scrolls sideways.
        var wrapCode: Bool
        /// The accent the user picked, the app's in every theme (nil: tau's). Not one per theme, as Telegram's
        /// `themeSpecificAccentColors`: with Auto-Night the theme follows the phone, and a theme never picked for had
        /// tau's pink, so the app (and the Live Activity it colors) turned pink whenever the phone went dark, or iOS
        /// drew tau's snapshot in the other appearance, and back when it went light.
        var accent: TauTheme.Accent?
        /// Where a chat's server shows in the chat list, while there are several.
        var serverTags: ServerTags = .underMessage

        enum ServerTags: String {
            /// A tag in its server's color before the time.
            case besideTime
            /// Telegram's folder tags: a line of its own under one of the message.
            case underMessage
        }

        static let `default` = Settings(theme: .classic, autoNight: true, nightTheme: .night, wrapCode: true, accent: nil)

        /// The picked accent, or for a theme without it (black is Day's, white Night's, gray not Night's) its nearest.
        func accent(for builtin: TauTheme.Builtin) -> TauTheme.Accent {
            let accent = self.accent ?? .standard
            let available = TauTheme.Accent.available(for: builtin)
            if available.contains(accent) {
                return accent
            }
            for nearest: TauTheme.Accent in [.white, .black, .gray] where available.contains(nearest) {
                return nearest
            }
            return .standard
        }
    }

    /// Before version 2 the default night theme was Tinted Night; Telegram's is Night.
    private static let settingsVersion = 2

    private static let settingsKey = "appearance.settings"

    private let themePromise: ValuePromise<ThemeBox>
    private let settingsPromise: ValuePromise<Settings>
    private var systemStyle: WindowUserInterfaceStyle = .light
    private var systemStyleDisposable: Disposable?

    private(set) var settings: Settings
    private(set) var current: TauTheme

    init() {
        var settings = Settings.default
        if let stored = UserDefaults.standard.dictionary(forKey: ThemeContext.settingsKey) {
            if let value = (stored["theme"] as? String).flatMap(TauTheme.Builtin.init(rawValue:)) {
                settings.theme = value
            }
            if let value = stored["autoNight"] as? Bool {
                settings.autoNight = value
            }
            if let value = (stored["nightTheme"] as? String).flatMap(TauTheme.Builtin.init(rawValue:)), value.isDark, (stored["version"] as? Int ?? 1) >= ThemeContext.settingsVersion || value != .tintedNight {
                settings.nightTheme = value
            }
            if let value = stored["wrapCode"] as? Bool {
                settings.wrapCode = value
            }
            if let value = (stored["serverTags"] as? String).flatMap(Settings.ServerTags.init(rawValue:)) {
                settings.serverTags = value
            }
            if let value = (stored["accent"] as? String).flatMap(TauTheme.Accent.init(rawValue:)) {
                settings.accent = value
            } else {
                // Before, one per theme: the one picked, not tau's that a theme without one had.
                var accents: [TauTheme.Builtin: TauTheme.Accent] = [:]
                for (key, value) in stored["accents"] as? [String: String] ?? [:] {
                    if let builtin = TauTheme.Builtin(rawValue: key), let accent = TauTheme.Accent(rawValue: value) {
                        accents[builtin] = accent
                    }
                }
                let picked = [accents[settings.theme], accents[settings.nightTheme]] + TauTheme.Builtin.allCases.map { accents[$0] }
                settings.accent = picked.compactMap { $0 }.first { $0 != .standard } ?? picked.compactMap { $0 }.first
            }
        }
        self.settings = settings
        // The phone's appearance now, not light until the window says: a dark phone's first frame is its night theme.
        let system: WindowUserInterfaceStyle = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        self.systemStyle = system
        let current = ThemeContext.resolve(settings, system: system)
        self.current = current
        self.themePromise = ValuePromise(ThemeBox(current), ignoreRepeated: true)
        self.settingsPromise = ValuePromise(settings, ignoreRepeated: true)
    }

    deinit {
        self.systemStyleDisposable?.dispose()
        if let textSizeObserver = self.textSizeObserver {
            NotificationCenter.default.removeObserver(textSizeObserver)
        }
    }

    private var textSizeObserver: NSObjectProtocol?

    /// Follow iOS's text size (Settings > Display & Brightness > Text Size), as Telegram does by default
    /// (`useSystemFont`): a theme of the new size, which every screen lays out again with.
    func observeTextSize() {
        self.textSizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }

    var theme: Signal<TauTheme, NoError> {
        return self.themePromise.get() |> map { $0.theme }
    }

    var settingsSignal: Signal<Settings, NoError> {
        return self.settingsPromise.get()
    }

    /// Follow the window's light/dark appearance.
    func observeSystemStyle(_ style: Signal<WindowUserInterfaceStyle, NoError>) {
        // -systemStyle dark|light: the phone's, for the UI tests (the simulator's dark mode does not reach the app).
        if let value = UserDefaults.standard.string(forKey: "systemStyle") {
            self.systemStyle = value == "dark" ? .dark : .light
            self.apply()
            return
        }
        self.systemStyleDisposable = (style |> deliverOnMainQueue).start(next: { [weak self] style in
            guard let self else {
                return
            }
            self.systemStyle = style
            self.apply()
        })
    }

    func update(_ f: (inout Settings) -> Void) {
        var settings = self.settings
        f(&settings)
        self.settings = settings
        var stored: [String: Any] = ["version": ThemeContext.settingsVersion, "theme": settings.theme.rawValue, "autoNight": settings.autoNight, "nightTheme": settings.nightTheme.rawValue, "wrapCode": settings.wrapCode, "serverTags": settings.serverTags.rawValue]
        if let accent = settings.accent {
            stored["accent"] = accent.rawValue
        }
        UserDefaults.standard.set(stored, forKey: ThemeContext.settingsKey)
        self.settingsPromise.set(settings)
        self.apply()
    }

    /// Debug override from the `-theme` launch argument.
    func force(_ builtin: TauTheme.Builtin) {
        self.update { settings in
            settings.theme = builtin
            settings.autoNight = false
        }
    }

    private func apply() {
        let theme = ThemeContext.resolve(self.settings, system: self.systemStyle)
        if theme !== self.current {
            self.current = theme
            self.themePromise.set(ThemeBox(theme))
        }
    }

    private static func resolve(_ settings: Settings, system: WindowUserInterfaceStyle) -> TauTheme {
        let fontSize = TauTheme.systemFontSize()
        if settings.autoNight, system == .dark, !settings.theme.isDark {
            return .builtin(settings.nightTheme, accent: settings.accent(for: settings.nightTheme), fontSize: fontSize)
        }
        return .builtin(settings.theme, accent: settings.accent(for: settings.theme), fontSize: fontSize)
    }
}

private struct ThemeBox: Equatable {
    let theme: TauTheme

    init(_ theme: TauTheme) {
        self.theme = theme
    }

    static func == (lhs: ThemeBox, rhs: ThemeBox) -> Bool {
        return lhs.theme === rhs.theme
    }
}

/// What every screen needs: the data store and the theme.
final class AppContext {
    private(set) var store: TauStore
    /// What Telegram's copied components take as their account context (TelegramAccountContext.swift).
    let telegram: TauAccountContext
    let telegramShared: TauSharedAccountContext
    /// Rebuilds the screens on a new store, after the server address changed.
    var replaceStore: ((TauStore) -> Void)?
    let themeContext: ThemeContext

    func setStore(_ store: TauStore) {
        self.store = store
        self.replaceStore?(store)
    }

    init(store: TauStore, themeContext: ThemeContext) {
        let shared = TauSharedAccountContext(presentationData: themeContext.current.presentationData)
        self.telegramShared = shared
        self.telegram = TauAccountContext(shared: shared)
        initializeLegacyComponents(context: self.telegram, strings: themeContext.current.presentationStrings)
        self.store = store
        self.themeContext = themeContext
    }

    var theme: TauTheme {
        return self.themeContext.current
    }
}
