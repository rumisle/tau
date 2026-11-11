# The web client

The plan for tau in a browser: Telegram Web A (github.com/Ajaxy/telegram-tt, GPL-3.0-or-later) as the UI, as the iOS
app takes Telegram-iOS, with a data layer of tau's own written the Telegram way. M0 is built (section 6, "M0 as built");
parity comes by walking tau's history. A proof of
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
scripts/web/              tau's: dev.sh, test.sh, build.sh, upstream.ts (import, update, diff), parity.sh
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
  upstream commit is the record of tau's edits (`node scripts/web/upstream.ts diff` prints it), so there is no second
  copy to drift.
- **Taking an update** (`node scripts/web/upstream.ts update [commit]`): fetch upstream's old and new commits into a
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
  protocol.ts               the wire types a client reads (the server keeps its own, with its validation)
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
  - streaming goes through Web A's typing draft, which carries `tau` content too; the entry's `newMessage` removes it
    (Stopped is for a generation that ends without one: after the entry it would draw the answer twice for a second);
  - tau's own fields go in one optional `ApiMessage.tau`, while `content.richMessage` is still filled for previews,
    copy and search.
  - the chat list's last messages go as `updateChatLastMessage`, not in `fetchChats`' result: `loadAllChats` puts a
    result's messages over those Web A has, a while after, undoing what a chat that opened meanwhile put there; and
    again once Web A is synced, as its sync drops the messages it had (`resetMessages`) after its first batch;
  - read states go as `updateThreadReadState` (Web A takes none from `updateChat`): unread counts, and the two checks
    of a user's message, which the agent has read once it is in the transcript.
- **Sending is the outbox's** (`client/outbox.ts`, docs/sending.md's rules). Web A's `sendMessage` call enqueues; the
  bubble is a local message (a fraction above the chat's last ID) with Telegram's clock, one check once queued, the red
  badge when refused, and `updateMessageSendSucceeded` when its entry comes, matched by text before the record if need
  be. The outbox lasts in IndexedDB, one per tab (`db/outbox.ts`): each tab holds a Web Lock, and a tab that opens
  adopts the outboxes of tabs gone, so a reload or a crash sends what was left. New Chat (Web A's New Message button,
  without its menu) is a draft chat with an ID of its own, not listed, whose messages wait in the outbox for the
  conversation's create; once created, the conversation opens in its place.
- **Stop is Web A's Stop for a bot's streamed answer.** The chat's typing status carries `tauRun` while its own run
  works; the composer shows Stop for it unless the field has text (Send steers then); Stop withdraws the queued messages
  back to the field and aborts the run. Its `tauText` is what the title and the chat list say in Telegram's typing
  place, as iOS's title does: "working" for its own run, "reader working" or "2 subagents working" while only background
  subagents (at any depth, titled "name: task") work. **The queue** (`components/QueuePanel.tsx`, `api/queue.ts`): while
  the agent works, messages wait above the field in Web A's embedded-message bar, where a reply shows, not in the chat:
  Steer or Follow-up, the first one's text, the clock or a check, the pinned bar's segments for several; this device's
  and other devices' (`pi.inbox`). × withdraws one; a click or a right-click opens Edit, Send as Follow-up or Steer,
  Send Now, Delete (a submenu each when several). Send's menu is a right-click on Send while the agent works (iOS: a
  long press): Send as Follow-up, Stop and Send; Web A's Send Without Sound and Schedule are left out. After a failed
  run the queue is held (`isQueueHeld`: a `runFailure`, no run): "Follow-up, waits for your next message", and the chat
  is not busy (no Stop, no working); the next message, or Retry, starts a run that takes it first.
