# The web client (design, not built)

The plan for tau in a browser: Telegram Web A (github.com/Ajaxy/telegram-tt, GPL-3.0-or-later) as the UI, as the iOS
app takes Telegram-iOS, with a data layer of tau's own written the Telegram way. Nothing here is built yet. A proof of
concept is in the `tau-poc` branch of a scratch clone of Web A (its `TAU-NOTES.md`). It is kept as a reference; its
findings are below.

## What the proof of concept showed

- **The boundary holds.** Web A's UI reaches the network only through `callApi(method, ...)` and hears back through
  `apiUpdate`s carrying plain `Api*` objects (`src/api/types`). Pointing `src/api/gramjs/index.ts` at a connector of
  tau's own replaced GramJS without the UI noticing. The chat list, transcripts and streaming took 4 methods
  (`fetchChats`, `fetchMessages`, `fetchChatFolders`, `fetchPeerColors`) of the 527 the UI calls, and 11 update types
  of about 150. Every other method resolves to `undefined`, as a failed request does, and the UI copes.
- **tau's data fits.** An entry ID is a message ID: global and increasing, with Web A's local IDs as fractions between
  them. Web A has two features made for AI bots: rich messages (`content.richMessage`, Instant View blocks with
  headings, lists, code, tables, math, `thinking` and `details`) and typing drafts (`updateChatTypingDraft`, a bot's
  streamed message, which Web A hands over to the final message). `pi.live.generation` maps onto a typing draft
  directly.
- **The look is tau's with one component.** A row component of tau's own (`TauMessage`), placed in Web A's message list
  in place of its 2,400-line bubble, draws answers without a bubble, thinking, tool and subagent cards, and a run's
  footer, after `ios/Tau/Chat/ChatMessageItem.swift`. Side by side with the iOS app at the same size, a long answer
  breaks its lines at the same words. 13 of Web A's files were edited, 82 lines in all.
- **Hacks it needed**, each a rule for the real thing (section 2): Web A keeps a message it already has, so the chat
  list's truncated summary stuck under the entry's ID; a typing draft is numbered after a last message ID that Web A
  moves 350 ms late; typing status expires after a few seconds; theme colors are set inline on `<html>`.
