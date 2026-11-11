// What the agent does and for how long, in the chat's title as iOS's (ChatController's title status): "working for
// 12s", ticking each second; the words alone before the first second.
import { memo } from '../../lib/teact/teact';

import { STRINGS } from '../strings';
import { formatElapsed } from './format';

import useIntervalForceUpdate from '../../hooks/schedulers/useIntervalForceUpdate';

const TICK_MS = 1000;

const Elapsed = ({ text, since }: { text: string; since: number }) => {
  useIntervalForceUpdate(TICK_MS);
  const elapsed = Date.now() - since;
  return elapsed >= 1000 ? `${text} ${STRINGS.ElapsedFor} ${formatElapsed(elapsed)}` : text;
};

export default memo(Elapsed);
