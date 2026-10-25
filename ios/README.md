# tau iOS

A Telegram-iOS-grade client for tau. The UI is Telegram's own code wherever it can be: the foundation, the themes and
wallpapers, the context menus, the selection mode, the attachment menu. It talks to the tau server
(`../docs/protocol.md`) or runs on canned data.

## Build

```bash
ios/scripts/build.sh --run     # xcodegen + xcodebuild, install and launch on the "iPhone 17 Pro" simulator
ios/scripts/build.sh --device  # signed Release build on the connected iPhone (the team in Config/Local.xcconfig)
ios/scripts/testflight.sh      # archive and upload to App Store Connect ("tau agent") for TestFlight
ios/scripts/uitest.sh          # UI walkthroughs in the simulator; screenshots of each step in /tmp/tau-ui
ios/scripts/sending-tests.sh   # the sending state machine against the dev server (scripts/devserver.sh, port 7979)
uv run ios/scripts/uitests.py  # all of them on 3 simulators at once, a dev server each: about 14 min instead of 40
```

XcodeGen comes from nix when it is not installed (`nix shell nixpkgs#xcodegen`). `Tau.xcodeproj` is generated and
ignored by git; edit `project.yml`.

Who the app is comes from `Config/Tau.xcconfig`, and yours from `Config/Local.xcconfig` (gitignored; copy
`Config/Local.example.xcconfig`): the bundle ID, under which each extension's is and the keychain group the app shares
with them (`$(AppIdentifierPrefix)$(TAU_BUNDLE_ID).shared`), the signing team, and the server a new install connects
to. The scripts read the same file (`scripts/config.sh`).

## Server

A new install connects to `TAU_DEFAULT_SERVER` (for example the Mac's server by its tailnet name), else to
`127.0.0.1:7878` (`Tau/Info.plist` allows plain WebSockets to `*.ts.net`, which WireGuard encrypts, and to the local
network). Settings > Server sets another address and the server's token. The UI tests pass `-server.url ws://127.0.0.1:7878`
(and `-server.token`, which the test scripts read from `~/.config/tau/token`) to reach the local server directly. "Use Demo Data" in the same dialog, or the `-mock YES` launch argument, switches to canned
conversations (`Model/MockStore.swift`).

`Server/` is the client side of the protocol, after `server/src/client.ts`:

| File | Role |
|---|---|
| `TauConnection.swift` | One WebSocket: requests by id, pushes, `hello` with the first requests behind it, reconnect with backoff, a ping that finds a dead socket, waking that replaces one the server closed, a response timeout (`../docs/network.md`); the chat list and chat titles show Telegram's "Connecting…" / "Updating…" meanwhile |
| `MultiStore.swift` | Every configured server at once, one ServerStore each: their chats in one list, conversation IDs that carry the server's slot, Telegram's title status across them; the saved server list |
| `Outbox.swift` | Messages on their way, on disk until the server has them: one request per conversation at a time, in order, idempotent retries, safe withdraws (`../docs/sending.md`) |
| `ConversationReplica.swift` | A conversation's cached entries, docs kept current with ops, and `TranscriptBuilder`, which turns entries and `pi.live` into rows |
| `ServerStore.swift` | The store: dialog list (by version, on disk), subscriptions while a chat is open, drafts, sending through the outbox, steer and follow-up, Stop that returns queued messages to the field, fork-based edits, the entry cache in Caches |
| `JSONValue.swift` | The protocol's ops applied to JSON |

Rows keep their IDs from streaming to committed: an assistant row is keyed by the generation task that writes it
(`pi.live.run.taskId` while it streams, `byTaskId` on the entry), a sent message by its outbox row ID, which its entry
keeps once placed.

A message shows Telegram's clock until the server has it and two checks once it is in the transcript; one refused gets
the red badge with Resend and Delete. While the agent works, Send steers and a long press offers Send as Follow-up and
Stop and Send; queued messages wait in Telegram's input accessory panel (`Chat/InputAccessoryPanelView.swift`), whose
menu edits, moves, sends now or deletes them. See `../docs/sending.md`.
A tool call and its result are one card; a `subagent` call links to the child conversation.

## Debug launch arguments

For checking UI from the command line (`ios/scripts/shot.sh out.png 3 -- <args>` relaunches and screenshots):

| Arguments | Effect |
|---|---|
| `-mock YES` | Canned data instead of the server |
| `-server.url ws://host:7878` | Another server for this launch |
| `-openChat 2` | Open conversation 2 at launch (`-pushChat 2`: with the push animation) |
| `-openChat 2 -send "hi"` | ...and send a message a second later |
| `-openChat 2 -focus YES` | ...and focus the input field |
| `-theme tintedNight` | Force a theme: `classic`, `day`, `night`, `tintedNight` (`light`, `dark` alias Classic and Tinted Night) |
| `-tab 1` | Open the Settings tab |
| `-wrapCode NO` | Code blocks scroll sideways instead of wrapping (Settings > Appearance > Wrap Lines) |
| `-compose YES` | Open New Chat |

`TAU_TIMING=1` in the environment (`SIMCTL_CHILD_TAU_TIMING=1 xcrun simctl launch ...`) logs each message row's layout
time and, once a second, the frames drawn and missed, to `/tmp/tau-timing.log`.

The archive, read state, and unread counts live on the server (`conversation.read`, `conversation.mark`), so every
device agrees; Settings > Default Model sets the server's default (`settings.configure`).

## How the Telegram code is used

Telegram-iOS is GPL v2 or later; tau, with the parts it takes from elsewhere, is GPL v3 or later (`../LICENSE`,
`../README.md`).

`scripts/vendor_telegram.py` copies modules verbatim into `ThirdParty/Telegram`, at the commit in
`ThirdParty/Telegram/REVISION`, with Telegram's paths so `diff -r` against a checkout shows every change, and generates a
SwiftPM package with one target per Bazel module. It reads Telegram's BUILD files itself (they are Starlark; see
`scripts/telegram_build.py`): from the modules tau imports (`ROOTS`) it follows the dependencies, takes each module's
sources, headers, defines and include paths, and stops at **shims**. It also generates `PresentationStrings` with
Telegram's own script, and copies every image and Lottie file the copied sources name.

