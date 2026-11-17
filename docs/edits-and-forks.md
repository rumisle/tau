# Edits and forks (design, not built)

Status: agreed (an edit changes the chat, a fork makes another one with copies of its subagents); a few details are
left for the building. Nothing here is implemented: the current behavior is in docs/sending.md "Edits and drafts".

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
- **Fork makes another chat.** A new conversation beside the original, which is untouched. Its subagents come along
  as copies, each as it was at the fork point (below).

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
- **An edit before the last compaction becomes a fork.** Durable's context starts at the newest head marker, and a
  head write whose target is older than that start is refused as stale (durable docs/spec.md, "A head write ... is
  stale: placing it would bring back history that head cut"). A fork at that point, though, has the whole history up
  to it: the original's later head markers are past the fork's cap. So the edit opens a new chat, with its subagents
  copied (below), and no dialog asks first: the edit panel says so in one line ("Before the summary: edits in a new
  chat"). This should be rare, since most edits change a recent message; to be checked against the data.

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
2. **Spawned in the part edited away**: they go on and report into the chat. Nothing is lost, and the result may be
   what the user wanted. The model of the new version no longer sees the call that started one, so the report says so
   as a fact: the subagent was started in the part of the chat the user edited away. The user can stop one from the
   Subagents menu (perhaps the very reason for the edit). Switching back to that version finds it in `tau.subagents`.
3. **Spawned before, but given work in the part edited away** (`send`): the same: the work finishes and reports, saying
   it was asked for in the part edited away. Reports are per run of the subagent (`afterRun`), not per message.

It happens: on server A, 17 subagents spawned in a part an edit left were still working at the edit, and 13 spawned
before the edit point were (each still wrote after the edit). All of them reported into the original, which nobody
read.

### Fork

- From any message, including the steps inside an answer (a tool card, thinking): to steer an agent differently from
  a point in its work.
- What the fork has: everything up to and including that message; the model, thinking level and working directory;
  copies of its subagents; not the original's running answer.
- On the user's own message: the fork answers it again.
- The model in the fork is told, as part of the fork, that it is a fork of "<title>".
- The subagent cards before the fork point are the copies', live in the fork.
- Never between a tool call and its result: the model's API takes no unanswered calls. Forking from a tool card forks
  after its result; while the tool runs there is no such point yet.
- The fork's counter is its own spend, from zero; the cost card also says what was spent before the fork.

### Subagents in a fork: copies as of the fork point

Entry IDs are global and ordered across the whole database (durable docs/spec.md 2.1), so "the subagent as it was at
the fork point" is exact: its newest entry with an ID below the fork point.

- Each subagent of the original spawned before the fork point is forked at that entry, owned by a new anchor task in
  the fork (tau already gives each subagent a `tau.subagent-anchor` task; durable's `forkConversation` takes the
  ownership explicitly), and entered in the fork's `tau.subagents` under the same name.
- A subagent spawned after the fork point has an ID above it, and isn't copied.
- The copies and the originals are independent from then on: each reports to its own chat. A copy costs nothing
  until it is used, since a durable fork shares its history.
- A subagent midway through a turn at the fork point is copied with what it had committed; a tool call without its
  result gets durable's synthesized error result. A message to it carries on.
- A subagent's own subagents are copied the same way, depth first.
- Not copied: what lives outside the database (files, processes), as with any fork.
- Before building: a small durable test that a fork of a task-owned conversation can take a new owner.

## Open questions

## Decided

1. An edit changes the chat; a fork is a separate action.
2. Versions show as **edited** and **Versions** in the menu (web: hover actions).
3. Subagents of a version edited away go on and report, saying where they were started.
4. An edit before the last compaction becomes a fork.
5. A fork's counter starts at zero; its cost card says what was spent before the fork.
6. A fork copies its subagents as of the fork point.
7. Existing edit forks stay as they are for now (no clean-up script).

## Left for the building

- Which version the chat list's preview and the search index show; whether hidden versions are searchable.
- What a fork of a fork, or an edit inside a fork, says to the model about subagents.
- Whether an edit of a subagent's own conversation (a child chat) is allowed, and what its parent then sees.
- How offline edits (the outbox) express "go to version n" idempotently.
