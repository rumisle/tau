# Images

Images live in entries, as the model has them: a photo the user sent is an image block of its `pi.user` message, an
image a tool returned (the read tool's, for an image file) one of its `pi.tool-result`. Both are base64, up to 4.5 MB.
A photo the user sent is also a file the server keeps (docs/files.md), named in the message's attachments block.

## By reference

Clients get every entry with its images replaced by references (`server/src/media.ts`):

```ts
{ type: "image", mimeType: "image/png", media: { entryId, index, bytes, width?, height? } }
```

`index` counts the entry's images in order; `width` and `height` come from the image's header, read without decoding
it. A transcript then syncs in kilobytes however many photos it has, and the phone decodes only what it shows.

The app fetches a user's photo as its file, `GET /files/<id>` (the ID is the directory in the attachments block's path),
and the others with `media.get { conversationId, entryId, index }` -> `{ mimeType, data }`: a tool's images, and photos
of messages older than files. Over HTTP a photo goes beside the socket, on its own connection: a few megabytes of base64
in one frame would hold back everything behind it on the socket, the streamed answer and the pong that tells the socket
is alive (at 0.5 Mbps, two photos delayed a pong 5.5 seconds; past 10 the app takes the socket for dead).

## In the app

- **Sent at most 2000 pixels on the long side**, as JPEG at 0.8 (`Tau/Share/ImageEncoding.swift`), by the app and the
  share extension alike: pi's own limit for images, within what the high-resolution Claude takes (2576) and the 2000 a
  request of more than 20 images allows each. Larger only costs: GPT-5.5 and later take an image as it is by default
  (`detail: "auto"` is `original`) and bill its 32-pixel patches, a 48-megapixel photo is refused outright, the
  others shrink it themselves, and every turn sends it again while the database keeps it.
- **Laid out before it arrives**: from the reference's size, as Telegram lays out media it is still downloading. The
  placeholder is the bubble's media color; past a quarter second a spinner shows in a dimmed circle; the photo fades in.
- **Where**: a user's photos in their bubble, as Telegram's album mosaic (`chatMessageBubbleMosaicLayout`); a tool's
  images in its card, under what the tool said, as an album too. A tap opens either in the media viewer, which pages
  through the chat's photos and tools' images and loads the one it shows at full size.
- **Loading** (`Tau/Server/MediaLoader.swift`): each image once, then from Caches; entries never change, so neither do
  their images. A photo this phone sent is cached from its own copy, by its file, when its entry arrives, so it is never fetched back.
  Another database behind the same address (its `serverId` changed) clears the cache, since its entries reuse the IDs.
- **Decoding**: off the main thread with ImageIO, downsampled to 1280 pixels for the chat and 4096 for the viewer. What
  is decoded is checked first: PNG, JPEG, GIF or WebP only, at most 80 megapixels; anything else shows a photo glyph.
  Nothing is fetched but images of entries: a tool's output never makes the app load a path or a URL.
- **Editing** a message with photos sends them again with the edit: the store fetches them from the cache or the
  server first.
- Settings > Data and Storage counts the cached images with the transcripts, and Clear Cache clears them.

## Trying it

The dev model reads a file for `!read <path>`; `SendingUITests.testModelImages` reads `/tmp/tau-read-test.png`, and
`testPhotoAlbums` sends albums of two, three and five, captioned, and edited.

## Storage (open, to investigate)

Images make most of a busy database. On a server used daily for a month, 459 MB of its 490 MB were images in the read
tool's results: 391 of them, about 2 MB each (screenshots), base64 in the entries. Each also stays in the model's
context until a compaction.

- **Compressing** them does little: PNG, JPEG and WebP are compressed already; zstd would win back about the quarter
  base64 adds.
- **Smaller images** do most: the read tool takes up to 2000 × 2000 pixels and 4.5 MB (durable's
  `DEFAULT_IMAGE_LIMITS`), but Anthropic scales down any image whose long edge is past 1568 pixels before the model
  sees it (its vision docs), so the pixels beyond are stored for nothing. Read's `resize` at a long edge of 1568 would
  store about half, with the model seeing the same. Other providers' limits to check before choosing the number.
- **Cost to the model** changes with neither: an image is priced by its pixels after that scaling (at most about 1,600
  tokens on Anthropic's), and sent again from the prompt cache at the cache's price.
- **The structural fix**: images kept as files beside the database (docs/files.md), the entry holding a reference,
  the same image stored once. Entries carry the model's messages, so this is durable's storage to change, not tau's.

First step when this is picked up: read's limit at 1568, one setting, with the providers' limits checked.
