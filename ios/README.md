# tau iOS

A chat client for tau built on Telegram-iOS's UI foundation. It runs on mock data for now (`Tau/Model/MockStore.swift`);
the server connection comes next.

## Build

```bash
ios/scripts/build.sh --run     # xcodegen + xcodebuild, install and launch on the "iPhone 17 Pro" simulator
```

XcodeGen comes from nix when it is not installed (`nix shell nixpkgs#xcodegen`). `Tau.xcodeproj` is generated and
ignored by git; edit `project.yml`.

Debug launch arguments, for checking UI from the command line (`ios/scripts/shot.sh out.png 3 -- <args>` relaunches
and screenshots):

| Arguments | Effect |
|---|---|
| `-openChat 2` | Open conversation 2 at launch |
| `-openChat 2 -send "hi"` | ...and send a message a second later (the mock streams an answer) |
| `-openChat 2 -focus YES` | ...and focus the input field |
| `-sendTo 3 -send "hi"` | Send to conversation 3 without opening it (to see the busy chat list row) |

## How the Telegram code is used

Telegram-iOS is GPLv2, and so is this app.

**Copied verbatim** into `ThirdParty/Telegram` by `scripts/vendor_telegram.py`, at the commit in
`ThirdParty/Telegram/REVISION`, with Telegram's paths so `diff -r` against a checkout shows every change. The script
generates a SwiftPM package (`ThirdParty/Telegram/Package.swift`), one target per Bazel module, modeled on Telegram's own
`build-system/generate_spm.py`:

| Module | What we use it for |
|---|---|
| AsyncDisplayKit (Telegram's minimal Texture fork), SwiftSignalKit, Display | Nodes, signals, `ListViewImpl` (the scrolling list), `NavigationController`, `Window1` (keyboard and layout), `TextNode` |
| ComponentFlow, ComponentDisplayAdapters | Telegram's component system, needed by the glass views |
| NavigationBarImpl, GlassBackgroundComponent, EdgeEffect, MeshTransform | iOS 26 Liquid Glass: navigation bar, glass shapes and containers (`UIGlassEffect` / `UIGlassContainerEffect`), blurred edge fades |
| TabBarComponent, LiquidLens, TabSelectionRecognizer, BundleIconComponent, TextBadgeComponent | The floating glass tab bar with its lens selection |
| InteractiveTextComponent | Message text: code blocks, quotes, and the per-glyph reveal used for streaming |
| StreamingTextReveal | `TextRevealController`, which paces streamed text smoothly between server commits |
| GradientBackground | The four-color animated wallpaper |
| MergeLists | Diffs entry lists into `ListView` insert/delete/update transactions |

**Patched**: two modules needed small cuts to drop their TelegramCore dependencies. Each change is a patch in
`ThirdParty/telegram-patches/`, reapplied by the vendor script:

- `0001`: MessageInlineBlockBackgroundView without custom emoji patterns.
- `0002`: InteractiveTextComponent without custom emoji and spoiler dust.

**Shimmed**: some copied modules import heavy Telegram modules only for a few members (a theme color, a string, a
search field they never show). Rather than patch them, `ThirdParty/telegram-shims/` holds small stand-in modules with the
same names and just those members, so the copied code compiles unchanged:

- `TelegramPresentationData`: the theme and strings types, filled from `Tau/Theme/Theme.swift` (`presentationTheme`).
- `SearchBarNode`: an inert search field, for search modes tau does not enable.
- `LottieComponent`: draws nothing; rlottie is a separate C++ submodule. Tab icons use static images meanwhile.

When a newly copied module needs another member, add it to the shim with Telegram's name. This is how
`TabBarComponent` (the floating glass tab bar) came over verbatim.

To change vendored code: edit it in `ThirdParty/Telegram`, then record the change with
`scripts/make_patch.sh <name> <paths>`. To update or add modules: check out Telegram-iOS into `vendor/Telegram-iOS`
(`git clone --depth 1 https://github.com/TelegramMessenger/Telegram-iOS vendor/Telegram-iOS`), edit the module table in
`vendor_telegram.py`, and run `uv run ios/scripts/vendor_telegram.py`.

**Ported** into `Tau/`: Telegram's chat list and chat screens are bound to TelegramCore (500+ modules), so their layout
code is reimplemented on the foundation above, keeping Telegram's metrics:

| File | From |
|---|---|
| `ChatList/ChatListItem.swift` | ChatListUI `ChatListItem` (60 pt avatar, fonts, row height formula, frames) |
| `Common/AvatarNode.swift` | AvatarNode gradient colors and letter avatars |
| `Chat/BubbleImages.swift` | TelegramPresentationData `messageBubbleImage` (copied, minus knockout and shadow variants) |
| `Chat/ChatMessageItem.swift` | ChatMessageBubbleItemNode layout constants, ChatMessageTextBubbleContentNode text reveal |
| `Chat/ChatControllerNode.swift` | ChatControllerNode / ChatHistoryListNode: rotated list, keyboard layout |
| `Theme/Theme.swift` | DefaultDayPresentationTheme colors |

## Layout

The app differs from Telegram where an agent chat needs it: user messages are bubbles; assistant answers have no bubble
and run the full width on the wallpaper, rendered as Markdown (`Chat/MarkdownText.swift`); tool results are compact cards.
The chat list shows each conversation's project directory where Telegram shows a group message's author.
