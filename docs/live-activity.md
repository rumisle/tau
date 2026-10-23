# Live Activity and the Dynamic Island

What it is for: the question "do I need to go back to the phone yet?". After sending an agent a task the user puts the
phone down; the activity says whether it is still working, whether there is an answer, or whether something needs them.
Everything else is noise, so it shows only that, in as few pixels as will say it.

## Which chats

The ones the user is waiting on: a chat gets a row when a message is sent to it from this phone (the composer, a
notification reply, the share sheet later), and keeps it while the run that message started, or one it leads to (a
subagent's report starts another), goes on. Opening a chat, or the activity, means it was seen: the row goes. Subagents
have no rows of their own; their parent's row says "2 subagents working".

One activity per server, not one per chat: three cards stacked on the lock screen are noise, and the island shows two
at most anyway. Per server because its server pushes its updates, and an update replaces the whole activity: two servers
pushing one activity would undo each other's rows. It lists up to three chats, the newest first, and "+2 more"; with
one chat it looks like that chat's own.

## Content

Per chat: its title, its state (working, done, failed), when its run started, and when it ended. While it works, the
step it is on, in a few words ("Running npm test", "Editing ChatController.swift", "Thinking", "2 subagents working"):
a step shows once it has lasted a couple of seconds, so quick tools never flicker past. Done: the answer's first line.
Failed: the error in a few words ("Overloaded", "Rate limited").

Time is in minutes, never seconds: "4 min", nothing in the first minute. iOS 18 counts it in the view itself
(`SystemFormatStyle.DateOffset` with minutes and hours), so it moves without updates; on iOS 17 it is what the last
update said.

## Look

tau's pink (the icon's accent, `#F2569A`) is the only color besides the avatars: minutes, "Working", the done check;
red only for a failure. Each chat appears as it does in the list, its letter avatar in Telegram's gradient (the same one,
picked by its ID); a working chat has a pink ring around it, as a story does in Telegram, a done one a pink check on
it, a failed one a red mark. The ring's room is kept either way, so avatars and titles line up whatever the states. The
lock screen card is dark, as the island, so both read the same.

## Dynamic Island

- **Compact**: the pink τ on the left. On the right: one chat working, its minutes ("4m", "<1m"); several, how many
  are, in a pink disc; all done, a pink check; one failed, a red mark.
- **Minimal** (another app's activity shares the island): the τ, or the check or the mark.
- **Expanded** (long press): a top line either side of the camera, the τ and "Working" or "2 working" on the left, the
  minutes (one chat), "+1 more", or the check on the right; under it up to two chats, avatar, title, state, and the
  step or the answer's first line, the avatars under the τ. No buttons: to stop an agent, open the app.

## Lock screen

The same rows, two at most and "+1 more" under them in line with the titles (an activity gets 160 pt). A tap opens that
chat (with one chat, the whole card does).

## Completion

The update that marks a chat done carries an alert: the island opens for a few seconds with "Done · worked 12 min" and
the answer's first line, with the notification sound if notifications are on. It replaces that chat's push, so the phone
does not ring twice. Done rows stay until seen, or 30 minutes; when none is left the activity ends.

## Updates while tau is away

iOS lets only the app itself, or Apple's push service, update an activity. While tau runs it updates its activities
from the chat list. A server with the account's APNs key (docs/notifications.md) takes over while no app is in the
foreground:

- The app starts each activity with `pushType: .token` and gives its server the activity's push token and all its rows
  (`liveActivity.update { deviceId, activity: { id, token, rows, accent } | null }`), each time they change.
- The server (`server/src/notifier.ts`) watches those chats' runs and their subagents'. A chat that starts working again
  gets an update at priority 5; one whose run ends with nothing left working is marked done (or failed) with the answer's
  first line, in an update at priority 10 with the alert, "Done · worked 12 min · …", which replaces that chat's
  notification on the device. When none is left working, the server ends the activity half an hour later, as the app
  would, unless it changed by then. Each push's `timestamp` is later than the last.
- An activity the server keeps up to date is not stale while it works, and the app gives no alert of its own for it.
- A notification's reply sends from the background, where an activity cannot start: the app asks its server
  (`liveActivity.start`), which updates the activity it has, or starts one with the device's push-to-start token
  (iOS 17.2, `devices.register { pushToStart }`). The app adopts an activity it did not start, at launch or while it
  runs: its rows, and its push token.
- An activity that ended or was dismissed takes its finished rows with it; a chat still working gets a new one once tau
  is open.

Without the key nothing updates an activity after the half minute iOS gives the app on leaving. The minutes keep
counting (iOS 18), but a finish is not seen until the app opens again; the activity says so once it is stale ("Open
tau for the latest"), two minutes after the last update.

## Not done

A step for each chat needs its live state, which the app has only for chats it has open; rows show "Working" or the
subagents otherwise. The server could put a short step in each Dialog for this.
