// Where the message list's live tail starts (docs/web.md "Reading position"): as ChatGPT does and Web A does for a bot's
// streamed answer, the message the user sends goes to the top of the view and the answer grows below it. Web A starts
// its tail at an incoming typing draft, which in tau comes late or not at all (a call runs first, the τ waits for the
// server); tau starts it at the user's message itself, sent here or on another device while the chat is on screen,
// whatever the run does next, and keeps it until Web A releases it (the answer outgrew the screen) or a newer message
// is sent. The web differs from iOS here, which stays at the bottom and follows: the user's choice.
import type { ApiMessage } from '../api/types';

import { getMessageOriginalId } from '../global/helpers';

/** What the list knew when it opened: messages sent before then start no tail */
export type TailBaseline = { newest?: number };

export function tauLiveTailStart(
  messageIds: number[] | undefined,
  messagesById: Record<number, ApiMessage> | undefined,
  activeStart: number | undefined,
  baseline: TailBaseline,
) {
  if (!messageIds || !messagesById) return undefined;
  let newest: number | undefined;
  for (let i = messageIds.length - 1; i >= 0; i--) {
    const message = messagesById[messageIds[i]];
    if (message?.isOutgoing) {
      newest = getMessageOriginalId(message);
      break;
    }
  }
  if (baseline.newest === undefined) {
    baseline.newest = newest ?? 0;
    return undefined;
  }
  if (newest === undefined) return undefined;
  if (activeStart !== undefined && newest >= activeStart) return newest;
  if (newest <= baseline.newest) return undefined;
  baseline.newest = newest;
  return newest;
}
