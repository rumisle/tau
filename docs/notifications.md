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

`server/src/notifier.ts` sees every run end in the commit stream. It pushes, with the account's APNs key, when no client is in
the foreground: each client reports `client.presence { active }` on connect and whenever the app becomes active or
resigns, and a closed connection counts as inactive. So a phone with tau open gets the banner and no push, and one
with tau closed (its socket gone) gets the push. A socket the server hears nothing on for 45 seconds is closed
(docs/protocol.md): without that, a phone that lost its network while tau was open would hold every push back until
its dead TCP connection timed out, which, with nothing to send on it, is never.

### Apple's push

A server started with the account's APNs key (`--apns-key ~/.config/tau/AuthKey_<key id>.p8 --apns-team <team id>`,
owner-only like the token) sends Apple's pushes itself (`server/src/apns.ts`): a provider token the key signs (ES256,
renewed every 50 minutes), one HTTP/2 connection per environment, opened again when Apple closes it. `hello` says
`apns: true`.

- **Registration.** The app asks for permission at launch (not under the UI tests), registers for remote notifications,
  and tells every server with `apns` its device token in `devices.register { deviceId, environment, topic, token,
  alerts, pushToStart, pushKey }` (`Notifications/PushRegistration.swift`), on each connection and when a token changes. The
  device ID is per install; the environment is the signing profile's `aps-environment` (Xcode's builds: the sandbox);
  the topic is the bundle ID. The server keeps them in `tau.devices` (`server/src/devices.ts`), drops a token Apple
  answers 410 or BadDeviceToken for, and gives a token to one device only (a reinstall's new ID replaces the old).
- **The push.** The run's end, as above, to each device whose `alerts` is on: the chat's title and the answer's text
  (400 characters), `thread-id` `<serverId>:<conversation>`, category `chat`, `mutable-content`, and
  `tau { server, id, url }`.
- **As the chat's message.** The notification service extension (`ios/TauNotifications`) makes it a communication
  notification, as Telegram's NotificationService does: an incoming `INSendMessageIntent` from the chat, with its
  letter avatar (`Tau/Common/LetterAvatar.swift`, the chat list's palette, colored by the app's ID for the chat, which
  takes the server's slot from the shared keychain's server list) where the app icon would be.
- **Tap and Reply.** A tap opens the chat (`UNUserNotificationCenterDelegate`); Reply sends the text to the chat as the
  composer would, marks it read, and keeps tau running in the background until the server has the message (the outbox
  keeps it on disk either way). Opening a chat removes its delivered notifications. In the foreground the system shows
  none: the server does not push then, and the app's banners do it.
- **Settings > Notifications** turns a server's answers off on this phone (`alerts: false`), and shows Turn On in
  Settings when iOS's permission is off.
- **A chat in the Live Activity** (docs/live-activity.md) does not ring twice: when its finish is the activity's update,
  with its alert, the device gets no notification for it.

### Through a relay

The APNs key works for every app of the account's team, so it stays with its owner. A server of anyone else's that the
app connects to sends its pushes through a relay instead (`--push-relay <url> --push-relay-token-file <path>`,
`server/src/relay.ts`): `POST /push { token, environment, type, topic, priority, payload, collapseId?, expiration? }`
with `Authorization: Bearer <the server's relay token>`, answered with Apple's `{ status, reason?, id? }` as
`Apns.send` resolves. The relay (`relay/`, a Cloudflare Worker) holds the key, signs the provider token, takes only
tokens it was given (one per server, named for its log), and only the app's topic and its Live Activities'.

### Sealed

The app makes a key once per install (32 random bytes in the shared keychain, `ShareGroup.pushKey`) and gives it to every
server as `pushKey`. To a device with one, an answer's push says only "tau / New message" in the clear, with
`tau { server, id, sealed }`: `sealed` is `{ title, body, url, failed }` in AES-256-GCM (`server/src/seal.ts`; the
12-byte nonce, the ciphertext, the 16-byte tag, base64, which CryptoKit's `AES.GCM.SealedBox(combined:)` reads). The
notification service extension opens it and shows the chat's title and answer; when it cannot, the clear text shows.
A relay, and Apple, see the chat's number and ciphertext. Live Activity pushes are not sealed: ActivityKit reads their
content state itself, with no extension in between, so a chat's title and step go to the relay as they are.

The push's tap opens the chat's link too, `tau://<serverId's first eight>/<conversation>` (docs/links.md), which the
app routes to the chat on the server with that database ID.
