# Edits and forks (design notes, not built)

Where the discussion of editing a message and forking from one got to, so it can be picked up later. Nothing here is
implemented; the current behavior is in docs/sending.md "Edits and drafts". The aim, before any code: robust,
predictable, and as simple as Telegram makes things look.

## What there is now

- **Edit** forks the conversation before the edited message (`conversation.fork` at the entry before it) and sends the
  new text as the fork's first message; the fork replaces the chat on screen, the original stays in the list
  (`ServerStore.editResolved`). Editing the first message makes a new conversation. Submitting an edit without changing
  anything does the same: the answer is generated again, in a new chat.
- **Subagents do not follow.** `tau.subagents` is `fork: "initial"` (server/src/subagent.ts: "a fork starts without
  subagents: they belong to the original"). In the fork the model still reads that it spawned them, but their reports
  go to the original only, and `send` to one answers `No subagent named X`. Nothing breaks on the server, but the model
  may wait for reports that never come, or spawn again and lose the subagent's context.
- **The app follows the original's subagents in a fork**: a card before the fork point links to the original's child
  conversation and shows it working (`childBusy` from that dialog), though its result will never come to the fork.
- **The list** shows the fork as a second chat with the same title, one more per edit, nothing linking them (TODO.md
  "Editing a message forks a second chat"). Not to address now.

## What the user wants

Most edits (by the user's estimate 99 %) abandon the original: the user wants to change what was said and go on, with
the same subagents, not a second chat with the subagents left behind in the first. But when the original matters, it
must keep working soundly: taking its subagents away from it would be wrong.

## The idea: two verbs

- **Edit changes this chat.** No new conversation: the chat goes back to before the edited message and goes on from
  the new text. What came after stays in the transcript, hidden from the model; the chat's subagents stay.
- **Fork makes another chat.** A new conversation beside the original, which is untouched. The fork has no subagents,
  and is told so (see below).

### Edit as versions in one conversation

Durable's transcript is append-only, but it already has what this needs: an entry may carry `edits`
(`ContextEdit`, durable src/types.ts): `{ target, action: "omit" }` or `{ target, action: "replace", messages }`.
Per target, the newest edit wins (src/harness/context.ts `deriveRange`). So:

- An edit appends an entry that omits the edited message and everything after it, and then the new message. The
  prompt cache's prefix up to the edit point still holds.
- Nothing is deleted: going back to an earlier version appends another edit that omits the current version's entries
  and replaces the earlier version's with their own messages (a `replace` with an entry's own `model` messages is the
  entry as it was). Any number of switches, in either direction.
- In the app this is the familiar version switcher on the edited message (ChatGPT's and Claude's `< 2/3 >`): the
  transcript shows the current version; the others are a tap away.

A write with `edits` waits for the next boundary like a steer (durable README "Writes"), so an edit while the agent
works stops the run first (Stop and Send), then goes back.

### Subagents in an edit

By which version they belong to:

1. **Spawned before the edit point**: they stay. Their spawn is still in what the model sees; one at work goes on and
   reports into the chat, which is right.
2. **Spawned in the part edited away**: they belong to an abandoned version. Stopped, but kept in `tau.subagents`
   (stopping keeps a subagent's conversation and context), so switching back to that version finds them again.
3. **Spawned before, but given work in the part edited away** (`send`): the agent stays; the work it is doing for the
   abandoned version is stopped, or finishes without reporting (to decide).

### Fork

- From any message, including the steps inside an answer (a tool card, thinking): the user wants to fork from
  anywhere, to steer an agent differently from a point in its work.
- What the fork has: everything up to and including that message; the model, thinking level, and working directory;
  not the original's running answer, nor its subagents.
- On the user's own message: the fork answers it again (as an unchanged edit does now).
- The model in the fork is told, as part of the fork, that it is a fork of "<title>" and that the original's subagents
  (by name) are not here and can be spawned again.
- The app shows subagent cards before the fork point as the original's: no live "working" state from them.
- Never between a tool call and its result: the model's API takes no unanswered calls. Forking from a tool card forks
  after its result; while the tool runs there is no such point yet (the menu item disabled, or the fork before the
  call: to decide).

## Open questions

- Which version the chat list's preview and the search index show; whether hidden versions are searchable.
- How the version switcher looks in a transcript of tool cards, where the "message" edited is far above the end.
- Item 3 above: stop the work, or let it finish unreported.
- What a fork of a fork, or an edit inside a fork, says to the model about subagents.
- Whether an edit of a subagent's own conversation (a child chat) is allowed, and what its parent then sees.
- How offline edits (the outbox) express "go back to version n" idempotently.
- Migration: existing edit forks stay as they are.