**Copied** (91 modules), among them:

| Modules | Used for |
|---|---|
| AsyncDisplayKit, SwiftSignalKit, Display | Nodes, signals, `ListViewImpl`, `NavigationController`, `Window1`, context gestures |
| TelegramPresentationData, PresentationStrings | The Classic, Day, Night and Tinted Night themes, Telegram's strings |
| ContextUI, ContextControllerImpl | The context menu: a message lifts out of the list; the chat list preview; the chat's menu |
| CheckNode, ChatMessageSelectionNode, AnimatedTextComponent, ChatTitleActivityNode, AnimatedCountLabelNode | Selection mode, the rolling "N Selected" title, "working" with typing dots, the scroll-to-bottom badge |
| AttachmentUI, MediaPickerUI, LegacyComponents | The attachment menu: glass sheet, photo grid with the camera tile, album switcher, caption field |
| NavigationBarImpl, GlassBackgroundComponent, EdgeEffect, TabBarComponent, LiquidLens | Liquid Glass bars, buttons and the tab bar |
| GradientBackground, Svg | The wallpaper gradient and its pattern |
| RLottieBinding, LottieComponent, ManagedAnimationNode | Telegram's animated icons, the swipe actions' icons |
| ItemListUI (rows only), ChatListBadgeNode (in `Tau/ChatList`) | The chat list's swipe actions (Read / Unread, Archive, Delete) and unread badges |
| GalleryUI (its frame: pager, zoom, swipe to dismiss, transitions) | The media viewer for sent photos (`Chat/ImageGalleryController.swift`, after InstantPageGalleryController) |
| TextSelectionNode, ContextMenuScreen | Selecting text in a message lifted into its context menu or, after a double tap, in place, over the whole message (docs/typography.md), and the menu over the selection, Quote included (docs/quotes.md) |
| SearchBarNode, SearchUI | The model picker's search (`Settings/ModelPickerController.swift`, after LanguageSelectionScreen) |
| ChatListTitleView | The chat list's "Connecting..." / "Updating..." title with its spinner |
| AlertComponent, AlertInputFieldComponent | Telegram's alerts with fields: Rename Chat, Add Server, a server's name and address |
| UndoUI (no account-bound toasts, patch 0010) | Telegram's toasts: "Text copied to clipboard", model changes, notices |
| libprisma (Prism's grammars in C++) | Syntax highlighting of code blocks and of the files tool cards show |
| InteractiveTextComponent, StreamingTextReveal | Message text and the streaming reveal |
| MessageInlineBlockBackgroundView | A quote in the field, as Telegram's field draws one (docs/quotes.md) |

**Shimmed** (`ThirdParty/telegram-shims/`, 41 modules): stand-ins with a Telegram module's name and only the API the
copied code uses, for modules bound to Telegram's account, network and database (`TelegramCore`, `Postbox`,
`AccountContext`, ...) or to features tau does not have (reactions, stickers, stories, calls). Most are a few types;
some do real work in Telegram's shapes: `AttachmentTextInputPanelNode` is the caption field, `AnimatedStickerComponent`
plays the tab icons through LottieComponent. A new module that needs more members gets them added here, with
Telegram's names.