- **Sizes and times** on this machine: Web A is 422k lines of TS/TSX and 59k of SCSS. A production build takes 3.5 s
  (Vite 8). `tsc` with Web A's TypeScript 6 takes 19 s for the whole project; tau's TypeScript 7 (the server's) takes 5
  s, with one complaint (an unused `@ts-expect-error`). A build's output is 233 MB: 100 MB of emoji images, 94 MB of
  build statistics, 23 MB of source maps. Without those it packs to 6 MB.

## 1. Where the code lives

**Decision: vendored into this repository, in `web/`, at a pinned upstream commit, with Web A's paths. tau's edits to
Web A's files are few, each marked, in place. tau's own code is in directories of its own.** This is the iOS app's
arrangement (`ios/ThirdParty/Telegram`, `ios/scripts/vendor_telegram.py`), adapted to a tree that is taken whole
rather than module by module.

```
web/                      Web A's tree at the commit in web/UPSTREAM, filtered (below), at its own paths
  src/...                 Web A's sources: verbatim except at `tau:` marks
  src/tau/                tau's: the API layer, components, styles (section 2)
  e2e/                    tau's: Playwright tests (section 4)
  UPSTREAM                the upstream commit, and the filter's rules
client/                   tau's: the protocol client, shared by web/ and the server's tests (section 2)
scripts/web/              tau's: dev, test, build, update-upstream, upstream-diff
```

- **Filtered.** Only the files a build needs come in: no `dist/` (222 MB in upstream's tree, rebuilt on every upstream
  commit), no `public/build-stats.json` (98 MB) or `statoscope-report.html`, and no `tauri/` or `deploy/`. The rest is
  3,241 files and 7 MB compressed, about half again the size of this repository's history today (14 MB). An update adds
  only what changed.
- **Why not a fork repository.** A fork of telegram-tt carries its history, with a 222 MB `dist/` committed in each of
  thousands of builds. It is cheaper to merge from (plain `git merge`), but every change that crosses the protocol
  would be two commits in two repositories: protocol, server, iOS and web could no longer change in one commit, as they
  do now, and a release would need a pinned fork commit, checked out beside this one. A git submodule pointing to the
  fork has the same split plus submodule chores. `git subtree --squash` would import upstream's whole tree, `dist/`
  included, because it cannot filter.
- **Edits in place, not patch files.** iOS keeps both the edited tree and `telegram-patches/*.patch` because
  `vendor_telegram.py` rewrites the tree from a checkout. Here the tree is the truth. The diff against the pristine
  upstream commit is the record of tau's edits (`scripts/web/upstream-diff.sh` prints it), so there is no second copy
  to drift.
- **Taking an update** (`scripts/web/update-upstream.sh <commit>`): fetch upstream's old and new commits into a
  shallow clone in `vendor/telegram-tt` (gitignored, as `vendor/pi` is). Apply the filter to both. Then, per file:
  - changed upstream, untouched by tau: take upstream's;
  - touched by tau, unchanged upstream: keep tau's;
  - changed on both sides: a 3-way merge (`git merge-file`), leaving conflict markers where they collide.

  Files added or deleted upstream follow. It writes the new commit into `UPSTREAM`, `npm install`s, and prints the
  conflicts, then the typecheck's and tests' results. Conflicts appear as ordinary conflict markers in ordinary files,
  committed when resolved, as one commit ("web: Web A to <commit>"). History stays linear; no vendor branch to keep.
- **Licensing.** Web A is GPL-3.0-or-later, as tau is. Its `LICENSE` stays in `web/`, the README credits it as it
  credits Telegram-iOS, and the server serves the app it was built with from this public repository, so the source is
  where the program is.

## 2. Structure inside

```
client/                     Pure TypeScript, no Node or DOM: runs in the browser, in Node and in tests
  protocol.ts               the wire types (moved from server/src/protocol.ts; the server imports them from here)
  ops.ts                    the protocol's ops, a standalone implementation, as server/src/client.ts's is, to keep
                            the spec honest
  connection.ts             one socket: requests by ID, pushes, hello with the first requests behind it, ping,
                            reconnect with backoff, wake (docs/network.md); the socket is injected (ws in Node,
                            WebSocket in the browser)
  replica.ts                a conversation's entries, holes and docs (server/src/client.ts's ConversationReplica)
  dialogs.ts                the chat list by version
  outbox.ts                 the sending state machine of docs/sending.md (ios/Tau/Server/Outbox.swift)
  store.ts                  interfaces for what persists (entries, dialogs + version, outbox), implemented over
                            IndexedDB in web/ and in memory in tests
web/src/tau/
  api/                      the connector (callApi, apiUpdate) and its methods; builders: Dialog -> ApiChat/ApiUser,
                            entries -> ApiMessage with `tau` content; the multi-server store (ios MultiStore)
  db/                       client/store.ts over IndexedDB: the entry cache, the dialog list, the outbox
  components/               TauMessage, ToolCard and its kinds, SubagentCard, the connect screen, the model picker,
                            tau's settings screens
  styles/                   tau.scss: tau's theme over Web A's
  strings.ts                tau's strings, beside Web A's lang packs
```

- **`client/` is the reference client made a package.** `server/src/client.ts` already holds the state machine the iOS
  app implements. Moving it into `client/` gives the web app, the server's tests and a CLI one implementation, tested
  once with `node:test` as the server is. `ios/Tau/Server` stays its Swift twin: changes to either are made in both,
  and docs/network.md and docs/sending.md describe both.
- **Durable's `ConversationTranscript` is not used.** It merges durable's own watch views (`ConversationView`) and pages
  through an `EntryLoader`. tau's protocol has its own subscribe, `history` and `gap`, and `client/replica.ts`'s holes
  are the same idea in tau's terms (100 lines today). Chord's delta code is not used either: the protocol's op format
  is Chord's, but the client applies ops itself, as `server/src/client.ts` does on purpose. Neither would bring the
  rest of vendor/pi into the browser bundle anyway.
- **`web/src/tau/api` builds Web A's state; it does not keep tau's.** Entries and docs live in `client/`. The builders
  turn them into `Api*` objects and `apiUpdate`s, as GramJS's builders turn MTProto's. Rules from the proof of concept:
  - a message ID's content changes only through `updateMessage` with `isFull`;
  - the chat list's last message is built from the cached entry, never the Dialog's summary unless nothing is cached;
  - streaming goes through Web A's typing draft, which carries `tau` content too;
  - tau's own fields go in one optional `ApiMessage.tau`, while `content.richMessage` is still filled for previews,
    copy and search.
- **IDs.** A private chat is keyed by its peer, so each conversation is a user of its own. Several servers are told
  apart as in iOS's MultiStore: the server's slot in the high bits of a conversation's ID, under Telegram's 2^52.
- **Removed vs dormant.** Nothing of Web A's source is deleted.
  - GramJS (`src/lib/gramjs`, `src/api/gramjs`) is dormant: nothing imports its worker once the connector switches,
    and the build leaves it out.
  - Calls, stories, payments, stars, gifts, the wallet, bots and mini apps, stickers, GIFs and premium are dormant:
    unreachable once their entry points (menu items, buttons, header actions) are behind `IS_TAU` (`src/config.ts`).
  - Deleting a file would be a divergence to carry through every update; an unreachable one costs nothing.
  - What is cut is in the build output: emoji images (native emoji, which Web A supports), statistics and source maps
    in a release, and Telegram's name, logos and icons, which tau's own assets replace (a trademark, not ours to ship).
- **The rule for touching Web A's files.** Only where there is no other way in: a one-line hook at an entry point, which
  calls code in `src/tau`.
  - Each edit is marked with a `tau:` comment that says why (`// tau:` in TS, `{/* tau: */}` in JSX, `// tau:` in SCSS).
  - Nothing is reformatted.
  - Whole replacements are new files in `src/tau`, reached through an alias or a hook, never edited copies.
  - `scripts/web/upstream-diff.sh --check` (in `scripts/web/test.sh`) fails on a changed hunk without a `tau:` mark,
    and prints how many upstream files differ: a number to keep small (13 in the proof of concept).
  - Theme colors override Web A's with `!important`, because Web A sets them inline on `<html>`; that is in
    `tau.scss`, not in Web A's styles.

## 3. Serving and connecting

**Decision: the server serves the built app on its own port.** The page, the WebSocket and `/files` share one origin.
Static files need no token: the app holds no data. `index.html` has `Cache-Control: no-cache`, and hashed assets are
immutable. `--web <dir>` names the build (by default `web/` beside a release's bundle); `--no-web` turns it off. Any
path that is not a file, a WebSocket upgrade or `/files` gets `index.html`. The server sets a strict
Content-Security-Policy itself (`script-src 'self'`, `connect-src` its own origin and the servers the user adds).
Alternatives:

- a separate static host (GitHub Pages, Cloudflare), which makes every connection cross-origin and splits a release;
- a dev server only, which is not a product.

**The token.** A browser cannot set headers on a WebSocket, and `/files` URLs in `<img>` cannot carry them either.

- **Getting it.** A connect screen, in place of Web A's login, takes a server address (this origin by default) and
  its token. `tau setup` also prints a link, `https://<host>/#token=<token>`: the fragment never reaches the server or
  its logs, and the app reads it, stores it and removes it from the address bar.
- **Keeping it.** In IndexedDB, one per server.
- **Sending it.** On the WebSocket, in `Sec-WebSocket-Protocol` (`tau.v1`, `tau.token.<token>`), which `verifyClient`
  reads, answering with `tau.v1`: a small server change, which keeps the token out of URLs, proxies' logs and
  history. The web app never uses `?token=`; the server keeps it for the clients that use it today. Files are
  fetched with `fetch` and an `Authorization` header (Web A loads media through `callApi('downloadMedia')` anyway,
  which returns blob URLs), and cached in Cache Storage.
- **Not cookies.** An HttpOnly cookie would keep the token from a script injected into the page, but would not stop
  that script from using the socket, which is as bad (section 7). It would also work for this origin only, not for a
  second server, and would need CSRF and Origin checks on the WebSocket.

**Secure contexts only.** The app runs where the browser treats the page as a secure context: HTTPS, or `localhost`
and `127.0.0.1`. Away from those, a plain HTTP page has no service worker (so no offline shell, no Web Push), no
`crypto.randomUUID`, no `navigator.clipboard` writes. One app, not a full one and a reduced one, is one app to test.

- **HTTPS through `tailscale serve --bg 7878`**, which gives `https://<machine>.<tailnet>.ts.net` with a real
  certificate and nothing to configure in tau. `tau setup` prints that address when Tailscale runs.
- **Plain HTTP from another machine** gets a page, served before any of the app loads (`index.html` checks
  `window.isSecureContext`), that says why the app does not run there and how to set up HTTPS: the `tailscale serve`
  command, with this machine's tailnet name when the server knows it. The server itself is unchanged: it still
  serves plain HTTP, for the iOS app and for `tailscale serve` to proxy.
- **Not chosen:** TLS in the server (`--tls-cert`, `--tls-key`, e.g. from `tailscale cert`), only if there is a need
  `tailscale serve` does not meet.
- The page's scheme decides the socket's: `wss:` under HTTPS, `ws:` on localhost.

**Several servers**, as the iOS app has them. Settings > Servers adds a server by address and token. The app connects
to each, cross-origin for all but the one that served it. That needs:

- the token sent the same way everywhere (above);
- CORS on `/files` (`Access-Control-Allow-Origin` echoing the origin, `Authorization` allowed), since the bearer token,
  not a cookie, is what authorizes;
- the serving server's CSP listing the servers added (a `connect-src` the app asks the server to extend, or `https:`
  and `wss:` on a tailnet).

One server comes first; the IDs leave room for several from the start.

## 4. Tests, fast

| Layer | Runner | What | Target |
|---|---|---|---|
| `client/` | `node:test`, as the server's tests | replica, holes and resume, ops, the dialog list by version, the outbox state machine with a fake connection and store, against the protocol's examples | < 2 s |
| `web/src/tau` | Vitest (Web A's runner, with its Vite transforms and jsdom) | builders: entries and docs to `Api*` objects (each tool's card, thinking, subagents, the run's end, streaming drafts); the IndexedDB store over `fake-indexeddb` | < 5 s |
| end to end | Playwright, headless Chromium (WebKit for Safari before a release) | the built app, served by a dev tau server with the dev model, driven as a user: open, read, send, steer, stop, edit, search, files, reconnect | smoke < 60 s, all < 3 min on 4 workers |
| look | Playwright screenshots | baselines per theme of fixed transcripts; layout assertions in iOS's points | in the e2e run |
| static | TypeScript 7 (`tsc` from the server's devDependencies) over all of `web/` and `client/`; ESLint and Stylelint on `src/tau`, `e2e/` and the files `upstream-diff` lists | | < 10 s |

- **End to end, isolated.** Each Playwright worker starts its own server, as `ios/scripts/uitests.py` gives each
  simulator one: `--memory`, a port from `TAU_WEB_PORTS` (default 7960 to 7967, apart from iOS's 7979 and 7991 to
  7995), `--model dev/echo`, a fast `--dev-tps`, and `TAU_DEV_ANSWERS` for scripted answers. Each serves the same
  build. Tests make their own conversations, so a worker's tests share a server; a test that stops or wipes it has a
  worker of its own.
- **They wait on state, not time.** As `-uiTesting`'s `chatState` does on iOS, the app marks the open chat
  `data-tau-chat-state="loading|busy|idle"` (in tests only), and helpers wait on it. Web A's animations are turned off
  in tests (its "no animations" setting).
- **The iOS look is checked in two ways, neither of them a pixel comparison with iOS** (the fonts differ: SF Pro there,
  Roboto here):
  - Layout assertions read the DOM: a 16 px text inset, 17 px answers, line height, a card's radius and padding, the
    gaps between rows, against `ChatMessageItem.swift`'s numbers.
  - `scripts/web/compare.py` puts the iOS UI tests' screenshots (`/tmp/tau-ui`) beside the same transcripts on the web,
    for review when the look changes.

  Web A's own Roboto is bundled, so baselines are the same on any Linux.
- **Typecheck everything, lint only tau's.** TypeScript 7 checks Web A's code in 5 s; the one complaint it has is fixed
  by a `tau:` edit or excluded. Web A's ESLint setup is slow and opinionated about Web A's own code; it runs on tau's
  files and the edited ones only.

## 5. Workflows

One command each, from the repository root:

| Command | Does |
|---|---|
| `scripts/web/dev.sh` | A dev tau server (`--memory` or `--db /tmp/tau-web-dev.db`, port 7990, `dev/echo`, `--watch`) and Vite's dev server with hot reload on 1234. Vite proxies the WebSocket and `/files` to the server, so dev is same-origin as production. Ctrl-C stops both. `--model`, `--port`, `--db` pass through. |
| `scripts/web/test.sh` | Static checks, then `client/` and `web/src/tau` unit tests, then the e2e smoke. `--all`: every e2e test. `--update-screenshots`. Used before every commit that touches `web/` or `client/`. |
| `scripts/web/build.sh` | `vite build` into `web/dist` (gitignored), without emoji images, statistics or source maps. |
| `scripts/build-release.sh` | As now, plus the web build copied into the release as `web/`. `check-release.ts` also fetches `/` and an asset from the started server. One tarball (2.3 MB today, about 8 MB with the app), so a server always serves the app built for its protocol. |
| `scripts/release.sh` | Unchanged: publishes that tarball. |
| `scripts/web/update-upstream.sh [commit]` | Takes Web A's upstream to a commit (by default the tip of its master), as in section 1, and runs the tests. |
| `scripts/web/upstream-diff.sh` | tau's edits to Web A's files as a diff against the pristine commit; `--check` fails on an unmarked hunk. |

- **Install.** `scripts/setup-pi.sh` as now, then `npm ci` in `web/` and in `client/`. `scripts/web/dev.sh` runs
  `npm ci` itself when `package-lock.json` is newer than `node_modules`.
- **Upstream updates.** About monthly, and before a release that needs an upstream fix. Each takes one commit:
  1. run the update script;
  2. resolve its conflicts, which are in marked hunks only, so each is a hook to put back;
  3. `scripts/web/test.sh --all`, and look at `compare.py`'s images if the look changed.

  Web A releases often (12.0.48 now), so a skipped month is a bigger merge, not a harder one.
- **CI.** There is none in the repository today; `scripts/web/test.sh` is what a GitHub Actions job runs when there is.
  It needs `vendor/pi` (for the dev server) and Playwright's Chromium, about 2 minutes to set up, cached.

## 6. Scope: M0, then tau's history

**M0, scaffold (1 week).**

- `web/` vendored at a pinned commit, with the update and diff scripts.
- The proof of concept's code redone in `src/tau` by section 2's rules.
- `client/` extracted from `server/src/client.ts`.
- The server serving the build (`--web`); the connect screen with the token link; the page for plain HTTP.
- `dev.sh`, `test.sh`, `build.sh`, and the release carrying the app.
- The first e2e tests.

M0 delivers the proof of concept's read-only client, served by tau and tested.

**Then parity by walking tau's history**, not by a roadmap. tau's commits, oldest first, are the iOS app's, the
protocol's and the server's features and fixes. Each commit message says what changed and why, often what went wrong
first. Taking them in order brings each feature to the web client with the lessons it took, rather than relearning
them: the sending state machine's races (docs/sending.md), the reading position's cases, streaming's overlaps. The
web client is in the same repository, so a commit after the walk catches up does both sides at once.

- **`web/PARITY.md`, the checklist:** one line per commit since the repository began that touches `ios/Tau`,
  `server/src`, `client/` or `docs/`, in order: hash, subject, and a state.
  - `todo` (the default);
  - `done <commit>`: the web commit that brought it;
  - `skip: <reason>`: relevant, but deliberately not done now;
  - `n/a: <reason>`: nothing for the web to do, e.g. an iOS layout fix to Telegram's ListView, a server-only change,
    or a docs fix.
- **`scripts/web/parity.sh`** appends the commits not yet listed, as `todo`, and prints the count per state. A run
  after each `git pull` keeps the list current, so the walk never ends while tau changes: new iOS work becomes web
  work in the same list.
- **Granularity.** One line per commit, but a web commit may close several lines (a feature that took five iOS
  commits is usually one web commit, with the lessons of all five); each line then says `done` with the same commit.
- **What a web commit does:** the behavior and its lessons, in Web A's terms. It is not a port of the Swift: where
  Web A's machinery already does a thing (scrolling, date groups, context menus), the line is `done` once the web
  client behaves as the commit says, or `n/a` if Web A did so already.
- **Tests come with it.** A commit with an iOS UI test or a server test gets its e2e or unit counterpart when the
  behavior is the web's too.

The walk covers what a roadmap would have listed (sending and the outbox, the entry cache and resume, every tool card,
subagents, the model picker, reading position, search, files, links and quotes, edits and forks, several servers,
settings, appearance), in the order tau built them. Things with no web counterpart are `n/a` when their commits come
up: Live Activities, Siri intents, the share extension's own target (the web's is a Web Share Target, taken with the
share extension's commits), Telegram-iOS vendoring. Web-only work (an installable PWA, Web Push from the server, the
tab's badge, keyboard shortcuts) is done where the matching iOS commit comes up: notifications with the APNs commits,
the badge with the Live Activity's.

## 7. Risks

- **Model output in the page.** Answers and tool output are untrusted text in a page that holds a token to a shell. One
  injected script is a remote shell.
  - Web A renders through its own virtual DOM, but has `dangerouslySetInnerHTML` paths (emoji, some text helpers).
  - Mitigations:
    - a strict CSP from the server, without `unsafe-inline` for scripts;
    - tau's content rendered only through `RichContent`, with links' schemes checked;
    - an audit of the `innerHTML` paths reachable from tau's content;
    - e2e tests that send hostile Markdown and HTML.
- **Upstream churn.** Web A is large and moves daily. A hook in `MessageListContent`, `Composer` or `HeaderActions`
  conflicts when those change. Kept small by the rule in section 2 and by monthly updates; the measure is the number
  of diverged files, printed by every test run.
- **Web A's assumptions.** Each of these needed a workaround:
  - message IDs whose content never changes;
  - local IDs as fractions;
  - a typing draft's 10 s TTL (`appConfig.typingDraftTtl`), which drops a draft when a long tool call sends nothing;
  - global state cached only for a Telegram session.

  More will appear with sending and editing, and each workaround is a place where an update can break behavior
  without a conflict. The e2e tests are the guard.
- **Teact.** Web A's own React-like library, with its own rules (measure/mutate phases, `withGlobal`, signals). Its
  AGENTS.md documents them; tau's components follow it.
- **Secure contexts.** The app needs HTTPS away from localhost, so a user without Tailscale (or another way to put TLS
  in front of the server) cannot use it remotely. The page for plain HTTP has to make the fix obvious; TLS in the
  server is the fallback if this proves a barrier (section 3).
- **Branding.** Web A is full of Telegram's name, logos and strings, fetched from Telegram's language packs at
  runtime (`fetchLangStrings`, unanswered now, which leaves the bundled fallback). tau needs its own assets and
  strings, without forking the language system.
- **Size.** Web A's build is large: 7.4 MB of JavaScript before compression, with heavy chunks. Lazy loading tau's
  Markdown path (tiptap was pulled into the initial chunk in the proof of concept) and leaving dormant features out
  of the initial chunks matters on phones.
- **Two clients to keep alike.** iOS and web implement the same client (outbox, replica, reading position) in two
  languages. `client/` and docs/network.md and docs/sending.md are the shared truth; e2e tests mirror the iOS
  UI tests' scenarios. `web/PARITY.md` keeps the walk honest: a commit is never silently left out.
- **The walk's length.** 221 commits today, many large. Most iOS layout fixes are `n/a` (Web A's machinery differs),
  but feature commits take time and the order is tau's, not the most useful first. If a first usable client is
  needed sooner, the walk can take sending and the entry cache first and mark what it skipped.
