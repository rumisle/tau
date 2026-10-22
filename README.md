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
| `docs/notifications.md` | When the user hears about an answer: Telegram's in-app banners, pushes through ntfy while the app is closed, and the way to Apple's push |
| `docs/sending.md` | How a message reaches the model: steer and follow-up, refusals, the client's outbox state machine, and what the user sees |
| `docs/chat-open.md` | Opening a chat at once: ready without the network, Telegram's spinner, the top of the list preloaded |
| `docs/media.md` | Images by reference: a photo or a tool's image laid out from its size, fetched when shown |
| `docs/compaction.md` | Compaction: durable's, started at 90% of the window (at most 700k tokens), with the summary asked for after the conversation's cached context |
| `docs/skills.md` | Skills: `.agents/skills` in the system prompt, as a section durable updates with a delta |
| `docs/dictation.md` | Dictation in the composer: Telegram's field with the microphone in it and Send that morphs in, and Aqua Voice's realtime API |
| `docs/appearance.md` | Themes and accent colors, as Telegram's Appearance: each built-in theme with its own accent, Telegram's pink by default, the Live Activity in it |
| `docs/cache.md` | Prompt cache warming: refreshing a working run's cache before it expires, when that pays |
| `docs/streaming.md` | Reading while an answer streams: what moved, overlapped and blanked, and why it no longer does |
| `docs/search.md` | Search: the index each server keeps as entries are written (`server/src/search`), matching and ranking, and the benchmark |
| `docs/live-activity.md` | The Live Activity and Dynamic Island (`ios/TauWidgets`): which chats, what they show, and what waits for APNs |
| `docs/folders.md` | Chat folders: tabs by server, project or chat over the list, and Settings > Chat Folders |
| `docs/share.md` | The share extension (`ios/TauShare`): sending to chats or a new one from any app |
| `server/` | The server: `src/host.ts` (Harness setup), `src/connection.ts` (protocol), `src/dialogs.ts` (chat list), `src/subagent.ts` (the subagent tool), `src/titles.ts` (automatic titles) |
| `server/src/client.ts` | Reference client in TypeScript: the state machine the iOS app implements (cache, holes, ops) |
| `vendor/pi` | pi at the commit in `PI_REVISION` (gitignored); the server links durable, pi-ai, and chord from it |
| `scripts/setup-pi.sh` | Clones and builds `vendor/pi`; `--latest` moves `PI_REVISION` to pi's main |

## Run

Requires Node 22.18+ (runs TypeScript directly). tau tracks durable on pi's main branch, not the npm release.

```bash
scripts/setup-pi.sh                         # once, and after changing PI_REVISION
cd server
npm start                                   # dev/echo model, data in ../data/tau.sqlite, ws://127.0.0.1:7878
npm start -- --model anthropic/claude-haiku-5-5 --cwd ~/work  # default cwd; clients pick their own
npm start -- --memory --dev-tps 20          # throwaway storage, slow streaming
TAU_TOKEN=secret npm start -- --host 0.0.0.0  # require a token when reachable from the phone
npm test
npm run check
```

Model credentials come from pi's `~/.pi/agent/auth.json` (the same logins as the `pi` CLI, safe to share) and the
usual provider environment variables. The `dev/echo` model is free: it echoes, runs `$ <command>` through bash, starts a subagent for
`& <name> [fork] [model=…] [thinking=…]: <task>`, waits before answering `~<seconds> <text>`, fails as an overloaded provider
`!overloaded <times> <text>` or for good `!fatal <text>`, streams a long Markdown answer for `!doc <sections>`, reads a file for `!read <path>`, and writes a
short summary when asked to compact. `--dev-cache-ttl <seconds>` gives it a prompt cache and prices, to try cache warming.
