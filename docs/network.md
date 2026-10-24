# The network

What the app sends and receives, and when. It comes from an audit of every request and op, measured through a
logging proxy between the app and the server: cold and warm launches, chats opened with and without a cache, a real
model's run, long tool output, the app sent to the background and brought back, a socket that died without a word,
200 ms of latency and a downlink of 0.5 to 2 Mbps, and the whole history of a real server. The numbers are from that
audit.

## Connecting

A connection is TCP, the WebSocket upgrade, then one round trip: the app sends `hello` and, in the same flight, what it
needs next, `dialogs.subscribe { since }` and the subscribe of each open chat (`TauConnection.onOpen`,
`ServerStore.opened`). The server answers the hello before it reads the next frame, so the app knows whether the
database is the one its cache and those requests are for before their answers come; if it is another, it ignores them,
drops the cache and asks again. Before, everything waited a round trip for the hello: four round trips to a current
chat list, now three.

A new chat's first message is still two round trips (the create, then the submit), and an edit's too (the fork, then
the submit): putting the message into the create would save one, at the price of the sending state machine's create
and submit order (docs/sending.md).

## Staying connected

- **The app** pings every 15 seconds and takes a socket without a pong in 10 for dead.
- **The server** closes a socket it heard nothing on for 45 seconds, and pings every 15 so a client that only answers
  pings stays (`server/src/server.ts`). Bytes of a frame still arriving count. Without this a phone that lost its
  network while tau was open stayed "in the foreground" on the server until its dead TCP connection timed out, which
  with nothing to send on it is never, and the server held every push back meanwhile (docs/notifications.md).
- **The background**: suspended, the app answers nothing, so the server closes its socket about a minute later, and
  stops sending it the open chat's streamed chunks. Before, they kept coming for the whole run (333 frames in 40 seconds
  of a streamed answer), waking the phone's radio for each.
- **Waking** (`TauConnection.wake`): back in the foreground, or woken in the background for a notification's reply, a
  socket silent for more than 40 seconds, which the server has closed by then, is replaced at once; a newer one gets a
  ping with 3 seconds to answer; one still connecting, or waiting out a backoff, is tried now. A socket that died while
  the app was away used to be found out by the 10-second pong, 11.7 seconds after the app came back; now it is replaced
  in 0.6 seconds after a long absence, 4.3 after a short one. A reply from a notification no longer risks the 25 seconds
  iOS gives it.
- A socket that dies while the app is in the foreground is still found out by the next ping: up to 25 seconds.

## What goes over it

- **Compressed**, every frame of 64 bytes or more. Streamed chunks are a few hundred bytes, most of it the same path
  each time; at the old threshold of 1024 bytes none of them was compressed.
- **Entries as the app shows them** (`server/src/outgoing.ts`). The provider's replay data (`thinkingSignature` and
  the like, opaque and nearly incompressible) was 44% of a real server's history on the wire, compressed: 1.33 of
  3.05 MB, for reasoning models (Opus, GPT). A `pi.system` entry came with the whole prompt and tools, 12.7 kB at the
  start of each conversation; no client shows them. Both are left out; the model's context keeps them.
- **The chat list by version.** The server keeps every conversation's Dialog in memory, read once at start and then
  updated from each commit (new entries and runs starting or ending from the commit itself; a read mark, title, model or
  prompt cache by reading that conversation again), and numbers each change. The app keeps the version with its list
  on disk and asks only for what changed since. With 2,000 conversations a reconnect took 100 to 260 ms of the server's
  time and 540 kB (raw) for the whole list; now 2 to 3 ms and 53 bytes when nothing changed.
- **Photos over HTTP.** A user's photo is fetched as its file, beside the socket, not as base64 in a `media.get` answer
  that held back everything behind it (docs/media.md).
- **Read marks at most every 2 seconds** per chat, the newest: a chat on screen while an answer comes read each entry,
  a commit, a recount and a `dialog` push each, seven in one short run.
- **A fork starts from its original**: entries are global and never change, so a fork with nothing cached takes the
  entries up to its point from what the phone has of the conversation it was made from, and its subscribe brings only
  what comes after. An edit's fork used to download the newest 100 entries again (on a real server about 400 kB
  compressed for a long chat); now it brings the edited message.

## Left as they are

- **Preloading** the top 30 chats goes one at a time; it is background work, and with the replay data gone it is
  about half what it was.
- **Uploads** of an album go one at a time: bandwidth bounds them, and running them together would change the outbox.
- **Downloads and uploads do not resume**: large files are rare.
- **No thumbnails**, and no automatic download policy on mobile networks: a design of its own.
- **Tool results** are a quarter of a history's bytes, but an expanded card shows them.
- **Network Usage** counts the socket's text before compression and leaves out HTTP.

## Measuring

A proxy that logs each frame (its method or event, op paths, sizes, the server's time) and the bytes on the wire, and
can delay, throttle or freeze a socket, sits between the app and the server: the app with
`-server.url ws://127.0.0.1:<proxy port>`. It was a scratch tool of the audit and is not in the repository.
