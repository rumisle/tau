# Links to chats and messages

tau's own links name a chat, or one message of it, on a server named by the first eight characters of its ID
(`hello`'s `serverId`), which stays as the server's address changes (`ios/Tau/Common/TauLink.swift`):

```
tau://d0003019/1523               the chat
tau://d0003019/1523/880           its entry 880; history only grows, so an entry is for good
tau://d0003019/1523/880?q=words   and those words of it, marked
tau://new?text=…&server=d0003019&model=anthropic/claude-opus-5-5
                                  a new chat, its field filled in; the server and model when given and there
```

- **Copying**: the chat menu's first row (the title, from ⋯) copies the chat's link; a message's menu has Copy Link, as
  a channel message's has in Telegram. Telegram's "Link copied to clipboard" says so.
- **Opening**: a tap on one in a chat, a push, the Live Activity, or one from another app (`tau` is the app's URL
  scheme) opens the chat, at the message, marked as a search's match is. `tau://new` opens a new chat with its field
  written, for Shortcuts or an answer that suggests going on elsewhere; a link never changes anything by itself.
- **In a message**: a link to a chat this phone has shows as a card, in Telegram's quote: the chat's title over what it
  says there, the message's own words for a message's link (from the phone's copy, else asked of its server once, by
  `conversation.history`), the chat's latest for a chat's. A tap on the card opens it. The card is placed where the
  link is, the same in the user's messages and the agent's (`MarkdownText.placingCards`):
  - after the block that has the link: its paragraph, its list item, a whole quote or code block, a table;
  - in place of a block that is the link and nothing else (written out, or a Markdown link alone), not under it;
  - several links in one block: their cards after it, stacked in the order of the links;
  - a link written more than once: one card, at its first block;
  - inline, the link stays tappable text and its card follows the block.

  At most 8 cards a message. Cards come once a message is whole (not while it streams), and once the phone has the
  chat and its server (at launch, when its list and its servers' hello come). Selections and copies leave them out.
- **In the field**: one written there is previewed above the text, as Telegram previews a link, in the accessory
  panel's place; its ✕ hides the preview of that link while the chat is open.

The message is sent as written: the model reads the link as text. Reading the linked chat is for later.
