# Sending

How a message gets from the composer to the model, and what the user sees on the way. The client side is
`ios/Tau/Server/Outbox.swift`; the server side is `conversation.submit` and `submission.withdraw` in
`server/src/connection.ts` (docs/protocol.md).

## What the server does with a message

durable admits a submission and gives it a status:

- `queued`: in the conversation's inbox (`pi.inbox`), waiting for a boundary. The model has not seen it.
- `placed`: in the transcript. The model has it.
- `done` or `unanswered`: the run that had it ended, with an answer or without one (`aborted`, `model_error`,
  `no_model`, `reset`, `faulted`, `restart_limit`).

An idle conversation places a message at once and starts a run. A busy one queues it. A **steer** is placed at the next
boundary: after the current tool round, or when the answer ends; it joins the running run. A **follow-up** is placed
only when the run ends, and starts the next run. durable does not interrupt text being written: a steer sent during a
final answer waits for it, then starts a run, as a follow-up would. Both modes take one message per boundary
(`one-at-a-time`, pi's default).

Once placed, a message is in the transcript for good; what happens to the run is the run's outcome, shown where the
answer would be, not on the message.

## Refused

The server refuses a message when it will never take it, before anything is written:

| Code | When |
|---|---|
| `too_large` | more than 1,000,000 characters, more than 20 photos or files, a file over the server's limit |
| `file_missing` | a file it does not have (swept a day after an upload no message took): uploaded again, once |
| `not_found` | the conversation does not exist (deleted, or the server's database was replaced) |
| `bad_request` | malformed content |
| `withdrawn` | the request ID was withdrawn first (see below) |

`internal` is the server failing, which may pass: the client retries it four times, 1, 2, 4 and 8 s apart, then
treats it as refused. A lost connection, a timeout, or a server that is down is never a refusal.

## On the client

Every message is an `OutgoingMessage` in the outbox, written to disk before its request goes out. It has a request
ID, which makes its submit idempotent, and a position (`seq`) among everything asked of its conversation.

```
               send (on disk)
                    │
                    ▼
              ┌───────────┐ refused  ┌─────────┐  Resend → a new message
              │  pending  │─────────▶│ failed  │  Delete → gone
              │   clock   │          │ red  !  │
              └─────┬─────┘          └─────────┘
      placed        │  queued
                    │     └────────▶┌────────────┐ withdrawn → gone, or back in the field
                    │               │   queued   │ Edit      → back in the field
                    │               │ panel, ✓   │ move      → withdrawn, then sent anew
                    │               └─────┬──────┘
                    │        placed       │ (a withdraw that comes too late reports it)
                    ▼                     ▼
              ┌─────────────────────────────────────┐
              │ placed: in the transcript, ✓✓       │
              └─────────────────────────────────────┘
```

Rules that keep it predictable:

1. **On disk first.** A message survives a lost connection and a killed app. Relaunched, the outbox sends what is
   pending and asks again about what was queued.
2. **One request per conversation at a time, in order.** Messages, withdraws, aborts, resets, compactions and model
   changes of one conversation go out in the order the user made them, each after the previous one is answered. The
   server runs them in arrival order too (`Serial`). A model chosen before a message answers it.
3. **Idempotent retries.** A submit that may have arrived is sent again with the same request ID; the server answers
   with the existing submission. A conversation create carries a request ID too.
4. **No timeouts on messages.** A request with no answer in 45 s (longer for big frames) means the socket is dead:
   the client reconnects and sends again. A ping every 15 s finds a socket that died quietly, and waking (the app
   back in the foreground, or woken for a notification's reply) replaces one the server has closed meanwhile at once
   (docs/network.md).
5. **Cancelling is safe at every step.** A message never written to a socket is dropped locally. Otherwise
   `submission.withdraw` names it by request ID: queued, it leaves the inbox; placed, the client says so and keeps it;
   not arrived yet, the server remembers the ID and refuses the submit if it comes later. Without that last case a
   message cancelled while its submit was in flight could still be sent.
6. **Records only move forward.** A queued record that arrives after the message was placed is ignored. A placed
   message stays in the outbox until its entry reaches the replica, so its row keeps its ID.
7. **Pushes for every conversation.** The server reports submission changes of all conversations to a client that
   subscribed to the chat list, so a chat that is not open still learns what became of its messages. After a reconnect,
   every queued message asks again.
8. **One database.** Messages written for one server database are failed, not sent, if the server reports another
   one: its conversation IDs name other conversations.

## Edits and drafts

An edit is a fork before the edited message with the new text as its first message (pi's `/tree` and edit work the
same way). The fork is a create in the outbox: on disk, sent with a request ID that makes `conversation.fork`
idempotent, and the edited message waits for it like any first message. Until the fork exists and its transcript has
arrived, the chat shows the original up to the edit, then the new message with the clock.

What is written and not sent is a draft (`Model/InputDrafts.swift`), as Telegram keeps a chat's input state: the
message being written and, beside it while an edit is open, the edit's text and the message it edits. Drafts are on
disk, written a moment after each change and when the app leaves the foreground, so a crash loses at most the last
keystrokes. Opening the chat restores both; cancelling or sending the edit brings back the message that was being
written. The chat list shows Telegram's red "Draft:". New Chat keeps one draft of its own.

## What the user sees

Telegram's sending, with the agent's two ways of reading a message.

- **Idle**: the bubble appears at once with Telegram's clock (ChatMessageDateAndStatusNode), then two checks once the
  message is in the transcript. The model reads at once, so two checks, as in a bot chat.
- **Working**: Send steers. The message goes to a panel at the top of the input field, Telegram's accessory panel
  (ChatInputMessageAccessoryPanel, iOS 26): an accent line, "Steer" or "Follow-up", the text, the clock while it is on
  its way and a check once the server holds it, and a close button that withdraws it. Several queued messages split the
  line into segments, as the pinned messages bar does. When the model gets it, the panel closes and the bubble rises
  from it into its place in the transcript.
- **Long press Send while working**: Telegram's send menu, with **Send as Follow-up** in place of Schedule Message, and
  **Stop and Send**.
- **Tap the panel**: the message's actions in Telegram's context menu: Edit (it comes back to the field), Send as
  Follow-up or Send as Steer, Send Now (stops the agent and sends it), Delete. With several queued, the menu lists them
  first.
- **Stop**: the run ends and the queued messages come back to the field in order, as pi's Escape returns queued
  messages to the editor. Send Now does the same with the others.
- **Refused**: Telegram's red badge beside the bubble (ChatMessageDeliveryFailedNode), which opens the reason with
  Resend and Delete. The chat list shows the red badge too, and the clock for a message on its way.
- **No connection**: the chat's title says "Connecting…" as Telegram's does, and messages keep their clocks.
- **In the background**: the app keeps running briefly to finish sending, as Telegram does.

## Testing

`ios/TauUITests/SendingUITests.swift` runs these against the dev server (`ios/scripts/devserver.sh start`: the dev/echo
model on port 7979, where `$ sleep N` keeps the agent busy). The offline, kill and refusal cases need the server
stopped, started and wiped on cue, which the test asks for through files in `/tmp/tau-ui` and
`ios/scripts/sending-tests.sh` answers.
`server/test/server.test.ts` covers ordering, withdraw races, refusals, and idempotent creates.
