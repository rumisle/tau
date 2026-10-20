# tau iOS

A Telegram-iOS-grade client for tau. The UI is Telegram's own code wherever it can be: the foundation, the themes and
wallpapers, the context menus, the selection mode, the attachment menu. It talks to the tau server
(`../docs/protocol.md`) or runs on canned data.

## Build

```bash
ios/scripts/build.sh --run     # xcodegen + xcodebuild, install and launch on the "iPhone 17 Pro" simulator
ios/scripts/build.sh --device  # signed Release build on the connected iPhone (TAU_TEAM, default TEAMID)
ios/scripts/uitest.sh          # UI walkthroughs in the simulator; screenshots of each step in /tmp/tau-ui
```

XcodeGen comes from nix when it is not installed (`nix shell nixpkgs#xcodegen`). `Tau.xcodeproj` is generated and
ignored by git; edit `project.yml`.

## Server

The app connects to `ws://nest.example.ts.net:7878`, the Mac's server by its tailnet name (`Tau/Info.plist` allows
plain WebSockets to `*.ts.net`, which WireGuard encrypts, and to the local network). Settings > Server sets another address and the `TAU_TOKEN`. The UI tests pass `-server.url ws://127.0.0.1:7878` to reach
the local server directly. "Use Demo Data" in the same dialog, or the `-mock YES` launch argument, switches to canned
conversations (`Model/MockStore.swift`).

`Server/` is the client side of the protocol, after `server/src/client.ts`:

| File | Role |
|---|---|
| `TauConnection.swift` | One WebSocket: requests by id, pushes, `hello`, reconnect with backoff; the chat list title shows Telegram's "Connecting…" / "Updating…" meanwhile |
| `ConversationReplica.swift` | A conversation's cached entries, docs kept current with ops, and `TranscriptBuilder`, which turns entries and `pi.live` into rows |
| `ServerStore.swift` | The store: dialog list, subscriptions while a chat is open, drafts, sends with idempotent request IDs, fork-based edits, the entry cache in Caches |
| `JSONValue.swift` | The protocol's ops applied to JSON |

Rows keep their IDs from streaming to committed: an assistant row is keyed by the generation task that writes it
(`pi.live.run.taskId` while it streams, `byTaskId` on the entry), a sent message by its local ID until its entry arrives.
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
| `-compose YES` | Open New Chat |

## How the Telegram code is used

Telegram-iOS is GPLv2, and so is this app.

`scripts/vendor_telegram.py` copies modules verbatim into `ThirdParty/Telegram`, at the commit in
`ThirdParty/Telegram/REVISION`, with Telegram's paths so `diff -r` against a checkout shows every change, and generates a
SwiftPM package with one target per Bazel module. It reads Telegram's BUILD files itself (they are Starlark; see
`scripts/telegram_build.py`): from the modules tau imports (`ROOTS`) it follows the dependencies, takes each module's
sources, headers, defines and include paths, and stops at **shims**. It also generates `PresentationStrings` with
Telegram's own script, and copies every image and Lottie file the copied sources name.

**Copied** (78 modules), among them:

| Modules | Used for |
|---|---|
| AsyncDisplayKit, SwiftSignalKit, Display | Nodes, signals, `ListViewImpl`, `NavigationController`, `Window1`, context gestures |
| TelegramPresentationData, PresentationStrings | The Classic, Day, Night and Tinted Night themes, Telegram's strings |
| ContextUI, ContextControllerImpl | The context menu: a message lifts out of the list; the chat list preview; the title menu |
| CheckNode, ChatMessageSelectionNode, AnimatedTextComponent, ChatTitleActivityNode, AnimatedCountLabelNode | Selection mode, the rolling "N Selected" title, "working" with typing dots, the scroll-to-bottom badge |
| AttachmentUI, MediaPickerUI, LegacyComponents | The attachment menu: glass sheet, photo grid with the camera tile, album switcher, caption field |
| NavigationBarImpl, GlassBackgroundComponent, EdgeEffect, TabBarComponent, LiquidLens | Liquid Glass bars, buttons and the tab bar |
| GradientBackground, Svg | The wallpaper gradient and its pattern |
| RLottieBinding, LottieComponent | Telegram's animated icons |
| InteractiveTextComponent, StreamingTextReveal | Message text and the streaming reveal |

**Shimmed** (`ThirdParty/telegram-shims/`, 44 modules): stand-ins with a Telegram module's name and only the API the
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

Not yet: Telegram's full-screen media viewer and photo editor (LegacyMediaPickerGallery; the editor's paint tab needs
DrawingUI), voice input.

## Layout

The app differs from Telegram where an agent chat needs it: user messages are bubbles; assistant answers have no bubble
and run the full width on the wallpaper, rendered as Markdown (`Chat/MarkdownText.swift`); tool calls are compact cards
with their output; thinking is dimmed and folded. The chat list shows each conversation's project directory where
Telegram shows a group message's author. A new chat starts from a project picker (`ChatList/ComposeController.swift`,
recent projects and the server's folders through `fs.list`) and stays a draft until its first message.
