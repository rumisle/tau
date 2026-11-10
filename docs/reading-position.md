# Reading position and turns (design)

Where a chat opens, what counts as seen, and moving through a long transcript by turns. Agreed with the user; to be
built. The code today: `ChatControllerNode` (`isAtBottom`, `currentScrollState`, the transaction's `scrollToItem`),
`ChatController.saveScrollState` and `markSeen`, `ServerStore.markSeen` (the server's `MetaDoc.read`, which counts
`unreadCount`).

## What there is now

- Leaving a chat (or the app going to the background) saves the message at the bottom of the screen and its offset,
  or **nil when at the end**; opening restores it, nil opening at the end.
- At the end (within 120 pt) the list follows what arrives, a streaming answer included; scrolled back it stays, and
  the down button counts committed rows that arrived below.
- A message the user sends scrolls to the end.
- Opening a chat, or anything arriving while it is on screen with the app active, marks **everything** read
  (`markSeen` sends the newest entry), whatever was on screen.
- Tapping the status bar scrolls to the top (UIKit's default for the list's scroll view).

The trouble: leave right after sending, or while the answer streams, and the saved position is "the end"; the end has
moved on by the time the user is back, so the chat opens at the end of a long answer and the user scrolls up to find
where it started, or where they were.

## Terms

- **A turn** starts at a message of the user's and holds everything until the next one: thinking, tool calls, subagent
  cards, answers. Its start is the user's message. (Compaction cards are not turn starts for now.)
- **Seen** means it was on screen, the chat in front and the app active. Not "the chat was opened".
- **The seen frontier**: the newest point the user has seen, a row and how far down it (a long answer may be seen half
  way). It only moves forward.

## Seen, precisely

- The frontier advances as rows (or, for a tall row, its lines) are laid out inside the visible area while the chat is
  on screen and the app is active. A streaming row moves it as its text appears on screen, not as it arrives.
- Leaving the chat and the app leaving the foreground are the same: nothing is seen while away, and the list does not
  follow the end while the app is inactive.
- The server's read marker (`conversation.read { at }`) is the newest entry whose row has been seen (at all), so the
  list's unread count is what the user has not looked at. Reads stay throttled as now (`readInterval`).
- The frontier within a row is kept on the phone with the scroll state (`ChatScrollState` grows a frontier); the
  server keeps only the entry.

## Where a chat opens

One mechanism, the scroll memory, without the "end" case:

1. Leaving saves what is on screen (the row at the bottom and its offset), at the end too. No nil for the end.
2. Opening restores it.
3. If what directly follows the restored view is unseen (the frontier is at the view's bottom and there is more below),
   the view moves down so the last seen lines sit near the top of the screen, a line or two of context above them, and
   the unseen content fills the rest.

| Left | New content since | Opens |
|---|---|---|
| At the end, right after sending | yes | the user's message near the top, the response below |
| At the end, in the middle of the response | yes | the last lines seen near the top, the rest below |
| At the end | no | as left |
| Scrolled back reading older rows | yes | as left (what follows is already seen); the down button shows, with its count |

No "new messages" divider.

While the chat stays on screen and the app active, at the end, the list follows what arrives, as now. A message the
user sends still scrolls to the end.

## Turn navigation and the down button

- **Tapping the status bar** goes to the start of the previous turn: the start of the turn above the one at the top of
  the screen (the user's message at the top). Repeated taps go up turn by turn; a light haptic per jump. At the first
  turn it scrolls to the top, as now.
- **A return stack**, Telegram's `ChatHistoryNavigationStack`
  (TelegramUI/Sources/ChatHistoryNavigationStack.swift, ChatControllerNavigateToMessage.swift,
  ChatControllerLoadDisplayNode.swift):
  - A jump pushes where it left from: the newest row visible before it.
  - **A return point that becomes visible is dropped**: whenever the newest visible row changes, points not newer than
    it are removed (`maxVisibleMessageIndexUpdated` → `filterOutIndicesLessThan`). So a jump to a turn on the same
    screen keeps nothing; scrolling down by hand past a point drops it; there is no distance threshold.
  - **The down button** goes to the last return point (without pushing), and with none to the end, as now. Long press:
    to the end directly.
- No up button, no second down arrow, no list of turns (add when needed).
- Opening a chat that moves the view down to unseen content (above) pushes nothing; the down button goes to the end.

## Tests

UI tests with the dev model (and `/tmp/tau-dev-answers.json` for long answers):

- Leave right after sending, let a long answer finish, reopen: the user's message is near the top.
- Watch an answer stream past a screen, leave in the middle, let it finish, reopen: the last lines seen are near the
  top, nothing seen is above the fold twice.
- Scroll back, leave, let something arrive, reopen: exactly where left; the down button with its count.
- Background the app while at the end of a streaming chat, let it finish, return: as reopening.
- Status bar taps: turn by turn up; down button back point by point; a jump within one screen leaves the down button
  going to the end; scrolling by hand past a point drops it.
- The list's unread count after half-seeing a chat counts the unseen answers only.

## As built

What turned out different from the design above, and why.

- **Seen while inactive, the list not following.** The list goes on laying out what arrives while the app is inactive
  (holding it still would mean holding a streaming row's growth and every insertion still, which the list does only by
  following its end), and the view is put back when the app is active again: as it was left, and then as reopening
  (below). What arrives meanwhile is not seen: the frontier moves only while the chat is on screen and the app active.
- **A user message from elsewhere** (another device, a script through the protocol) no longer scrolls to the end: only
  one sent from this phone, on its way or leaving its queue, does. One from elsewhere comes in as any other row, so a
  chat scrolled back stays there.
- **A streaming row's frontier** is how far down its laid-out height is on screen: its reveal trails that by a fraction
  of a second, which the frontier does not wait for.
- `markSeen(id)` (everything) stays for a reply sent from a notification; the chat itself calls
  `markSeen(id, through: entryId)`.
- **Opening from the phone's copy.** A chat opens at once with the transcript the phone has, which may lack what
  finished while it was closed (the answer streaming when the user left): the saved view is put back from it, and
  whether what follows it is unseen is judged again when the server's transcript is in, unless the user scrolled
  meanwhile. A saved message not in the copy waits for the server's transcript before it is given up.
- **What came while away shows as written**: an answer still being revealed when the user left (or catching up, after
  the background) shows the rest at once when the chat is put back, so the view is judged on its whole height. Revealed
  in big steps at the list's pace, it moved what was put back.
- **A height animation left running.** Telegram's list let a row's height animation from an earlier animated update
  go on after an update without animation, setting the row back toward its old height: back while the answer still
  streamed, the rest shown in full shrank under the view, and when it shrank by more than lay below the screen the list
  went to the end and followed it. An update without animation now ends a running one (Display's `ListView`).
- **The down button's count** is the messages and answers after the frontier, rather than those that arrived while the
  list was not at the end: the same while the chat is open, and right after opening a chat scrolled back.
- **The agent's waiting row** (the τ) is never the saved view's anchor: it is gone by the time the chat opens again.
- **The status bar did nothing in a chat** before (not UIKit's scroll to top, as the design's "now" says: the list's
  own scroll view does not take it, and Telegram's navigation controller asks the top controller's `scrollToTop`,
  which the chat had not set). Now it goes to the previous turn, animated, with `UIImpactFeedbackGenerator(.light)`.
- **A return point is a view**, the row at the bottom of the screen and its offset, as the scroll memory keeps one,
  not a message: answers are often taller than the screen, and Telegram's message index would bring back the row,
  not where the user was in it. It is dropped, as designed, when its row is on screen again. So the first jump up from
  the end of a long answer keeps nothing (the answer's start shows under its question where it lands), and the down
  button retraces the jumps: three up from the end, two points, then the end.
- **A jump to a turn on the same screen** pushes nothing (rather than pushing and dropping it as its row is on screen
  during the scroll): the same as designed, without the stack changing mid-animation. The stack keeps still while a
  jump animates.
- **The down button held** goes to the end through Telegram's context gesture on the button (its tap recognizer would
  take a plain long press as a tap), with a light haptic; the return points are left behind.

