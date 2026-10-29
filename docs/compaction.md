# Compaction

When a conversation's context fills up, the older part is replaced by a summary and the conversation goes on from the
summary and the latest messages. tau uses durable's compaction (`vendor/pi/packages/durable/src/harness/compaction.ts`)
as it is, with two changes, both in `server/src/compaction.ts`: when it starts, and how the summary is asked for.

## What durable does

- **When.** Before each request, generation estimates the context: the usage of the newest answer plus estimates of
  the messages after it. Above `contextWindow - reserveTokens` (16384) it blocks: it compacts, then prepares the
  request again. Above `backgroundTokens` (32768) less than that, it starts a background compaction: the conversation
  keeps working, and the summary is placed at the next boundary through a write submission. A provider's context
  overflow error compacts and retries once. `conversation.compact` compacts on request.
- **What is kept.** Walking back from the newest entry until 20000 tokens (`keepRecentTokens`) are kept, the cut lands
  on an entry that starts with a user or assistant message, never between a tool call and its result.
- **The entry.** A `pi.compaction` entry whose `head` is the first kept entry; its model content is one user message,
  `The conversation history before this point was compacted into the following summary:\n\n<summary>\n…\n</summary>`.
  The context is then `[system][that message][the kept entries…][new]`. Nothing is removed from the transcript.
- **The summary.** Durable's own: a separate request, with a system prompt of its own and the summarized messages
  serialized as text (tool results cut to 2000 characters, thinking left out), in six sections (Goal, Constraints &
  Preferences, Progress, Key Decisions, Next Steps, Critical Context), folding an earlier summary into the new one. It
  sends `cacheRetention: "none"`: none of it is a cache read. Errors that may pass are retried with backoff; the task
  survives restarts.

## What tau changes

**When it starts.** At a share of the model's window, 90% by default, but never past 700k tokens: past that, long
context answers worse and every step costs more, whatever the window. This is durable's background threshold, set
per model through `compaction.modelOverrides` (`compactionPolicy`): the conversation keeps working while the summary
is made, and durable's blocking threshold, 16384 short of the window, stays behind it. For a 200k window that is
180k in the background and 183,616 blocking; for 1M, 700k and 983,616. A window too small for the share to come first
(32k) only blocks. Clients set the share and the cap with `settings.configure { compaction }` (Settings > a server >
Auto-Compact); off leaves overflow and manual compaction.

**How the summary is asked for.** As a follow-up to the conversation's own request: the context exactly as the last
step sent it (`Conversation.context()`, the same messages, system deltas and tools; the same model, thinking level,
stream options and provider session ID), with the summary prompt as one more user message. The whole prefix is a cache
read; only the prompt and the summary are new. The prompt is durable's, worded for a reader that has the whole
conversation: its system prompt's instructions (do not continue, do not call tools) open the message, since the system
prompt cannot change without missing the cache, and it names where the kept part starts ("the user message starting
…"), asking for Progress and Next Steps as of the end of the conversation.

It goes out from durable's `beforeCompact` hook, which may supply the summary; durable still selects the cut, places
the entry and owns the task. It is completed, not streamed, so the cache warmer (docs/cache.md) does not take it for a
step. A tool round still waiting for its results (a manual compaction mid-round) is left out of the follow-up: a user
message cannot follow unanswered tool calls, and what comes before is still the cached prefix.

**Falling back.** Anything that does not give a summary returns no decision, and durable's own summarization runs:
no provider session yet (nothing is cached), a reply that calls a tool, stops for length or has no text, an error
after two retries of those that may pass, or a request that throws. The default is the fallback.

**Usage.** The follow-up's usage goes into the conversation's `pi.usage`, as durable records its summaries, and into
the Usage ledger as the model `tau/compaction` (`server/src/search/usage.ts`).

## In the app

Durable's semantics stand: a manual or background compaction never holds the conversation up. A message sent meanwhile
is answered at once, on the whole context, and the summary goes in at the run's next boundary, or not at all when the
conversation moved past it (its write settles `stale`). The app says so instead of hiding it:

- **From start to end, one row.** A compaction shows at the bottom of the chat from the moment it starts, Telegram's
  service pill with the τ: "Compacting context… 1m 20s"; once summarized while a run goes on, "Context summarized ·
  goes in at the next step". When the summary is placed the pill turns, in place, into the "Context compacted" card:
  when and why (on request, automatically, after an overflow), that the model reads this summary instead of everything
  above it, the context's size before and after it ("412k → 38k tokens", from the last answer before it and the first
  after it) and what tau's summary request cost; the summary folded under it, a tap unfolds it. One that was not used
  stays as a small note where the chat was then: "Compaction not used: the chat moved on", "Compaction failed: …",
  "Nothing to compact". Manual and automatic ones alike.
- **The server keeps what became of each** (`server/src/compactions.ts`): from `pi.live.compactions`, the summary's
  entry (a blocking one's own) or its write submission (`compaction:<taskId>`: placed, or `stale`), the failure, the
  answers' usage and the follow-up's cost, in the conversation doc `tau.compactions`, which clients get with the
  others (`docs["tau.compactions"].items`, docs/protocol.md). So a chat says it after a restart or a week later too.
- **The title says what holds the user up**: "working" while the agent works, a background compaction meanwhile
  included (the row says that one); "compacting" when the agent is idle and a compaction runs, and when the run waits
  for one (past durable's blocking threshold). The field says Steer while a run goes, else Message: a message during
  an idle compaction is answered at once.
- The chat's menu (⋯) has Compact Context; the card's Continue with Full Context goes on in a new chat, a copy from
  before the summary.

## Tests

`server/test/compaction.test.ts`: the thresholds, a manual compaction whose follow-up reads its context from the dev
model's prompt cache (`devCacheTtl`), the fallback when the follow-up calls a tool (`!no-follow-up` in the chat), and a
threshold compaction started on its own after `settings.configure { compaction: { ratio: 0.3 } }`, each with its
`tau.compactions` record (placed, the context before and after, the cost), and one asked for mid-run (placed at the
next step, or not used). `SendingUITests.testCompactionCard`: the pill to the card, idle and mid-run, and the title.
