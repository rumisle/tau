# Sharing to tau

`ios/TauShare` is a share extension: Share from any app, then tau, and its sheet lists the chats as avatars (Telegram's
ShareController layout), the chat list's order with pinned chats first, New Chat leading, with a search over titles and
projects. What is shared (text, a link, up to ten photos, up to ten files) shows at the bottom with a comment field; Send goes to every
chat picked, with a count on the button when it is more than one.

- **New Chat** starts a chat in a project picked from the recent ones ("New chat in tau ▾"), titled by the server after
  its first answer.
- **A chat whose agent is working** gets the share as a follow-up: something shared should not turn a run aside.
- **It sends itself**: its own WebSocket to each server (`hello`, `conversation.create`, `conversation.submit`), without
  the app. What it cannot send (the server out of reach) it leaves for the app, which sends it through its outbox the
  next time it opens, as it sends anything.

The app and the extension exchange the servers and chats, and unsent shares, in a shared keychain group
(`$(AppIdentifierPrefix)$(TAU_BUNDLE_ID).shared`), not an App Group: a free developer account's profiles allow the
team's keychain groups but not App Groups. Unsent photos are kept at most four, 1280 px a side, to fit.

Files (PDFs, archives, videos) and photos are uploaded (docs/files.md), once for all a server's chats, and named by the
messages. What the server refuses
(a file too large) the sheet says, and stays open. Unsent files are not left for the app: the keychain cannot hold
them, so the sheet says to share them again.