- **The τ while the agent works and has written nothing** (`components/WaitingTau.tsx`, iOS's ChatWaitingNode): a
  typing draft whose only part is `waiting`, sent while the run is on and no call runs; the answer then streams in the
  same draft (`streamsIn` maps its generation's draft ID to the τ's), and it is sent again every 5 s against Web A's
  draft expiry. The run is the server's, so the τ shows only once the server has the message.
- **A message sent goes to the top; the web differs from iOS here, at the user's choice** (`liveTail.ts`, in Web A's
  `MessageList`). As ChatGPT does, and Web A for a bot's streamed answer: the user's message goes to the top of the
  view and the answer grows below it, past the screen without moving it; the user scrolls. iOS stays at the bottom
  and follows the answer (docs/reading-position.md). Web A starts its live tail at an incoming typing draft, which in
  tau comes late or not at all (a call runs first, the τ waits for the server); tau starts it at the user's message,
  sent here (focused wherever the view was) or on another device (when the view is at the end), and keeps it through
  the τ, streaming, calls and reconnects until a newer message is sent. A draft's first frame does not scroll to its
  end, and an answer that outgrew the view leaves it where it is. A chat opened mid-run opens at its end. The reading
  position's other parts apply in their desktop form, below.
- **The reading position, desktop** (docs/reading-position.md; `readingPosition.ts`, one hook in Web A's
  `MessageList` and its opening scroll, `reading.ts` for what is kept in localStorage):
  - *Seen* is on screen with the tab visible: the frontier (the newest message on screen and how far down it) moves
    as rows are laid out in view, never back; the server reads the newest entry seen (`seenThrough`, at most every two
    seconds), and the open chat's row counts the answers after it that were laid out when it was measured, so an
    answer that lands on screen never shows a count, and one below the view does until it is scrolled to.
  - *Where a chat opens*: the view left (the message at the bottom of the screen and how much of it was above the
    bottom), at the end too, then down so the last lines seen sit near the top when what follows them is unseen,
    judged on the frontier from before it opened, again as the subscribe brings what came since unless the user
    scrolled. A chat never left here opens as Web A opens it. No "new messages" divider.
  - *Turns*: Mod+Up (Cmd on a Mac, Ctrl elsewhere; Web A's own use of it, reply to the previous message, means
    nothing in tau) goes to the start of the turn above, a message of the user's, pushing the view it left from;
    the down button and Mod+Down go back to the last such point, else to the end; Mod+Shift+Down to the end. A point
    whose row is on screen again is dropped once a jump ends (Web A's scroll animation, which its bottom snap needs).
    A field with text keeps its own Mod+Up and Down. iOS's status bar tap and haptics have no desktop form.
- **Compaction shows as it goes** (iOS's service rows): while one runs, a pill over the end of the chat above the
  field (`components/CompactionPill.tsx`, in the queue's place, so Web A's composer has no other hook) with the τ and
  its time, the title "compacting for 12s" and the ⋯ menu's Compacting Context… disabled; the chat goes on meanwhile.
  Its time is the server's record's start (`tau.compactions`), else when this page first saw it. Then the summary as a
  card on Telegram's service fill (`components/CompactionCard.tsx`), folded with a fade until clicked; its right-click
  menu's Restore Full Context opens a fork draft from before it (`restoreFullContext`), created by its first message.
  One that ended unused stays as a small note on the service fill after the entry where the chat was then (a row of
  that entry's, never the chat's last message nor unread): "Compaction not used: the chat moved on", "Compaction
  failed: 400: prompt is too long", "Nothing to compact". A failure that comes in a live commit while the chat is open
  says so once, as a toast in words (`compactionError`); one a subscribe's snapshot brings (an open, a reconnect, a
  reload) stays quiet.
- **Subagents** are listed in the ⋯ menu (avatar, working for or worked how long, the task); a row, or a subagent's
  card, opens its conversation: sent to Web A unlisted (`openConversation`), its title and work kept up to date.
- **The page is tau's**: the title "tau" (Web A's `APP_TITLE` default), the iOS icon's τ on pink as favicons, Apple's
  touch icon and the manifest's (`public/tau`, made by `scripts/web/icons.mjs`; `tau.webmanifest`), with Web A's
  unread swap (`favicon` to `favicon-unread`) kept.
