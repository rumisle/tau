// tau's state as Web A's UI reads it, beside Web A's selectors.
import type { GlobalState } from '../global/types';
import type { ThreadId } from '../types';

import { IS_TAU } from './config';
import { selectThreadLocalStateParam } from '../global/selectors/threads';

/** The composer's Stop while the chat's own run works: the "draft" Web A stops is the run (src/tau/api/session.ts) */
export const TAU_RUN_DRAFT_ID = 'tau-run';

export function selectTauStoppableRun<T extends GlobalState>(global: T, chatId: string, threadId: ThreadId) {
  if (!IS_TAU) return undefined;
  const status = selectThreadLocalStateParam(global, chatId, threadId, 'typingStatusByPeerId')?.[chatId];
  return (status as { tauRun?: boolean } | undefined)?.tauRun ? TAU_RUN_DRAFT_ID : undefined;
}