**Patched** (`ThirdParty/telegram-patches/`, reapplied after each copy): cuts where a copied module uses a
TelegramCore-bound feature inline.

| Patch | Removes |
|---|---|
| 0001, 0002 | Custom emoji and spoilers in message text |
| 0003 | Cloud themes and the account's settings in TelegramPresentationData |
| 0004, 0005 | The attachment menu's chat input interaction, music player, bots, AI captions, minimizing |
| 0006, 0007 | The media picker's story, sticker and avatar modes, its full-screen gallery, the message preview |
| 0008, 0009 | ItemListUI and GalleryUI without their screens: a typealias and a class their kept files use |

0002 also puts InteractiveTextNode's attachments on the text baseline at their own height, for inline formulas.

`App/TelegramAccountContext.swift` is the AccountContext Telegram's components take, and the LegacyComponents globals
provider (after Telegram's `TelegramInitializeLegacyComponents.swift`).

To change vendored code: edit it in `ThirdParty/Telegram`, then record the change with
`scripts/make_patch.sh <name> <paths>`. To add a module: check out Telegram-iOS into `vendor/Telegram-iOS`
(`git clone --depth 1 https://github.com/TelegramMessenger/Telegram-iOS vendor/Telegram-iOS`, then
`git -C vendor/Telegram-iOS submodule update --init --depth 1 submodules/rlottie/rlottie`), add it to `ROOTS`, run
`uv run ios/scripts/vendor_telegram.py`, and build the package to see which shim members it needs.

**Ported** into `Tau/`, where Telegram's screens are bound to the chat stack (ChatControllerImpl and its 500
modules): the chat list row (`ChatList/ChatListItem.swift`), message rows (`Chat/ChatMessageItem.swift`, after
ChatMessageBubbleItemNode), the chat screen (`Chat/ChatControllerNode.swift`), the wallpaper (`Chat/WallpaperNode.swift`,
after WallpaperBackgroundNode, with the pattern composed into the gradient instead of a live blend), and the settings
lists (`Settings/`, in ItemListUI's glass style). `Chat/ChatHistoryNavigationButtonNode.swift` is copied from
TelegramUI.

Not copied: LaTeX, which Telegram does not render. `Chat/MathText.swift` typesets `$...$`, `\(...\)`, `$$...$$` and
`\[...\]` with [SwiftMath](https://github.com/mgriebling/SwiftMath) (MIT, a SwiftPM dependency) and hands the formulas to
InteractiveTextNode as attachments.

Not yet: Telegram's photo editor (LegacyMediaPickerGallery; its paint tab needs DrawingUI), voice input.

## Layout

The app differs from Telegram where an agent chat needs it: user messages are bubbles; assistant answers have no bubble
and run the full width on the wallpaper, rendered as Markdown (`Chat/MarkdownText.swift`); tool calls are compact cards
made for each tool (a command with the end of its output, a file highlighted by its language, an edit as a diff);
thinking is dimmed and folded. With Settings > Appearance > Wrap Lines off, each code block is laid out on its own,
unwrapped, in a horizontal scroller. The bar has no title, as ChatGPT's: Back, then New Chat (on the latest chat's server, over this chat, so Back returns; held, the servers to pick, the finger sliding to one) and Telegram's animated ⋯ (held, the menu follows the finger), the chat's menu, which starts with its title in full (and its server's name, with several) and shows the model by name, the thinking level, and Usage: how full the
context is (the latest response's tokens against the model's context window) and the spend from `pi.usage`. A link, from Markdown or written out (with its scheme or `www.`, as a file name like `README.md` is not one), opens on a tap in Safari's view over the app, as Telegram's in-app browser; held, it lifts the message with Telegram's link menu: Open, Open in Browser, Copy Link, Add to Reading List. Where Telegram's title sits, a small glass capsule says what goes on (working and for how long, compacting, subagents working, Connecting…) and is gone when nothing does. A long answer is parsed and laid out in chunks split at safe paragraph breaks, so a
streaming step costs one chunk rather than the whole answer. The field's placeholder names the model ("Message Claude Opus 5.5", "Steer …" while it works). A chat list row is the title and two lines of the last message, as a private chat's; with several servers, its server's tag in the place of Telegram's folder tags or beside the time (Settings > Appearance > Server Tags). There are no project directories: chats start where the server starts them (`docs/protocol.md`). A new chat is a draft until its first message; its card names its server (with several) and its model, each a tap from changing.
