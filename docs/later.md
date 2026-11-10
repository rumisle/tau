# Later

Status: design, not built. Reviewed once against durable (spec.md, src/types.ts, harness/scheduler.ts) and tau's
server; implementation notes below come from that review. Reading back is docs/history.md, built.

A conversation can put something off: "look at this later". The user can't look at it now, or the agent is busy
with something more important and doesn't want to spend its context window on it. A Later is that thing, picked up
again when its time comes, on its own thread. The conversation it came from gets only a short card.

## Use cases

- Nagging that isn't annoying: "I've been coughing for weeks, I should see a doctor." Every few days it checks in, and
  each time brings something new (a clinic with a Saturday slot, a reason this cough is worth checking) instead of
  repeating itself. It backs off when ignored and stops once the user has been.
- Something spotted during a task: the agent notices a flaky test while doing a refactor and puts it off.
- Watching: a fare below a target, a PR's CI, a deploy's error rate for a day, a package release. It wakes, checks,
  and stays silent unless there is something to say.
- Deadlines worked backwards: a visa renewal, a contract, taxes.
- "Let's look into this sometime": comes back on a quiet weekend morning with a short reading list.

## Model

A Later is a **hidden child conversation with a next wake time**, owned by a **top-level** conversation (its
*owner*).

```
Later = child conversation {
  owner:    top-level conversation  // where its cards go; who manages it
  anchor:   EntryId                 // the entry it came from (in the owner, or in the Later that made it)
  brief:    string                  // what, what's known, why it was put off; the Later may update it
  wake:     { at: time }
  state:    waiting | running | done | cancelled
}
```

- Each Later is **one thread for its whole life**. Every wake runs in the same thread, so the five doctor check-ins
  and what came out of them stay together.
- It **always** gets its own thread, never the owner's transcript. When the Later is made, nobody can tell whether
  waking in the owner would pollute it later, so there is one rule and no judgement call.
- It starts from the brief alone, not a fork. Forking at creation misses what came after. Forking at wake time
  copies a window that may have moved on. The brief and the history tools (below) cover both.
- **Flat:** whoever creates a Later (the top-level agent, a subagent, or another Later), it is owned by the root of
  the ownership chain, the top-level conversation, and its cards go there. There is never more than one level. The
  anchor stays where it was made (for example in the subagent's transcript), which the owner can read as a
  descendant. A Later outlives the subagent that made it.

Implementation: durable conversations are owned by a *task*, not a conversation (`ConversationRecord.owner`,
src/types.ts). As `subagent.ts` does, the owner gets a background anchor task, and each Later thread is created with
`ownership: { kind: "task", taskId }`. Background ownership means the owner's Stop doesn't touch its Laters.

## Creating one

- The agent calls `later` with `brief` and `wake`.
- The user long-presses any message and picks "Later". The brief is the user's own text for v1. Drafting it with the
  model can come later.

## Waking

- `wake.at` only, for v1. "When the owner's current run ends" (`idle`) has no durable primitive. The run's task
  changes from one generation to the next, so it would need a tau hook on the owner's run ending. "In N minutes" is
  the stand-in for now.
- A wake is one run in the Later's thread. It sees its brief, its own earlier wakes, and the current time.
- During a wake it **decides the next one itself**: it sets `wake` again, or finishes. That is where backoff and
  "don't be annoying" live. A fixed schedule can't adapt to the user's replies.
- Minimum interval between wakes: 15 minutes, so a watch can't run away with the bill.
- Quiet hours: wakes due at night are pushed back to morning. The user's timezone is set in the app and synced to the
  server.

Implementation: a sleeper task (`defineTask` with a `sleepUntil` phase) per Later. On waking it submits the wake
prompt to the thread, waits for the run to end (as `Reporter` does), reads the next `wake` from a doc, and sleeps
again. Sleeps survive restarts already. A sleep can't be woken early except by an abort (spec.md §5.6), so "run now"
and rescheduling abort the sleeper and start a new one.

## Reporting

A wake says something only by calling `report`:

```
report({ notify: boolean, card?: string })
```

- `card`: append a card to the owner (below).
- `notify`: push to the user.
- A wake that ends without calling `report` is **silent**: no card, no push. Every run ends in an assistant answer,
  so silence has to be explicit like this.

## The card

- A reference to the Later's thread, plus a sentence or two.
- Appended through a write submission (`submit({ type: "write", entry })`), not a raw append. It doesn't start a run.
  If the owner is idle, the model sees it the next time the user writes there. If the owner is busy, it lands at the
  next boundary of the current run, like a steer. Both are fine.
- Older cards are **not** hidden from the model. Omitting them with `edits` would change the context at that position
  and break the prompt cache from there every time a new card arrives. They are short, so they stay. The UI folds a
  Later's cards into one, with a badge when the thread has news.
- The card is a sentence or two and the thread's tau link (`tau://<server>/<thread>`, docs/links.md). The app
  already draws a link to a chat as a card with its title and latest message, and a tap opens it. The model reads
  the link as text, and `history_read({ link })` opens it.

## Reading back

Nothing new: docs/history.md's `history_read` and `history_search`. Any conversation can read any other on its
server.

- The owner's agent reads a Later's thread from its card's link, or searches all of them:
  `history_search({ query, in: <thread link> })`.
- A Later reads its owner with `history_read({ link: "owner" })`. Its owner is the top-level conversation, since its
  anchor task lives there. Its brief carries the anchor's entry link, which may point into a subagent's transcript,
  and it reads around that with `history_read({ link: <anchor> })`, and anything newer by paging `newer`.
- Searching the owner's context for what changed since it was put off: `history_search({ in: "owner", sort: "newest" })`.

## The user in the thread

- A push opens the Later's thread. The user can reply there, and the conversation continues in the thread.
- A reply while a wake is running is a **steer** into that run.
- Back goes to the **owner**, scrolled to the card, not to the chat list.
- Telegram does the same with channel comments: a notification opens the comments, and back lands on the post.

## Managing

| Who | Can |
|---|---|
| Owner's agent | `later` tool: create, list, cancel, reschedule, update the brief, for all of the owner's Laters |
| A Later | itself: update its brief, set its next wake, finish ("they went to the doctor; done"); create Laters (owned by the top level) and manage the ones it made, but not its siblings |
| User | long-press a card: cancel, snooze, run now; the owner's info page lists its Laters |

There is no global list for now. One can be added under Settings if Laters get hard to find.

## Owner lifecycle

- **Archived** (durable has no delete): Laters keep running. The user cancels them if they're no longer wanted.
- **Forked:** Laters are not copied (subagent ownership uses `fork: "initial"`). They stay with the original, and new
  cards go there. The fork keeps the old cards as history. Their links still open and read the threads.
- **Stop:** doesn't cancel Laters.

## Server changes this needs

- `dialogs.ts` loads every conversation (`scanConversations({})`), so it has to leave out owned ones, or Later
  threads show up as chats. Not with `MetaDoc.hidden`: that is the user's Hide, and it would also take the threads out
  of `history_search`.
- `notifier.ts` skips every owned conversation (around line 223). It has to notify for a Later's wake when `report`
  asks for it, as the thread, with Reply.

## Not in v1

`wake.idle`, recurring schedules (cron), event triggers (webhooks, polling conditions), forked Laters, a global list,
and model-drafted briefs.

## Prior art

ChatGPT "Scheduled tasks" put each run in the chat that made the task. Claude Code's `/loop` runs in the session
(`CronCreate`). Its cloud "Scheduled tasks" (formerly Routines) start a fresh session each run. The first pollutes and
the second loses the link. Later sits in between: its own thread, with a card and a way to read back.
