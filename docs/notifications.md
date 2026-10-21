# Notifications

When an agent answers, the user hears about it once, where they are: a banner in the app if it is open, a push if
it is not, nothing if they are looking at that chat. As Telegram does it (ApplicationContext and its push service),
with the decision on the server and the delivery replaceable.

## What notifies

The end of a run in a top-level conversation: a final answer, or a run that failed. A subagent's conversation does
not notify; its answer goes to the conversation that started it, whose own answer then does. A tool round does not
end a run.

## In the app

`ServerStore` turns a `dialog` push into a `ChatAnswer` when the dialog's last entry is a newer assistant entry, the
run is over, and the chat is unread. The first list after a connect only sets the baseline: answers that came while
the app was away do not turn into banners. `AppDelegate.observeAnswers` then drops it if the app is in the
background or the chat is on screen, and otherwise shows Telegram's banner (`NotificationContainerController`, copied
from TelegramUI, with `ChatNotificationItem` after ChatMessageNotificationItem) in the window's top level. A tap
opens the chat; banners of one chat replace each other. Settings > Notifications turns banners and their vibration
off.

## Pushes

`server/src/notifier.ts` sees every run end in the commit stream. It pushes when a target is set and no client is in
the foreground: each client reports `client.presence { active }` on connect and whenever the app becomes active or
resigns, and a closed connection counts as inactive. So a phone with tau open gets the banner and no push, and one
with tau closed (its socket gone) gets the push.

Today the target is ntfy: Settings > Notifications turns pushes on per server, which stores
`{ server: "https://ntfy.sh", topic }` (a random topic) in `tau.settings`. The ntfy app subscribes to the topic and
shows the push; its tap opens `tau://chat?server=<serverId>&id=<conversation>`, which the app routes to the chat on
the server with that database ID.

Apple's push would be a second target beside ntfy, not a change of design: the app registers for remote
notifications and sends its device token in a `notifications.register { kind: "apns", token }` request; the
notifier sends to every registered token through APNs with the same title, text and URL (as `userInfo`), and the app
opens the chat from `UNUserNotificationCenterDelegate` the way it opens the URL now. Removing ntfy is then deleting
its target. It needs a paid Apple developer account, for the push entitlement and an APNs key.
