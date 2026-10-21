# Live Activity and the Dynamic Island

What it is for: the question "do I need to go back to the phone yet?". After sending an agent a task the user puts the
phone down; the activity says whether it is still working, whether there is an answer, or whether something needs them.
Everything else is noise, so it shows only that, in as few pixels as will say it.

## Which chats

The ones the user is waiting on: a chat gets a row when a message is sent to it from this phone (the composer, a
notification reply, the share sheet later), and keeps it while the run that message started, or one it leads to (a
subagent's report starts another), goes on. Opening a chat, or the activity, means it was seen: the row goes. Subagents
have no rows of their own; their parent's row says "2 subagents working".

One activity for tau, not one per chat: three cards stacked on the lock screen are noise, and the island shows two at
most anyway. It lists up to three chats, the newest first, and "+2 more"; with one chat it looks like that chat's own.

## Content

Per chat: its title, its state (working, done, failed), when its run started, and when it ended. While it works, the
step it is on, in a few words ("Running npm test", "Editing ChatController.swift", "Thinking", "2 subagents working"):
a step shows once it has lasted a couple of seconds, so quick tools never flicker past. Done: the answer's first line.
Failed: the error in a few words ("Overloaded", "Rate limited").

Time is in minutes, never seconds: "4 min", nothing in the first minute. iOS 18 counts it in the view itself
(`SystemFormatStyle.DateOffset` with minutes and hours), so it moves without updates; on iOS 17 it is what the last
update said.

## Dynamic Island

- **Compact**: the pink τ on the left. On the right: one chat working, its minutes; several, how many are working;
  something done and not seen, a green check; failed, a red mark.
- **Minimal** (another app's activity shares the island): the τ, or the check or the mark.
- **Expanded** (long press): each chat's title, state and minutes, and its step or the answer's first line. No buttons:
  to stop an agent, open the app.

## Lock screen

A card: a row a chat, the title on the left and the minutes or "Done" on the right, the step or the answer's first line
under it in the secondary color. A tap opens that chat (with one chat, the whole card does).

## Completion

The update that marks a chat done carries an alert: the island opens for a few seconds with "Done · worked 12 min" and
the answer's first line, with the notification sound if notifications are on. It replaces that chat's push, so the phone
does not ring twice. Done rows stay until seen, or 30 minutes; when none is left the activity ends.

## Without APNs (now)

iOS lets only the app itself, or Apple's push service, update an activity. tau has no APNs yet (a free developer account
cannot send them), so the activity is updated while the app runs, plus the half minute iOS gives it on leaving. After
that the minutes keep counting (iOS 18), but a finish is not seen until the app opens again; the activity says so once
it is stale ("Open tau for the latest"), two minutes after the last update. With APNs the server sends the updates
(`liveactivity` pushes, the activity's push token registered with it), and completion arrives whatever the app is
doing; the views stay as they are.

## Not done

A step for each chat needs its live state, which the app has only for chats it has open; rows show "Working" or the
subagents otherwise. The server could put a short step in each Dialog for this.
