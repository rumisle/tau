import UIKit
import Display
import SwiftSignalKit

/// The app's current theme: Day or Night, following the system unless the user picked one in Settings > Appearance.
/// Screens subscribe to `theme` and restyle in place, as Telegram's controllers follow `presentationData`.
final class ThemeContext {
    enum Mode: String, CaseIterable {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system:
                return "System"
            case .light:
                return "Day"
            case .dark:
                return "Night"
            }
        }
    }

    private static let modeKey = "appearance.mode"

    private let themePromise: ValuePromise<ThemeBox>
    private let modePromise: ValuePromise<Mode>
    private var systemStyle: WindowUserInterfaceStyle = .light
    private var systemStyleDisposable: Disposable?

    private(set) var mode: Mode
    private(set) var current: TauTheme

    init() {
        let mode = Mode(rawValue: UserDefaults.standard.string(forKey: ThemeContext.modeKey) ?? "") ?? .system
        self.mode = mode
        let current = ThemeContext.resolve(mode: mode, system: .light)
        self.current = current
        self.themePromise = ValuePromise(ThemeBox(current), ignoreRepeated: true)
        self.modePromise = ValuePromise(mode, ignoreRepeated: true)
    }

    deinit {
        self.systemStyleDisposable?.dispose()
    }

    var theme: Signal<TauTheme, NoError> {
        return self.themePromise.get() |> map { $0.theme }
    }

    var modeSignal: Signal<Mode, NoError> {
        return self.modePromise.get()
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

    func setMode(_ mode: Mode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: ThemeContext.modeKey)
        self.modePromise.set(mode)
        self.apply()
    }

    private func apply() {
        let theme = ThemeContext.resolve(mode: self.mode, system: self.systemStyle)
        if theme !== self.current {
            self.current = theme
            self.themePromise.set(ThemeBox(theme))
        }
    }

    private static func resolve(mode: Mode, system: WindowUserInterfaceStyle) -> TauTheme {
        switch mode {
        case .system:
            return system == .dark ? .night : .day
        case .light:
            return .day
        case .dark:
            return .night
        }
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
    let store: MockStore
    let themeContext: ThemeContext

    init(store: MockStore, themeContext: ThemeContext) {
        self.store = store
        self.themeContext = themeContext
    }

    var theme: TauTheme {
        return self.themeContext.current
    }
}