- **Model errors as pi has them** (iOS's ModelErrorText; `api/modelErrors.ts`): a failed attempt the server asks past
  does not show (`errorState`: retried, pending while the run goes on, or the run's end, shown then by `flushErrors`);
  meanwhile the τ says "retrying in 5s (attempt 3): overloaded" from `pi.live.generation`; the answer's footer says
  "retried 2 times"; an error the run ends on is a card, "The model failed" and the provider's message, with Retry
  (also in its right-click menu), which sends the message before it again.
- **Search is the servers'** (docs/search.md; `searchChats`, `searchMessagesGlobal`, `searchMessagesInChat` in
  `api/methods.ts`): the chat list's field finds chats by title at once, then messages, every server asked and their
  pages merged by score, each its conversation's best part; a result is the chat's own row when its replica is loaded,
  else the server's excerpt, which the row replaces as the chat opens. A chat's search is Web A's (its list of matches,
  Up and Down), without a jump to a date. Found words are marked in tau's rows with the CSS Custom Highlight API
  (`components/searchHighlight.ts`), Web A's bubbles (with the chat list's query too) and results by Web A, both in
  tau's pink; Telegram's tabs, its strip of chats and its "All chats" filter are hidden. An empty search lists the
  chats found before, then the most recently active (`recentChatIds`).
- **An answer is a system notification** (docs/notifications.md "On the web"): tau's, decided on the chat list when a
  run ends, in place of Web A's per message; Settings > Notifications is tau's (`components/NotificationSettings.tsx`).
- **Usage** (`components/UsageSettings.tsx`, `api/usageReport.ts`; iOS's UsageController) is Settings' row in place of
  Web A's Privacy and Security: 7, 30 or 90 days of every server's `usage.report` merged; the overview (spent, tokens,
  answers with their change from the span before, chats); the days as a stacked bar chart by model in Telegram's
  series colors, cost or tokens (tokens first when nothing cost anything), a day shown on hover and kept on a click;
  the models with their share, the costliest chats, which open on a click.
- **Data and Storage is tau's** (`components/DataSettings.tsx`, in place of Web A's auto-download settings): the bytes
  of unsent messages (the outboxes and their files in IndexedDB) and drafts (localStorage), and Network Usage, the
  socket's frames per server since Reset Statistics (`api/usage.ts`, one count: a browser does not say whether it is on
  Wi-Fi), with Chat History (the entry cache) and Clear Cache, which drops the chats' entries, not the list.
