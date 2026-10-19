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
| `docs/protocol.md` | The wire protocol: sync model, methods, pushes, op format |
| `server/` | The server: `src/host.ts` (Harness setup), `src/connection.ts` (protocol), `src/dialogs.ts` (chat list) |
| `server/src/client.ts` | Reference client in TypeScript: the state machine the iOS app implements (cache, holes, ops) |
| `vendor/pi` | pi at the commit in `PI_REVISION` (gitignored); the server links durable, pi-ai, and chord from it |
| `scripts/setup-pi.sh` | Clones and builds `vendor/pi`; `--latest` moves `PI_REVISION` to pi's main |

## Run

Requires Node 22.18+ (runs TypeScript directly). tau tracks durable on pi's main branch, not the npm release.

```bash
scripts/setup-pi.sh                         # once, and after changing PI_REVISION
cd server
npm start                                   # dev/echo model, data in ../data/tau.sqlite, ws://127.0.0.1:7878
npm start -- --model anthropic/claude-opus-5-5 --cwd ~/work   # default cwd; clients pick their own
npm start -- --memory --dev-tps 20          # throwaway storage, slow streaming
TAU_TOKEN=secret npm start -- --host 0.0.0.0  # require a token when reachable from the phone
npm test
npm run check
```

Model credentials come from pi's `~/.pi/agent/auth.json` (the same logins as the `pi` CLI, safe to share) and the
usual provider environment variables. The `dev/echo` model is free: it echoes, and runs `$ <command>` through bash.
