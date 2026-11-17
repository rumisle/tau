# Edits and forks (design, not built)

Status: the direction is agreed (an edit changes the chat, a fork makes another one); the questions at the end are
open. Nothing here is implemented: the current behavior is in docs/sending.md "Edits and drafts".

## What there is now

- **Edit** forks the conversation before the edited message (`conversation.fork` at the entry before it) and sends the
  new text as the fork's first message; the fork replaces the chat on screen, the original stays in the list
  (`ServerStore.editResolved`). Editing the first message makes a new conversation. Submitting an edit without changing
  anything does the same: the answer is generated again, in a new chat.
- **Subagents do not follow.** `tau.subagents` is `fork: "initial"` (server/src/subagent.ts: "a fork starts without
  subagents: they belong to the original"). In the fork the model still reads that it spawned them, but their reports
  go to the original only, and `send` to one answers `No subagent named X`. The model may wait for reports that never
  come, or spawn again and lose the subagent's context.
- **The app follows the original's subagents in a fork**: a card before the fork point links to the original's child
  conversation and shows it working (`childBusy` from that dialog), though its result will never come to the fork.
- **The cost counter starts again at zero**: durable's `pi.usage` is `fork: "initial"`, a ledger of the conversation's
  own spend.
- **The list** shows the fork as a second chat with the same title, one more per edit, nothing linking them.

## What it does in use

Two servers' databases, read-only (November 2026): one used daily by one person for a month, one by the developer.
A conversation that was forked from counts as *abandoned* when nothing was written to it after its first fork, and
as *used again* when the user wrote to it after.

| | Server A | Server B |
|---|---|---|
| Top-level conversations | 146 | 333 |
| ...of them edit forks | **126** | 28 |
| Largest chat: forks / longest chain of forks | **94 / 70** | 3 / 3 |
| Conversations forked from | 116 | 28 |
| ...abandoned | 99 (98 still in the list) | 27 (21 archived by hand) |
| ...the user wrote to again | 10 | 1 |
| Visible chats sharing one title | **95** | 3 |
| Subagents the latest chat of each edited chat no longer has | 75 | 27 |
| Originals that got only subagent reports after the fork | 6 | 0 |
| Latest chats' cost counters, together | **$4.15** | $664.59 |
| ...what their earlier versions spent besides | **$986.01** | $195.63 |

- The user's estimate holds: of 144 conversations forked from, the user went back to 11 (8%).
- A subagent working when its chat was edited reports to the original, which nobody reads: its result is lost to the
  user (6 cases on server A).
- 24 of server A's 126 forks sent the same text as the original: a regenerate, not a change.

## How others do it

- **ChatGPT and Claude**: an edit makes a new version inside the same conversation, switched with `< 2/3 >` under the
  message; the sidebar keeps one item. A new chat from a point is a separate, explicit action (ChatGPT's "Branch in
  new chat").
- **pi**: `/tree` branches within the same session file, which is where an edit goes; `/fork` makes a new session
  (pi's docs/sessions.md).
- **Claude Code**: `/rewind` goes back to an earlier point and goes on in the same session.

None of them handles edits by archiving the old chat.

## Why not archive the original automatically

It moves the clutter rather than removing it (server A's Archived Chats would hold 98 chats of one title), takes over
the user's own "I'm done with this" gesture, and fixes neither the lost subagents nor the counter: reports would still
go to a chat nobody sees.

## The design: two verbs

- **Edit changes this chat.** No new conversation: the chat goes back to before the edited message and goes on from
  the new text. What came after stays, hidden from the model; the chat's subagents stay; the counter keeps counting,
  since that money was spent in this chat.
- **Fork makes another chat.** A new conversation beside the original, which is untouched. The fork has no subagents,
  and is told so (below).

### Edit as versions in one conversation

Durable's transcript is append-only, but it already has what this needs: an entry may carry `edits`
(`ContextEdit`, durable src/types.ts): `{ target, action: "omit" }` or `{ target, action: "replace", messages }`.
Per target, the newest edit wins (durable docs/spec.md 2.1, src/harness/context.ts `deriveRange`). So:

- An edit appends an entry that omits the edited message and everything after it, and then the new message. The
  prompt cache's prefix up to the edit point still holds.
- Nothing is deleted: going back to another version appends another edit that omits the current version's entries
  and replaces that version's with their own messages (a `replace` with an entry's own `model` messages is the entry
  as it was). Any number of switches, in either direction.
- A write with `edits` waits for the next boundary like a steer (durable README "Writes"), so an edit while the agent
  works stops the run first (Stop and Send), then goes back.
- Durable's context starts at the newest head marker and heads only move forward (src/harness/context.ts
  `advanceRange`). An edit before the last compaction would need a head back at the old start, and the context would
  grow back to its size before the compaction (question 4).

### Showing versions

Most of the time nobody goes back, so the versions stay out of the way until asked for.

- **iOS**, as Telegram does things:
  1. The edited message says **edited** beside its time, as Telegram marks an edited message. No buttons, no room
     taken.
  2. Its context menu (long press) has **Versions**, one word, only when there is more than one. Not "Earlier
     Versions": on version 2 of 3 there is a later one too.
  3. Versions opens a list in a Telegram sheet: each version's message, the first line of its answer, its time and
     cost; the current one has a check mark. A tap switches to it (stopping a running answer first). A switch only
     appends an edit, so nothing is lost and it can be undone.
  - Not a swipe on the bubble: it would fight Telegram's swipe to reply. Not a standing row under the message ("2
    earlier versions"): one per edit clutters the chat again.
- **Web**, by desktop conventions (docs/web.md): `‹ 2/3 ›` in the message's hover actions, and the same Versions list
  from its context menu.
- A first version can ship with **edited** and the **Versions** menu and list only; the data is there for any later
  look.

### Subagents in an edit

By which version they belong to:

1. **Spawned before the edit point**: they stay. Their spawn is still in what the model sees; one at work goes on and
   reports into the chat, which is right.
2. **Spawned in the part edited away**: they belong to an abandoned version (question 3).
3. **Spawned before, but given work in the part edited away** (`send`): the agent stays; the work it does for the
   abandoned version is stopped, or finishes without reporting (question 3). Reports are per run of the subagent
   (`afterRun`), not per message, so one that finishes reports to the chat unless its leader changes.

### Fork

- From any message, including the steps inside an answer (a tool card, thinking): to steer an agent differently from
  a point in its work.
- What the fork has: everything up to and including that message; the model, thinking level and working directory;
  not the original's running answer, nor its subagents.
- On the user's own message: the fork answers it again.
- The model in the fork is told, as part of the fork, that it is a fork of "<title>" and that the original's subagents
  (by name) are not here and can be spawned again.
- The app shows subagent cards before the fork point as the original's, without their live "working" state.
- Never between a tool call and its result: the model's API takes no unanswered calls. Forking from a tool card forks
  after its result; while the tool runs there is no such point yet.
- The fork's counter is its own spend (question 5).

## Open questions

1. ~~Edit in place, fork as a separate action~~: agreed.
2. ~~How versions show on a phone~~: agreed, as above.
3. **Subagents spawned in the version edited away**: stopped but kept in `tau.subagents` (stopping keeps a
   subagent's conversation and context, so switching back finds them), or left to finish without reporting?
4. **An edit before the last compaction**: allow it, with the context back at its size before the compaction, or make
   it a fork, or warn first?
5. **A fork's counter**: its own spend from zero, with the cost card also saying what was spent before the fork?
6. **Existing forks**: a one-time script that archives the conversations forked from and abandoned (server A's 98)?
   New edits make no forks, so this happens once.

Also to settle while building:

- Which version the chat list's preview and the search index show; whether hidden versions are searchable.
- What a fork of a fork, or an edit inside a fork, says to the model about subagents.
- Whether an edit of a subagent's own conversation (a child chat) is allowed, and what its parent then sees.
- How offline edits (the outbox) express "go to version n" idempotently.
