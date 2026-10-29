# tau

A Telegram-grade iOS client for [pi-durable](https://github.com/earendil-works/pi/tree/main/packages/durable) agents.

```
iOS app  <-- WebSocket, docs/protocol.md -->  server/ (Node: pi-durable Harness + SQLite + coding tools)
```

Durable commits every step of an agent run to SQLite before showing it. If the server dies mid-answer, the run picks
up where it stopped after a restart. The server exposes that state as a sync protocol modelled on Telegram's:
immutable entries the phone caches by ID, plus small live documents streamed as JSON ops.

## Layout

| Path | What |
|---|---|
| `ios/` | The iOS app: Telegram-iOS's own UI code (themes, context menus, attachment menu) around ported chat screens (see ios/README.md) |
| `docs/protocol.md` | The wire protocol: sync model, methods, pushes, op format |
| `docs/notifications.md` | When the user hears about an answer: Telegram's in-app banners, Apple's push while the app is closed: notifications as the chat's messages, with Reply |
| `docs/network.md` | What goes over the connection, and when: one round trip to connect, a silent socket closed, what entries leave out, the chat list by version |
| `docs/sending.md` | How a message reaches the model: steer and follow-up, refusals, the client's outbox state machine, and what the user sees |
| `docs/chat-open.md` | Opening a chat at once: ready without the network, Telegram's spinner, the top of the list preloaded |
| `docs/media.md` | Images by reference: a photo or a tool's image laid out from its size, fetched when shown |
| `docs/files.md` | Files: kept beside the database, named to the model by path, sent back with `send_file`, shown as Telegram's documents |
| `docs/codemode.md` | Code mode: the agent's scripts call the tools, one card with a line per call; what a script sends or starts as display entries |
| `docs/compaction.md` | Compaction: durable's, started at 90% of the window (at most 700k tokens), with the summary asked for after the conversation's cached context |
| `docs/skills.md` | Skills: `.agents/skills` in the system prompt, as a section durable updates with a delta |
| `docs/dictation.md` | Dictation in the composer: Telegram's field with the microphone in it and Send that morphs in; off until a provider is chosen in Settings; Aqua Voice's realtime API with the user's session key |
| `docs/appearance.md` | Themes and accent colors, as Telegram's Appearance: each built-in theme with its own accent, Telegram's pink by default, the Live Activity in it |
| `docs/typography.md` | How answers are set: clreq's and Butterick's rules, what Core Text does and what tau adds (spacing, hanging lists, no lone characters, the Chinese ellipsis, curly quotes), and iOS's text size |
| `docs/cache.md` | Prompt cache warming: refreshing a working run's cache before it expires, when that pays |
| `docs/streaming.md` | Reading while an answer streams: what moved, overlapped and blanked, and why it no longer does |
| `docs/edits-and-forks.md` | Design notes, not built: edit as versions in one chat, fork as another chat, and what subagents do in each |
| `docs/deploy.md` | Releases and deploying them: one bundle with pi in it, `install.sh` on Linux, `tau upgrade` and `tau rollback` |
| `docs/search.md` | Search: the index each server keeps as entries are written (`server/src/search`), matching and ranking, and the benchmark |
| `docs/live-activity.md` | The Live Activity and Dynamic Island (`ios/TauWidgets`): which chats, what they show, and what waits for APNs |
| `docs/folders.md` | Chat folders: tabs by server or chat over the list, and Settings > Chat Folders |
| `docs/quotes.md` | Quoting selected text into the field: `<tau:quote>`, how the field and the chat show it |
| `docs/links.md` | tau's links to chats and messages: copying, opening, the cards they show |
| `docs/share.md` | The share extension (`ios/TauShare`): sending to chats or a new one from any app |
| `server/` | The server: `src/host.ts` (Harness setup), `src/connection.ts` (protocol), `src/dialogs.ts` (chat list), `src/subagent.ts` (the subagent tool), `src/titles.ts` (automatic titles) |
| `server/src/client.ts` | Reference client in TypeScript: the state machine the iOS app implements (cache, holes, ops) |
| `vendor/pi` | pi at the commit in `PI_REVISION` (gitignored); the server links durable, pi-ai, and chord from it |
| `relay/` | The push relay, a Cloudflare Worker that holds the APNs key, for servers without it (docs/notifications.md) |
| `scripts/setup-pi.sh` | Clones and builds `vendor/pi`; `--latest` moves `PI_REVISION` to pi's main |

## Run

On a server, from a release (docs/deploy.md): `curl -fsSL https://github.com/rumisle/tau/releases/latest/download/install.sh | sh`, then `tau upgrade`. From the source:

Requires Node 22.18+ (runs TypeScript directly). tau tracks durable on pi's main branch, not the npm release.

```bash
scripts/setup-pi.sh                         # once, and after changing PI_REVISION
cd server
npm start                                   # dev/echo model, data in ~/.local/share/tau, ws://127.0.0.1:7878
npm start -- --data ../data                 # data beside the code, as on a dev machine
npm start -- --model anthropic/claude-haiku-5-5   # the default model; chats start in ~
npm start -- --memory --dev-tps 20          # throwaway storage, slow streaming
npm start -- --host 0.0.0.0 --token-file ~/.config/tau/token  # reachable from the phone: clients need the token
npm test
npm run check
```

A server reachable beyond loopback runs commands for anyone who reaches it, so it must have a token: `--token-file`
(only its owner may read it; by convention `~/.config/tau/token`), or `TAU_TOKEN`. Without one it refuses any `--host`
but loopback, unless `--no-auth`. Make one, then give it to the app (Settings > Servers > the server > Address):

```bash
umask 077 && mkdir -p ~/.config/tau && openssl rand -hex 32 > ~/.config/tau/token
pbcopy < ~/.config/tau/token                # on the Mac, or from a Linux server: ssh host 'cat ~/.config/tau/token' | pbcopy
```

The data (the database and its search index) is in `--data`, by default `$XDG_DATA_HOME/tau` or `~/.local/share/tau`,
which the server makes only its owner may enter; `--db <file>` names a database instead, as the tests do. The code
stays apart, so a deploy replaces it freely.

`server/contrib/tau-server.service` runs it with a token under systemd, as a user unit: as its user, since the agents
work on that user's files. The UI test scripts read this Mac's token, and a second server's for the tests of several
servers (`ios/Config/Local.example.env`), and pass them to the tests.

Model credentials come from pi's `~/.pi/agent/auth.json` (the same logins as the `pi` CLI, safe to share) and the
usual provider environment variables. The `dev/echo` model is free: it echoes, runs `$ <command>` through bash, starts a subagent for
`& <name> [fork] [model=…] [thinking=…]: <task>`, waits before answering `~<seconds> <text>`, fails as an overloaded provider
`!overloaded <times> <text>` or for good `!fatal <text>`, streams a long Markdown answer for `!doc <sections>`, answers all at once as a buffering provider for `!burst <text>`, reads a file for `!read <path>`, runs a code mode script for `!code <script>` or `!code @<path>`, and writes a
short summary when asked to compact. `--dev-cache-ttl <seconds>` gives it a prompt cache and prices, to try cache warming.

## License

GPL v3 or later (`LICENSE`). The app is built on Telegram-iOS's code, which Telegram licenses under the GPL v2 or later
(telegram.org/apps), and bundles Telegram Desktop's default wallpaper pattern, GPL v3 with an OpenSSL exception
(`ios/ThirdParty/tdesktop/NOTICE`); with Apache 2.0 parts (Texture's AsyncDisplayKit, lottie-ios), which the GPL v2 does
not take, the whole is GPL v3. The server uses pi (MIT), and the app SwiftMath (MIT). Each part copied in keeps its
notice: `ios/ThirdParty/Telegram/NOTICE`, and the LICENSE files of the modules that have one.
