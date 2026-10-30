# Appearance

Settings > Appearance, as Telegram's: a color theme, its accent color, Auto-Night, and code block wrapping
(`ios/Tau/Theme`, `ios/Tau/Settings/SettingsController.swift`).

## Themes

Telegram's four built-in themes, copied verbatim (`TelegramPresentationData/Sources/Default*PresentationTheme.swift`):
Classic, Day, Night and Tinted Night. tau's chat background is a plain color of its own per theme, since assistant
text sits on it without a bubble (`TauTheme.Builtin.plainBackground`). With Auto-Night following the system, a night
theme replaces a light one while the phone is in dark mode.

## Accent colors

One accent, the user's, in every theme: unlike Telegram's `themeSpecificAccentColors`, which keeps one per theme.
With Auto-Night the theme follows the phone, so a theme never picked for showed tau's pink whenever the phone went
dark (or iOS drew the app's snapshot in the other appearance), and the Live Activity took it too. A theme without
the accent picked has its nearest: white for Night, black for Day, gray for the others. Settings from before, one per
theme, become the one picked (not tau's). At launch the theme is the one for the phone's appearance then, not a light
one until the window reports it. The colors are Telegram's base colors
(PresentationThemeBaseColor): blue, cyan, green, pink, orange, purple, red, yellow and gray, with black only for Day,
white only for Night, and no gray for Night (ThemePickerController). tau's default is Telegram's pink, `0xeb6ca4`.
Telegram's presets (an accent with bubble gradients and a wallpaper) and custom colors are not offered.

tau's own τ (the header of Settings and About) is in the accent: Telegram's avatar gradient made from it, the accent at
the bottom and a lighter tint of it on top (`Avatar.image(letters:accent:diameter:)`), so yellow and gray, which have no
avatar palette, have one too. White, Night's, goes from white down to a light gray under a dark τ; black, Day's,
lightens to a dark gray on top. The Live Activity's τ and ring take the accent too (`ContentState.accent`); the app icon
does not.

A theme is made as Telegram makes a built-in theme with an accent (`makePresentationTheme(mediaBox:themeReference:
accentColor:)`): `customizePresentationTheme(..., editing: true, accentColor:, baseColor:)`, which tints buttons,
links, checks, switches and the tab bar, and the outgoing bubbles of Day and Night; Tinted Night derives its
backgrounds from the accent's hue, and tau's chat background there follows (Telegram's `additionalBackgroundColor`, a
step darker). Blue is each theme's own accent: the theme unchanged. Night's blue is `0x3e88f7`, as
`PresentationThemeAccentColor.colorFor(baseTheme:)` has it.

The swatches are Telegram's ThemeSettingsAccentColorItem: a 2 pt ring around a fill 4 pt inside it, which covers the
ring (scale 1.2) until chosen and shrinks inside it (0.3 s); a row that scrolls sideways when they do not fit, a last
one peeking out.

## Readable text

Tinted Night's colors are the accent's, its brightness scaled (`customizeDefaultDarkTintedPresentationTheme`), so a
darker accent darkens the text with the backgrounds: on green, the chat list's previews, the chat bar's status, the
agent's times and the tab bar's labels measured APCA Lc 20, half of Night's. `Readability` (`ios/Tau/Theme`) lifts
them after Telegram makes a theme, after the approach of pi's system theme: each rule names a color, the surfaces it
is drawn on and the contrast it needs, and a color short of it on any is made more opaque, or lighter (darker on a
light surface) in OKLCH, keeping its hue and chroma. Secondary text needs Lc 37, Night's lowest (its messages' times);
the tab bar's unselected labels Lc 75, as Night's white and Day's black are. A color that reads already is Telegram's:
Classic, Day and Night are unchanged, and Tinted Night's blue moves by a step. An outgoing bubble's time is left on
its accent, where it reads no better on Night or Day.

## The Live Activity

The Dynamic Island and the lock screen card draw in the accent (`TauWidgets/TauLiveActivity.swift`): the app sends it
with each update (`ContentState.accent`), and a change of accent updates a shown activity at once. On their dark
background a very dark accent (Day's black) shows as white. The app icon stays tau's pink.

## Launch arguments

`-theme classic|day|night|tintedNight` (`light`, `dark` too), `-accent <color>` for the theme in effect, `-appearance
YES` to open Settings > Appearance.
