# To do

## Editing a message forks a second chat

Editing a user message forks the conversation before it (`conversation.fork`) and opens the fork; the original stays,
so the list shows two chats of the same title, one more for every edit, with nothing linking them
(`ServerStore.editResolved`, docs/sending.md "Edits and drafts"). Editing the first message makes a new conversation.

This is durable's model: a conversation is one linear, append-only transcript, and the only way to go back and continue
differently is a fork, a new conversation that sees its parent up to an entry (durable README "More Conversations and
Forks"; `test/examples/08-harness-conversations.ts` calls its fork `retry`). Durable records the parent and `parent.at`;
tau's Dialog does not pass them on. `edits` (replace or omit) change what the model sees from then on, in the same
conversation, without going back; `head` only cuts what comes before. pi's coding agent differs: a session is a tree,
and `/tree` continues from an earlier point in the same session, so its list keeps one; only `/fork` makes another.
docs/sending.md says pi's `/tree` works the same way as tau's edit, which is not right.

To decide: how an edited chat and its versions show in the list, for example one row per lineage, showing the newest
version, with the earlier ones reachable from the chat.

## Compress requests to Anthropic

Every turn sends the whole conversation again; Anthropic's API takes it gzipped (`Content-Encoding: gzip`, gzip only:
zstd, br and deflate are refused), and text compresses to a seventh or so (images, already compressed, hardly: about
three quarters, which is the base64 coming back). Claude Code does it since 2.1.300 for bodies over 512 KB, reusing the
compressed blocks of the unchanged prefix each turn (`CLAUDE_CODE_GZIP_REQUEST_BODIES`). It belongs in pi-ai's Anthropic
provider (its SDK takes a `fetch`), as a PR upstream: none is open (October 2026). The Codex provider already sends only
what is new over its WebSocket (`previous_response_id`), and zstd over SSE.

## An offline edit's fork may be missing from the list

Seen once: after editing a message while offline and restarting the app, the fork the edit made did not show in the
chat list. Not looked into yet. Start with how `ServerStore.editResolved` and the outbox's pending create live through a
restart.

## Sharing files from the share extension, on the phone

The share extension uploads files (`ShareSender.send(... files:)`; `Info.plist` takes files and movies). The UI tests
cover the app's files; sharing a PDF or a video from another app has not been tried on the device.

## Widgets and share extension profiles

The provisioning profiles of the widgets and share extensions (`$(TAU_BUNDLE_ID).widgets`, `.share`) expire on
October 29, 2026. To check they are the current ones, and make new ones before then.

## Archived Chats goes blank

Unarchiving the last archived chat leaves the Archived Chats page blank, instead of closing it or showing it empty as
Telegram does.

## Blurry thumbnails

Photo thumbnails in chats look blurry: check the size they are fetched and decoded at against the pixels they show
in.

## Tests not run lately

Shard 1's last run left 25 tests unrun; `testEditQueued` and `testMoveToSteer` are to run again too.

## Seal the Live Activity's pushes

An answer's push is sealed for the phone (docs/notifications.md "Sealed"), but a Live Activity's are not: ActivityKit
decodes their content state itself, with no notification service extension in between, so the chats' titles and steps
go to the push relay, and Apple, in the clear. This covers the Lock Screen, the Dynamic Island and the watch, which all
show the same content state.

The widget extension draws the activity from that state, so the server can put ciphertext in it (as a string field
`sealed` beside a placeholder `chats`) and the extension open it while drawing, with the key from the shared keychain
(`ShareGroup.existingPushKey`). For that, TauWidgets needs the keychain group (an entitlements file, new profiles). The
`alert` of an update or a push-to-start is shown by the system and cannot be sealed: a fixed text instead ("tau",
"Answered"). To check: drawing on the Lock Screen while locked (the key is AfterFirstUnlock), and on the watch, which
the phone draws for.

## A flaky Live Activity test

`test/push.test.ts` "a chat in a Live Activity: its finish updates the activity…" fails about one run in three to
seven, from before the push relay too: "the done row stays a while", a second `liveactivity` push within 100 ms of the
first, where the done row should stay 500 ms (`activityDoneLifetimeMs`). Not looked into: which push the second is.

## Maybe

- A second server for someone else, from the template unit `tau-server@.service`.
- Checking production pushes (TestFlight builds use the production APNs environment).

## Later

- Aqua dictation: more robust.
- Opening a chat: part C (A and B are done).
- Emoji showing as boxes on a Linux server.
- Keep Cache: turning itself off.
- Folders.
- Titles from a small model: `Titler` (src/titles.ts) names a chat with the chat's own model, Opus as well.
- Dynamic Type for tool cards.
- Streaming text that may overlap: seen, not confirmed.
