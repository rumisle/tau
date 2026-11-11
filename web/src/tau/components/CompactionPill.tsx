// A compaction at work (iOS's ChatMessageItem `.compacting`): Telegram's service pill with the τ tracing in it and the
// time it has taken so far, over the end of the chat, above the field; the chat goes on meanwhile. Its summary then
// arrives as a card in the transcript (components/CompactionCard.tsx).
import { memo, useEffect, useState } from '../../lib/teact/teact';

import { compactionSince, onConversationChange } from '../api/session';
import { STRINGS } from '../strings';
import { formatElapsed } from './format';

import useIntervalForceUpdate from '../../hooks/schedulers/useIntervalForceUpdate';

import WaitingTau from './WaitingTau';

const TICK_MS = 1000;

const CompactionPill = ({ chatId }: { chatId: string }) => {
  const [since, setSince] = useState(() => compactionSince(chatId));
  useEffect(() => {
    setSince(compactionSince(chatId));
    return onConversationChange((id) => {
      if (String(id) === chatId) setSince(compactionSince(chatId));
    });
  }, [chatId]);
  useIntervalForceUpdate(since !== undefined ? TICK_MS : undefined);
  if (since === undefined) return undefined;
  const elapsed = Date.now() - since;
  return (
    <div className="tau-compaction-pill" data-tau-part="compacting">
      <WaitingTau />
      <span>{STRINGS.CompactingContext}</span>
      {elapsed >= 1000 && <span className="tau-compaction-time">{formatElapsed(elapsed)}</span>}
    </div>
  );
};

export default memo(CompactionPill);