- **Chats open at once from what the browser has** (docs/chat-open.md, docs/network.md; `db/entries.ts`, iOS's
  EntryCache): each server's chat list with its version, and each opened chat's newest 300 entries, in IndexedDB a
  second after they change, by the server's own conversation IDs. A page loaded with a list kept starts with it, its
  header saying "connecting" (Web A syncs its list while it connects: two `tau:` edits); a chat with entries kept
  opens with them, and its subscribe (`after` its newest) brings what came since as new messages; with none kept, the
  newest 100. More missing than that (a `gap`) drops what was kept, here and in Web A, rather than show a hole; older
  pages (200) come from the server as Web A scrolls up to the oldest entry (`fetchHistory`). The list subscribes with
  `since` its version. Another database (`hello.serverId`) drops everything kept, and a page that showed it reloads.
  Docs (`pi.live`, `tau.compactions`) are never kept: a compaction's note shows once the chat is subscribed.
  The top 30 chats of the list (pinned first; not archived, subagents' or working ones) are kept up to date in the
  background, a second after the list changes, one at a time, with `conversation.history` after their newest kept
  entry, without subscribing; Web A's own preload, which would subscribe 20 chats, is off. **Waking:** the page shown
  again after 40 seconds or more, or the browser back online, replaces each socket at once; after less, a socket that
  does not answer within 3 seconds is replaced; a wait for a backoff is cut short. A fork with nothing kept starts
  from its original's entries up to its point, so its subscribe asks only for what came after (`seedFork`).
- **The chat's ⋯ menu is tau's** (`components/ChatMenu.tsx`, in Web A's header menu, with its nested submenus): the
  model, in a picker (`components/ModelPicker.tsx`: Web A's searchable picker in a modal of its own root, recent models
  first, Enter takes the first match), the thinking level (`api/agent.ts`: shown at once, sent in order with the chat's
  messages, believed until the `pi.agent` doc agrees, as iOS's `ServerStore.agent`), Usage (how full the context is and
  the spend, the numbers a level down, as iOS counts them: `computeUsage`), and Compact Context, never repeated after a
  lost connection. Its changes and notices are Web A's toasts, as iOS's are Telegram's: "Model changed to **…**",
  "Thinking set to **…**", "Compacting the context".
- **Rename** (`components/RenameModal.tsx`), in the chat's ⋯ menu and the chat list's: a small dialog with the title
  selected, Enter saves, Esc cancels; Web A's `updateChat` action carries it to `updateChatTitle`, so the toast's Undo
  is that action with the title before. Shown at once and believed until the Dialog agrees (`session.rename`), in the
  conversation's order through the outbox; a draft's create takes it, so a renamed New Chat is not named after its first
  answer.
- **Photos and files are Web A's media.** A user entry's attachments block names its kept files: one is a message with
  the photo or document and the caption; several an album (a message each, grouped: photos apart from files). Message
  IDs leave room for it: an entry's rows are `entryId * 32 + row`. Web A's media loader asks `downloadMedia` for
  `photo<id>` and `document<id>`, which fetches `/files/<id>` with the token (or `media.get` for an entry's image), and
  keeps it in the Cache API: files and entries never change. Sending: Web A's action hands tau the message whole (its
  text and every file, one request, as iOS sends it); photos go at most 2000 pixels as JPEG, the bytes wait in
  IndexedDB beside the outbox (`db/outboxFiles.ts`), which uploads them one by one before the submit. The attach menu
  has Photo or Video and File.
- **Read state and marks** go through Web A's own calls: its debounced `markMessageListRead` is `conversation.read`,
  Mark as Unread and Read are `conversation.mark { unread }`, Archive `{ archived }`. Web A moves a chat between its
  lists on `updateChatListType`, which a Dialog that changed its `archived` sends. The chat list's menu is iOS's in Web
  A's: Open in New Tab, Quick Preview, Rename, Mark as Read or Unread, Pin to Top, Archive, Hide (`conversation.mark {
  hidden }`, which Web A takes as leaving the chat; Telegram's Mute and Delete Chat are left out), and Pin to Top (`{
  pinned: <now> }`, so the latest pin is on top across servers; Web A orders a list's pinned chats by
  `updatePinnedChatIds`, sent as the Dialogs change, and has no limit on them here). A chat open in a visible tab reads
  what is on screen (the reading position's seen frontier, above), and its Dialogs show that meanwhile: Web A marks a
  message read only after it has been in view a while, so the server's unread count came back first and the open
  chat's row showed a badge.
- **An edit forks the chat** (docs/sending.md "Edits and drafts"): Edit in a user message's menu, or Up in an empty
  field, is Web A's edit in the field; sending it is Web A's `editMessage`, which tau takes as a fork before the message
  (`session.editMessage`): a create in the outbox with the agent the chat shows and the new text, carrying the
  original's kept files, as its first message. Until the fork exists its draft chat (an ID of its own, below New Chat's)
  shows the original up to the fork, read, and the new message with the clock, in the chat's place; then the fork opens
  in the draft's. Editing the first message is a New Chat with the chat's agent. A draft chat with messages waiting (New
  Chat's too) is in the chat list at the top, with its newest message and the clock, so the chat open is highlighted
  there; it leaves the list as its conversation comes.
- **Drafts are Web A's, kept here** (`db/drafts.ts`): Web A saves a chat's draft through `saveDraft`, which Telegram's
  server would keep; tau keeps it in localStorage per server, and gives it back with the chat list (`draftsById`), so
  the list shows Telegram's red "Draft:" and the field has it after a reload. Web A saves when the chat changes, a
  second after typing stops (ten in Web A), and as the page unloads, at once (Web A waits for a frame that never comes).
  A send clears it, as Telegram's server does. New Chat keeps one too.
- **The connection's state is Web A's**, in the chat's header (the chat list's without one): "connecting" while the
  server is away, "waiting for network" when the browser is offline (Web A says the latter for both:
  `hooks/useConnectionStatus.ts`), "updating" never, since a resubscribe brings what is missing at once.
- **A message's menu is tau's** (`components/MessageMenu.tsx`), on a right-click, on answers and the user's bubbles
  (Web A's `ContextMenuContainer` is left out: replies, reactions, forwarding are Telegram's): Copy, the answer's
  Markdown, or Copy Selected Text when the selection is in the message; for a message that did not go, its reason,
  Resend and Delete; one on its way can be deleted (withdrawn).
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
  - `node scripts/web/upstream.ts diff --check` (in `scripts/web/test.sh`) fails on a changed hunk without a `tau:`
    mark, and prints how many upstream files differ: a number to keep small (13 in the proof of concept, 16 in M0).
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

Built so (`api/servers.ts`, `components/ServersModal.tsx`): Servers, in the main menu, lists this page's server and
those added, with their status as Telegram's proxy list says it ("Connected, ping 42 ms", the ping `/auth`'s time); Add
Server takes an address and a token, which `/auth` must take; a right-click removes one (its chats leave the list). The
session keeps a link per server: its socket, chat list, outbox (in IndexedDB per origin) and models. Conversation IDs
become global on each socket (a server's slot above bit 40, as iOS's MultiStore; the first server's IDs are its own), so
the replicas, the outbox and Web A's chat IDs need no server beside them; a kept file's media ID carries its slot. New
Chat goes to the server used last; the New Message button's right-click picks another. The server answers CORS on
`/auth` and `/files`; its CSP already lets the page connect anywhere.

## 4. Tests, fast

| Layer | Runner | What | Target |
|---|---|---|---|
| `client/` | `node:test`, as the server's tests | replica, holes and resume, ops, the dialog list by version, the outbox state machine with a fake connection and store, against the protocol's examples | < 2 s |
| `web/src/tau` | Vitest (Web A's runner, with its Vite transforms and jsdom) | builders: entries and docs to `Api*` objects (each tool's card, thinking, subagents, the run's end, streaming drafts); the IndexedDB store over `fake-indexeddb` | < 5 s |
| end to end | Playwright, headless Chromium (WebKit for Safari before a release) | the built app, served by a dev tau server with the dev model, driven as a user: open, read, send, steer, stop, edit, search, files, reconnect | smoke (`@smoke`, `test.sh smoke`) < 15 s, all < 30 s on 12 workers |
| look | Playwright screenshots | baselines per theme of fixed transcripts; layout assertions in iOS's points | in the e2e run |
| static | no middle dot in tau's copy (iOS's house style); TypeScript 7 (`tsc` from the server's devDependencies) over all of `web/` and `client/`; ESLint and Stylelint on `src/tau` and the files `upstream.ts diff` lists; `web/e2e` by its own tsconfig | | < 10 s |

- **End to end, isolated.** Each Playwright worker starts its own server, as `ios/scripts/uitests.py` gives each
  simulator one: `--memory`, a port from `TAU_WEB_PORTS` (default 7960 to 7975, apart from iOS's 7979 and 7991 to
  7995, the dev servers' 7990 and 1234), `--model dev/echo`, a fast `--dev-tps`, and `TAU_DEV_ANSWERS` for scripted
  answers. 12 workers (`TAU_E2E_WORKERS`). Each serves the same build, or with `--dev` passes the app's requests to
  one Vite dev server (`--web-dev`). Tests make their own conversations, so a worker's tests share a server; a test
  that stops or wipes it has a worker of its own.
- **They wait on state, not time.** As `-uiTesting`'s `chatState` does on iOS, the app marks the open chat
  `data-tau-chat-state="loading|busy|idle"` (in tests only), and helpers wait on it. Web A's animations are turned off
  in tests (its "no animations" setting). A run that must still work when the test acts holds on `api.gate()`, a
  command that waits for a file the test writes, not on a `sleep`, which a slow page load outlasts.
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
| `scripts/web/dev.sh` | A dev tau server (`--db /tmp/tau-web-dev.db` or `--memory`, port 7990, `dev/echo`, restarted by `node --watch`) and Vite's dev server with hot reload on 1234, which proxies `/socket`, `/auth` and `/files` to the server, so dev is same-origin as production. Ctrl-C stops both. `--port`, `--web-port`, `--db`, `--memory`, `--model`; other options go to the server. |
| `scripts/web/test.sh` | Static checks, `client/` and `web/src/tau` unit tests, then the e2e tests, building the app first when its sources are newer. `scripts/web/test.sh unit e2e -- -g transcript` runs some steps and passes options to Playwright. `e2e --dev` (or `smoke --dev`) tests Vite's dev server instead of a build: no build, an edit is in the next run; it starts one on 1234 without hot reload, and leaves it running. |
| `scripts/web/build.sh [dir]` | `vite build` into `web/dist` (gitignored) or `dir`, without emoji images (the system's are used) or source maps. |
| `scripts/build-release.sh` | As now, plus the web build copied into the release as `web/`. `check-release.ts` also fetches `/` and an asset from the started server. One tarball (2.3 MB today, about 8 MB with the app), so a server always serves the app built for its protocol. |
| `scripts/release.sh` | Unchanged: publishes that tarball. |
| `node scripts/web/upstream.ts update [commit]` | Takes Web A's upstream to a commit (by default the tip of its master), as in section 1. |
| `node scripts/web/upstream.ts diff` | tau's edits to Web A's files as a diff against the pristine commit; `--check` fails on an unmarked hunk, `--stat` lists the files. |
| `scripts/web/parity.sh` | The history walk's checklist, `web/PARITY.md` (section 6). |

- **The iteration loop.** While working on a change, run the specs it touches against the dev server, and smoke when
  it touches sending or the chat list: `scripts/web/test.sh e2e --dev -- queue.spec.ts` (9 s for a spec; the whole
  suite is slower that way, 38 s, as each page loads Web A's modules one by one). Run the whole `scripts/web/test.sh`,
  on the build, once before a commit series is done or reported, and loop a flaky spec there
  (`-- --repeat-each 20 <spec>`).
- **Install.** `scripts/setup-pi.sh` and `npm ci` in `server/` as now (which links `client/`). The web scripts run
  `npm ci` in `web/` themselves when its `package-lock.json` is newer than its `node_modules`, and in `web/e2e`
  when it has none; Playwright's Chromium comes with `npx playwright install chromium` once. `vendor/telegram-tt`
  (for `upstream.ts diff --check` and updates) is fetched by the first `upstream.ts` command that needs it.
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

**M0 as built**, where it differs from the plan above or taught something:

- **`client/`** has the connection (on any WHATWG socket; `server/src/client.ts` runs it on `ws`), the replica, the
  chat list by version, ops, and the wire types a client reads (`client/src/protocol.ts`; the server keeps its own
  with its validation). The outbox and the persistence interfaces come with the history walk's sending and cache
  commits. Node resolves `tau-client/*` through a `file:` dependency, Web A through a tsconfig path.
- **`web/src/tau`**:
  - `api/`: `connector.ts`, `methods.ts`, `session.ts` (the state over tau-client), `builders.ts`, `markdown.ts`,
    `types.ts`;
  - `components/`: TauMessage, ToolCard, SubagentCard, Connect;
  - `styles/tau.scss`;
  - `auth.ts` (token, socket URL, `/auth`), `boot.ts` (the `#token=` link, the page for plain HTTP), `config.ts`
    (`IS_TAU`), `strings.ts`.

  Web A's edits are 16 files, 111 lines.
- **A chat not open gets its Dialog as Telegram's server sends a dialog**: `updateUser`, `updateThreadInfo`,
  `updateChat` with its read state, and the summary as `updateChatLastMessage`, never `newMessage`. A `newMessage`
  per summary made Web A take the history it had for whole, while the summaries skip entries (a tool call between
  two summaries never showed). Web A asks `requestChatUpdate` for a chat it learned of from an update; the session
  answers with the same. When a chat opens, each summary it showed is replaced by its entry's message
  (`updateMessage`, `isFull`) or removed (`deleteMessages`, for a tool's result).
- **A typing draft is numbered right without a timer.** The session sends `updateChatLastMessage` with each
  `newMessage`, so Web A's last message ID moves at once, not 350 ms later.
- **Web A asks Telegram's servers for "websync"** (`t.me/_websync_`) once signed in; it is off (`src/util/websync.ts`).
  An e2e fixture fails any test whose page asks another origin for anything.
- **Web A's `vitest.config.ts` names a setup file its repository ignores**, so tau's unit tests run with their own
  config (`web/tau.vitest.config.ts`).
- **TypeScript 7 differs from Web A's 6 in one place** (an `@ts-expect-error` it finds unused). The edit there is
  `@ts-ignore`, which both accept.
- **Tests**: the server's 117 (3 new, for the app, `/auth` and the subprotocol); `client/`'s 3; Vitest's 4 for the
  builders; Playwright's 6 (the link, the connect screen, a transcript, streaming, plain HTTP, the look's numbers).

Timings on the development machine (warm caches; a cold `npm ci` of `web/` downloads about 400 MB):

| Workflow | Time |
|---|---|
| `scripts/web/dev.sh`: both servers up | 1 s (Vite's first page load compiles Web A's modules on demand: about 10 s once) |
| `scripts/web/test.sh` | 27 s: static 2 to 5 s (with TypeScript's incremental cache), unit 2 s, e2e 22 s for 59 tests on 12 workers (47 s for 51 on 4); plus the build's 13 s when the sources changed |
| `scripts/web/test.sh e2e --dev -- <spec>` | 9 s for a spec of 5 tests; Vite starts in 1 s when it is not running |
| `scripts/web/build.sh` | 13 s; 15 MB unpacked |
| `scripts/build-release.sh` (server bundle, app, release check) | 6 s; 8.3 MB packed, 2.3 MB before |
| `node scripts/web/upstream.ts diff --check` | 0.2 s |
| `node scripts/web/upstream.ts update` | under 1 s past the fetch; a test update to the proof of concept's branch reported 10 files to resolve, each with diff3 markers |
| server tests | 47 s, as before |

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
  - `deferred: <reason>`: put off by the user, to come back to;
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
- **Desktop, not iOS gestures.** The web client is a desktop app: a commit brings what a feature achieves, in the
  desktop's form, not the iOS gesture that does it there; where Web A has the desktop behavior, it is Web A's.
  - Desktop idioms: right-click context menus; hover actions and tooltips; native text selection and copy (drag to
    select, across rows; Cmd/Ctrl+C); keyboard shortcuts as Telegram Desktop and Web have them (Enter and
    Shift+Enter, Esc, Up to edit the last message, Cmd+K); the scroll wheel; dropping files; focus that follows the
    keyboard.
  - Not brought over: long-press, swipes, tap-the-status-bar, haptics, and click-to-act on content a desktop user
    selects (a click on text places the caret or starts a selection; a code block copies from Web A's button shown on
    hover, inline code does nothing special). An iOS gesture becomes a context-menu item, a hover button or a
    keyboard shortcut.
  - `web/PARITY.md` says where a feature's desktop form differs from iOS's (`desktop:` in its line).
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
