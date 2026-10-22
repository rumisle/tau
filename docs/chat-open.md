# Opening a chat

A chat opens as Telegram's does: at once, with what the phone has, and never waiting for the network.

## Ready without the network

The navigation controller pushes a chat when its `ready` fires (Telegram's `NavigationContainer` waits for it).
`ChatControllerNode` fires it on its first update that is laid out: the cached transcript, or nothing yet. A chat with
nothing on the phone opens with Telegram's `ChatLoadingNode` (`Tau/Chat/ChatLoadingNode.swift`, the spinner in a
service-colored circle that Telegram shows in a one-to-one chat), centered between the bar and the input panel; the
subscribe's transcript replaces it, and it shrinks and fades out as Telegram's does. Offline, it stays until the server
is back.

Before, `ready` waited for the subscribe or 0.35 seconds: over Tailscale a chat not on the phone took the whole 0.35
seconds to open, and sometimes opened empty anyway.

## Preloading the top of the list

As Telegram's `ChatHistoryPreloadManager` keeps the history of the top of its chat list, `ServerStore` brings the
transcripts of the first 30 chats of the list (pinned first; not archived ones, subagents' or working ones) up to date in
the background, so a chat with new messages opens with them:

- A second after the list arrives or changes, and at most once a second while it keeps changing.
- For each chat whose cache is behind its newest message (`dialog.last.id`), one at a time: `conversation.history
  { after: cached newest, limit: 100 }`, without `before`, so without subscribing. More than 100 missing (`hasOlder` with
  `after`) is a gap, and the newest 100 replace the cache, as a subscribe's gap does.
- Into the replica when the chat was opened this run, else into its file (`EntryCache.merge`). Every read and write of
  the files goes through one serial queue, so a chat's save, a preload and a reset never interleave, and a load sees what
  was queued before it.
- A chat opened meanwhile is skipped: its subscription brings everything.
- What each chat was brought up to is remembered for the run; Clear Cache and another database start over.

Opening a preloaded chat still subscribes, with `after` its newest entry, so the docs and anything newer come at once.

## Trying it

`SendingUITests.testOpenWithoutWaiting` clears the cache, lets the list preload, stops the server and opens the chat
(its transcript is there); then clears it again with the server stopped, opens it (the spinner), and starts the server
(the transcript).
