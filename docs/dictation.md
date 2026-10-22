# Dictation

Speech to text in the composer (`ios/Tau/Chat/ChatInputPanelNode.swift`), through Aqua Voice
(`ios/Tau/Chat/AquaDictation.swift`).

## The composer

Laid out as Telegram's iOS 26 ChatTextInputPanelNode, with the text in it: the attachment button, then the field to
the screen's edge. At the field's end:

- **The microphone**, where Telegram keeps the sticker button, always there: tapped, it listens until tapped again;
  held, while the finger is down (Telegram's hold-to-record).
- **The action button** after it, Telegram's `sendActionButtons`: a 34 pt disc in the accent color. **Send** once
  there is text (long-pressed, the send menu), **Stop** while the agent works on an empty field, and while dictating,
  the **listening** button, which stops it. With none, there is no button.

The button comes in with Telegram's `updateActionButtons`: scaled up from 0.001 at the field's edge, faded in over
0.2 s and unblurred from 4 pt over 0.18 s, the send arrow coming from 22 pt left and 18 pt below. It leaves the same
way back, showing what it was. Between kinds the icons trade places with a scale, as Telegram's stop and microphone
icons do. The microphone moves aside for the button as Telegram's accessory buttons move for Send, and the text keeps
clear of both.

While listening, Telegram's recording blob (AudioBlob's VoiceBlobView, set up as ChatTextInputMediaRecordingButton
sets it up) moves around the disc with the microphone's level; it is over the field, not in its glass, so it is not
clipped. The words go in at the cursor, or at the end when the field is not being edited, a space apart from what is
before them, and replace themselves as they change. Tapping the listening button turns the microphone off at once;
the last words come within a second or two, and the button turns into Send. Send while listening sends what has been
heard. Dictation that cannot listen says why in a toast (no microphone access, no sign-in in the build, a connection
that failed with nothing heard).

There is no timer: the blob says it is listening, and the field stays as wide as it was.

## Aqua Voice

Aqua's realtime API. Unofficial: it can
change without notice.

- `wss://realtime.aquavoice.com?token=<JWT>`, then a `start` message as Aqua's macOS client builds it (16 kHz,
  `pcm_s16le`, streaming, the model, language, dictionary and replacements), then `ready`.
- Audio as binary frames of 100 ms (3200 bytes of 16 kHz mono 16-bit PCM), each behind an 8-byte header: type 1,
  0, the frame number and 0 as big-endian 16-bit, and the size in KB.
- `document_update` carries the whole text so far (`wet_text`, else `dry_text`, else `raw_text`); the one marked
  `final` after `stop_request { total_audio_chunks }` ends it.
- The microphone (AVAudioEngine, converted to 16 kHz) is captured from the tap on: what comes before `ready` is kept
  and sent then. Stopping sends a second of silence at the pace of speech, as Aqua's SDK does, then `stop_request`,
  and waits 8 s for the final text, keeping the last one heard otherwise. Audio must go at the pace of speech: the
  server, sent a recording at once, gives nothing.
- Aqua writes Chinese with a space between words; the spaces between two Chinese characters are taken out.

The sign-in is the user's own Aqua app's: `ios/scripts/aqua_secrets.py`, which `build.sh` runs, reads the JWT from its
LevelDB local storage (`~/Library/Application Support/Aqua Voice/Local Storage/leveldb`, valid about 1000 days) and the
model, language and dictionary from its `settings.json`, into `ios/Tau/Secrets/Aqua.plist` (gitignored), which the app
bundles. Without it, dictation says so.

## Testing

`-mockDictation YES` (and the mock store, unless `-mockDictation NO`) uses the stand-in engine, which "hears" a sentence
a word at a time. `-dictationFile <16 kHz mono WAV>` sends a file to Aqua instead of the microphone, at the pace of
speech, for trying the connection on the simulator (`say -o f.wav --data-format=LEI16@16000 "…"`). UI test:
`testDictation`.
