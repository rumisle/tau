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

Aqua's realtime API. Unofficial: it can change without notice.

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

## Settings > Dictation

Dictation is off until a provider is chosen, and off, the composer has no microphone. Providers are
`DictationProvider` cases, each with its engine (`ios/Tau/Chat/Dictation.swift`); there is one, Aqua Voice.

For Aqua Voice:

- **Session Key.** Aqua has no API keys; tau listens with the session of the user's own account: the JWT Aqua's app
  signs in with (its localStorage `token`, valid about a thousand days). The user pastes it in an alert, which keeps
  it only if it is a JWT with a `user_id` and not expired, in this iPhone's keychain (`AfterFirstUnlockThisDeviceOnly`).
  The row shows until when it is valid, Not Set or Expired; without a valid key the microphone says where to add one.
- **Copy Command for Mac** copies a command that, run in Terminal on a Mac where Aqua Voice is signed in, finds the key
  in the app's LevelDB local storage and copies it (Universal Clipboard brings it to the iPhone):

  ```sh
  k=$(grep -rahoE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' ~/Library/Application\ Support/Aqua\ Voice/Local\ Storage/leveldb 2>/dev/null | tail -n 1); [ -n "$k" ] && printf %s "$k" | pbcopy && echo 'Aqua session key copied' || echo 'No Aqua Voice sign-in on this Mac'
  ```
- **Language** (Aqua's codes: Auto-Detect, `en`, `cmn`, `yue`, `ja`, `ko`, `de`, `fr`, `es`, `ru`) and **Model**
  (`avalon-v1.1`, Aqua's default and fastest; `avalon-v1.5`, slower and better with Chinese; `whisper`), on the phone;
  Auto-Detect and Avalon 1.1 until changed.

Nothing of the user's is in the build or the repository.

## Testing

`-mockDictation YES` (and the mock store, unless `-mockDictation NO`) uses the stand-in engine, with the microphone shown whatever the setting, which "hears" a sentence
a word at a time. `-dictationFile <16 kHz mono WAV>` sends a file to Aqua instead of the microphone, at the pace of
speech, for trying the connection on the simulator (`say -o f.wav --data-format=LEI16@16000 "…"`). UI test:
`testDictation`.
