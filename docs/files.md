# Files

Files the user sends and files the agent sends back. The model gets the user's files as paths, so it can read,
convert or run anything on them; photos it also sees. The agent sends a file with the `send_file` tool; the app shows
it as Telegram shows a document, and fetches it on a tap.

## Where they are kept

Beside the database, for as long as it is: `tau.db` keeps its files in `tau.files/` (`server/src/files.ts`). By default
that is `~/.local/share/tau/tau.files`; the dev server's is `/tmp/tau-dev.files`; in memory, a temporary directory.

```
tau.files/<id>/<name>      the file: read-only (0400) in a read-only directory (0500)
tau.files/.pending/<id>    an upload no message refers to yet
```

- **Private**: the data directory and `tau.files` only their owner may enter (0700), whatever the umask. Not `/tmp`,
  where other users may look.
- **Kept for good**: a message refers to its files by path, and durable deletes no conversation (Hide keeps it), so a
  file an entry names is never removed. An upload is pending until then (`.pending/<id>`): swept a day after it came
  when no message named it (its message failed), a week after a message did when no entry names it (the message was
  withdrawn before it reached the model). Before one goes the store asks the search index, which records the files each
  entry names (`file_ref`): one an entry names is kept, whichever message it was uploaded for, as an edit sends its
  message's files again by ID.
- **Read-only**: a model's command cannot change or remove one by accident; to change a file it copies it, as the
  prompt says.
- **IDs** are 128 random bits, hex. **Names** are the file's own (the model knows a PDF by its name, and copies keep
  it), cut to their last component without control characters, at most 200 bytes; each file has a directory of its
  own, so names never collide.
- **At most 1 GB** a file (`HostOptions.maxFileBytes`); `hello` says the limit.

## Over HTTP

On the WebSocket's port, behind its token (`server/src/http-files.ts`):

- `POST /files?name=<name>`, the bytes as the body -> `201 { id, name, mimeType, bytes, width?, height? }`. Streamed to
  disk; past the limit, `413` and nothing stays. The type is the file's: an image by its first bytes, the rest by
  extension.
- `GET /files/<id>` (`HEAD`, `Range`) -> the file, with `Content-Disposition` and `Cache-Control: immutable`: a kept
  file never changes.

## What the model gets

`conversation.submit` names a message's uploads: `attachments: [{ id, as?: "image" | "file" }]`; `content` may then be
empty. The message's first text block names each file by path, as `pi @file` does:

```
<attachments>
<image name="/home/me/.local/share/tau/tau.files/7f3a…/photo.jpg" type="image/jpeg" bytes="812044" width="2000" height="1500"/>
<file name="/home/me/.local/share/tau/tau.files/a81c…/report.pdf" type="application/pdf" bytes="1204331"/>
</attachments>
```

- An `<image>` (sent `as: "image"`: a JPEG, PNG, GIF or WebP, to a model that takes images) is in the message as an
  image block too, after this one, in the same order; past durable's limits (2000 pixels a side, 4.5 MB) shrunk by its
  Photon image processor, which the read tool uses too. One that cannot be is a `<file>`. Anything else is a `<file>`, only named: a model
  without image input still gets a photo, as a path.
- The system prompt says how to read them.
- The chat list, search and titles read the message without the block (`server/src/attachments.ts`): a message of
  files alone reads as its file's name, or "Photo".
- A file the server does not have is refused with `file_missing`: the app uploads it again.

## What the agent sends

`send_file { paths }`: up to ten files, absolute or relative to the working directory (`server/src/send-file.ts`).
Each is copied into the store as it is now (a clone where the file system makes one), so later changes do not reach
the user; a directory is refused. A copy's ID comes from the call, so a call run again after a restart finds its copy.
The result names what was sent, and its `details.files` carry each one's `{ id, name, mimeType, bytes, width?,
height? }`. Called from a code mode script, whose calls' results stay out of the transcript, it also writes them in a
`tau.files` entry (docs/codemode.md).

## In the app

- **Sending**: the attachment menu's File (the document picker), Share from another app (the share extension uploads
  them itself; with the server out of reach it cannot keep files for the app, and says so), and the photo picker's Send
  as File (its `...` menu,
  as Telegram's), which sends the photos and videos as they are, the original's quality. Photos sent as photos are
  2000 pixels at most (docs/media.md).
- **The outbox** copies each file beside itself, uploads them one by one (`Server/FileTransfer.swift`), then submits the
  message with their IDs (`Server/Outbox.swift`). Each upload's ID is kept on disk; no answer is tried again, as a
  submit is; a file the server refuses fails the message. An edit sends the message's files again by their IDs, its
  photos too: nothing is fetched, nothing encoded again.
- **A file's row**, as Telegram's ChatMessageInteractiveFileNode: its SemanticStatusNode, a download arrow, a
  transfer's progress ("1.2 MB / 4.8 MB"), or the document icon once here; the name; the size. A tap fetches the file,
  stops fetching it, or opens it in Quick Look, which shares it, saves it to Files or opens it elsewhere (Telegram's
  DocumentPreviewController). One of the user's is in the bubble above the caption; the agent's are on the background
  where the call is, with no card, images as an album (the photos' viewer pages through them) and files as rows, one
  under another, as Telegram groups documents.
- **Fetched files** are kept in Caches by ID under their name; a file this phone uploaded is never fetched back.
  Data and Storage counts them with the images, and Clear Cache clears them.

## Trying it

The dev model sends files for `!send <path> [<path>…]`. `server/test/files.test.ts` covers uploads, ranges, what the
model gets, `send_file` and the sweep; `SendingUITests.testFiles` sends a file from the app (`-attachFile <path>`, as
the document picker gives one), has the agent send two back, fetches one and opens it.
