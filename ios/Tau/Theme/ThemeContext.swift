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
        /// Each theme's accent, as Telegram's `themeSpecificAccentColors`; a theme without one has tau's.
        var accents: [TauTheme.Builtin: TauTheme.Accent]

        static let `default` = Settings(theme: .classic, autoNight: true, nightTheme: .night, wrapCode: true, accents: [:])

        func accent(for builtin: TauTheme.Builtin) -> TauTheme.Accent {
            let accent = self.accents[builtin] ?? .standard
            return TauTheme.Accent.available(for: builtin).contains(accent) ? accent : .standard
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
            for (key, value) in stored["accents"] as? [String: String] ?? [:] {
                if let builtin = TauTheme.Builtin(rawValue: key), let accent = TauTheme.Accent(rawValue: value) {
                    settings.accents[builtin] = accent
                }
            }
        }
        self.settings = settings
        let current = ThemeContext.resolve(settings, system: .light)
        self.current = current
        self.themePromise = ValuePromise(ThemeBox(current), ignoreRepeated: true)
        self.settingsPromise = ValuePromise(settings, ignoreRepeated: true)
    }

    deinit {
        self.systemStyleDisposable?.dispose()
    }

    var theme: Signal<TauTheme, NoError> {
        return self.themePromise.get() |> map { $0.theme }
    }

    var settingsSignal: Signal<Settings, NoError> {
        return self.settingsPromise.get()
    }

    /// Follow the window's light/dark appearance.
    func observeSystemStyle(_ style: Signal<WindowUserInterfaceStyle, NoError>) {
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
        let accents = Dictionary(uniqueKeysWithValues: settings.accents.map { ($0.key.rawValue, $0.value.rawValue) })
        UserDefaults.standard.set(["version": ThemeContext.settingsVersion, "theme": settings.theme.rawValue, "autoNight": settings.autoNight, "nightTheme": settings.nightTheme.rawValue, "wrapCode": settings.wrapCode, "accents": accents], forKey: ThemeContext.settingsKey)
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
        if settings.autoNight, system == .dark, !settings.theme.isDark {
            return .builtin(settings.nightTheme, accent: settings.accent(for: settings.nightTheme))
        }
        return .builtin(settings.theme, accent: settings.accent(for: settings.theme))
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
