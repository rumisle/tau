# Dictation

Speech to text in the composer (`ios/Tau/Chat/ChatInputPanelNode.swift`), through Aqua Voice
(`ios/Tau/Chat/AquaDictation.swift`).

## The composer

Laid out as Telegram's iOS 26 ChatTextInputPanelNode, with the text in it: the attachment button, then the field to
the screen's edge. At the field's end:

- **The microphone**, where Telegram keeps the sticker button (an accessory button: 32 pt, 4 pt from the end), always
  there: tapped, it listens until tapped again; held, while the finger is down (Telegram's hold-to-record). While it
  listens it is a disc in the accent color, in its own place, with Telegram's recording blob (AudioBlob's VoiceBlobView,
  set up as ChatTextInputMediaRecordingButton sets it up) moving around it with the microphone's level; the blob is over
  the field, not in its glass, so it is not clipped. Nothing else changes: Send stays beside it.
- **The action button** after it, Telegram's `sendActionButtons`: a 40 by 34 pt capsule in the accent color, in a 46 by
  40 pt box. **Send** once there is text (long-pressed, the send menu), **Stop** while the agent works on an empty
  field; with neither, no button.

The button comes in with Telegram's `updateActionButtons`: scaled up from 0.001 at the field's edge, faded in over
0.2 s and unblurred from 4 pt over 0.18 s, the send arrow coming from 22 pt left and 18 pt below. It leaves the same
way back, showing what it was. Between Send and Stop the icons trade places with a scale. The microphone moves aside for
the button as Telegram's accessory buttons move for Send, and the text keeps clear of both.

The words go in at the cursor, or at the end when the field is not being edited, a space apart from what is before
them, and replace themselves as they change. **Stop is immediate**: the microphone turns off and the disc is the
microphone again at once. The last words (about a second later) replace what was heard only if it is still there as
it was; an edit meanwhile wins. Send while listening sends what has been heard. Dictation that cannot listen says why
in a toast (no microphone access, no sign-in in the build, a connection that failed with nothing heard).

## Aqua Voice

Aqua's realtime API. Unofficial: it can
change without notice.

- `wss://realtime.aquavoice.com?token=<JWT>`, then a `start` message as Aqua's macOS client builds it (16 kHz,
  `pcm_s16le`, streaming, the model, language, dictionary and replacements), then `ready`.
- Audio as binary frames of 100 ms (3200 bytes of 16 kHz mono 16-bit PCM), each behind an 8-byte header: type 1,
  0, the frame number and 0 as big-endian 16-bit, and the size in KB.
- `document_update`'s `display_text_annotated` is the whole text so far, in segments `{ text, type }`. Aqua's app
  reads it with `displayTextToString(segments, includeUnprocessed = true)`: the texts joined, but `deleted` (words the
  model took back) and, with `false`, `unprocessed` (heard, not yet cleaned up); it pastes the first, as tau puts in the
  field. The other types (`normal`, `active`, `locked`, `consumed`, `out_of_window`) only style its live transcript. Not `wet_text`: that is only the current window, about half a minute, which starts over
  with a new `snapshot_id`, so a long dictation read from it lost everything before its last stretch. The update
  marked `final` after `stop_request { total_audio_chunks }` ends it.
- The microphone (AVAudioEngine, converted to 16 kHz) is captured from the tap on: what comes before `ready` is kept
  and sent then. Stopping sends a second of silence (at once: paced, it only held the text back a second more), then
  `stop_request`; the final text comes about 1.1 s later, and after 8 s the last one heard is kept. Aqua's app sends
  no silence (it waits up to 2 s for its audio to go out, then `stop_request`); tau's second matters only when the
  last word ends right at Stop.
- `session_duration` comes every 5 s with `status: "info"` (and `max_minutes: 10`); `"warning"` near the end, then
  `"expired"` or `"shutdown"`, on which the app stops as if Stop were tapped, keeping the text, as Aqua's does. Speech itself must
  go at its pace: the server, sent a recording at once, gives nothing.
- Aqua writes Chinese with a space between words; the spaces between two Chinese characters are taken out.

**Settings > Dictation** sets the language (Aqua's codes: Auto-Detect, `en`, `cmn`, `ja`, `ko`, `de`, `fr`, `es`,
`ru`) and the model (`avalon-v1.1`, Aqua's default and fastest; `avalon-v1.5`, slower and better with Chinese;
`whisper`), kept on the phone; until changed, they are what the Mac's Aqua app was set to when the app was built. The
screen also shows until when the build's sign-in is valid. The token is not in the source and cannot be set in the
app: it comes with the build.

The sign-in is the user's own Aqua app's: `ios/scripts/aqua_secrets.py`, which `build.sh` runs, reads the JWT from its
LevelDB local storage (`~/Library/Application Support/Aqua Voice/Local Storage/leveldb`, valid about 1000 days) and the
model, language and dictionary from its `settings.json`, into `ios/Tau/Secrets/Aqua.plist` (gitignored), which the app
bundles. Without it, dictation says so.

## Testing

`-mockDictation YES` (and the mock store, unless `-mockDictation NO`) uses the stand-in engine, which "hears" a sentence
a word at a time. `-dictationFile <16 kHz mono WAV>` sends a file to Aqua instead of the microphone, at the pace of
speech, for trying the connection on the simulator (`say -o f.wav --data-format=LEI16@16000 "…"`). UI test:
`testDictation`.
