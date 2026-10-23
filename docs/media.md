# Images

Images live in entries, as the model has them: a photo the user sent is an image block of its `pi.user` message, an
image a tool returned (the read tool's, for an image file) one of its `pi.tool-result`. Both are base64, up to 4.5 MB.

## By reference

A client that says so in `hello { media: true }` gets every entry with its images replaced by references
(`server/src/media.ts`):

```ts
{ type: "image", mimeType: "image/png", media: { entryId, index, bytes, width?, height? } }
```

`index` counts the entry's images in order; `width` and `height` come from the image's header, read without decoding
it. `media.get { conversationId, entryId, index }` -> `{ mimeType, data }` returns one. A transcript then syncs in
kilobytes however many photos it has, and the phone decodes only what it shows. A client that does not ask (the share
extension, older apps) gets the data inline, as before.

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
  their images. A photo this phone sent is cached from its own copy when its entry arrives, so it is never fetched back.
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
