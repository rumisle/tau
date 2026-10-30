# Working on tau

For people and agents changing tau. What tau is and how to run it is in README.md.

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
| `server/` | The server: `src/host.ts` (Harness setup), `src/connection.ts` (protocol), `src/dialogs.ts` (chat list), `src/subagent.ts` (the subagent tool), `src/titles.ts` (automatic titles) |
| `server/src/client.ts` | Reference client in TypeScript: the state machine the iOS app implements (cache, holes, ops) |
| `relay/` | The push relay, a Cloudflare Worker that holds the APNs key, for servers without it (docs/notifications.md) |
| `vendor/pi` | pi at the commit in `PI_REVISION` (gitignored); the server links durable, pi-ai, and chord from it |
| `scripts/setup-pi.sh` | Clones and builds `vendor/pi`; `--latest` moves `PI_REVISION` to pi's main |
| `scripts/build-release.sh`, `release.sh`, `check-release.ts` | A release of the server: one bundle, checked, published on GitHub (docs/deploy.md) |
| `scripts/tau`, `install.sh` | The `tau` command a release ships (setup, upgrade, rollback) and the Linux installer |

## Docs

| Doc | What |
|---|---|
| `docs/protocol.md` | The wire protocol: sync model, methods, pushes, op format |
| `docs/deploy.md` | Releases and deploying them: one bundle with pi in it, `install.sh` on Linux, `tau upgrade` and `tau rollback` |
| `docs/notifications.md` | When the user hears about an answer: in-app banners, Apple's pushes, the relay, sealed pushes |
| `docs/live-activity.md` | The Live Activity and Dynamic Island (`ios/TauWidgets`): which chats, what they show, and what waits for APNs |
| `docs/network.md` | What goes over the connection, and when: one round trip to connect, a silent socket closed, what entries leave out, the chat list by version |
| `docs/sending.md` | How a message reaches the model: steer and follow-up, refusals, the client's outbox state machine, and what the user sees |
| `docs/chat-open.md` | Opening a chat at once: ready without the network, Telegram's spinner, the top of the list preloaded |
| `docs/streaming.md` | Reading while an answer streams: what moved, overlapped and blanked, and why it no longer does |
| `docs/compaction.md` | Compaction: durable's, started at 90% of the window (at most 700k tokens), with the summary asked for after the conversation's cached context, and its card in the chat |
| `docs/cache.md` | Prompt cache warming: refreshing a working run's cache before it expires, when that pays |
| `docs/codemode.md` | Code mode: the agent's scripts call the tools, one card with a line per call; what a script sends or starts as display entries |
| `docs/skills.md` | Skills: `.agents/skills` in the system prompt, as a section durable updates with a delta |
| `docs/media.md` | Images by reference: a photo or a tool's image laid out from its size, fetched when shown |
| `docs/files.md` | Files: kept beside the database, named to the model by path, sent back with `send_file`, shown as Telegram's documents |
| `docs/search.md` | Search: the index each server keeps as entries are written (`server/src/search`), matching and ranking, and the benchmark |
| `docs/history.md` | history_search and history_read: an agent searches and reads the server's chats by tau link, its own past compaction, its subagents', its owner's; tool calls and output in the index; the cards |
| `docs/links.md` | tau's links to chats and messages: copying, opening, the cards they show |
| `docs/quotes.md` | Quoting selected text into the field: `<tau:quote>`, how the field and the chat show it |
| `docs/share.md` | The share extension (`ios/TauShare`): sending to chats or a new one from any app |
| `docs/folders.md` | Chat folders: tabs by server or chat over the list, and Settings > Chat Folders |
| `docs/dictation.md` | Dictation in the composer: the field with the microphone in it and Send that morphs in; off until a provider is chosen in Settings |
| `docs/appearance.md` | Themes and accent colors, as Telegram's Appearance: each built-in theme with its own accent, the Live Activity in it |
| `docs/typography.md` | How answers are set: clreq's and Butterick's rules, what Core Text does and what tau adds, and iOS's text size |
| `docs/edits-and-forks.md` | Design notes, not built: edit as versions in one chat, fork as another chat, and what subagents do in each |

## Run from the source

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
but loopback, unless `--no-auth`.

The data (the database and its search index) is in `--data`, by default `$XDG_DATA_HOME/tau` or `~/.local/share/tau`,
which the server makes only its owner may enter; `--db <file>` names a database instead, as the tests do. The code
stays apart, so a deploy replaces it freely. `server/contrib/tau-server.service` runs a source checkout under systemd.

## The dev model

`dev/echo` is free: it echoes, runs `$ <command>` through bash, starts a subagent for `& <name> [fork] [model=…]
[thinking=…]: <task>`, waits before answering `~<seconds> <text>`, fails as an overloaded provider `!overloaded <times>
<text>`, for good `!fatal <text>` or for good once `!flaky <text>` (a continue then answers), streams a long Markdown
answer for `!doc <sections>`, answers all at once as a buffering provider for `!burst <text>`, reads a file for `!read
<path>`, runs a code mode script for `!code <script>` or `!code @<path>`, writes a slow tool call for `!longcall <n>`,
calls any tool for `!tool <name> <JSON or key=value arguments>` (kinds=user,assistant a list), and writes a short
summary when asked to compact. `--dev-cache-ttl <seconds>` gives it a prompt cache and prices, to try cache warming.

## The app

Building, the UI tests and their launch arguments are in ios/README.md. The UI test scripts read this Mac's token, and
a second server's for the tests of several servers (`ios/Config/Local.example.env`).
