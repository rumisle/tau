// What the transcript shows where the answer will be, while the agent works and has written nothing yet (iOS's
// ChatWaitingNode): a τ that a pen keeps tracing over its faint outline, from the bar to the end of the stem, then
// lifting off the same way, in the accent color. Beside it while the server asks the model again after an error:
// "retrying in 5s (attempt 3): overloaded", ticking.
import { memo } from '../../lib/teact/teact';

import type { ApiTauPart } from '../api/types';

import { STRINGS } from '../strings';
import { formatElapsed } from './format';

import useIntervalForceUpdate from '../../hooks/schedulers/useIntervalForceUpdate';

import styles from './TauMessage.module.scss';

// A lowercase tau in 24 px: the bar with its left end hooked down, and the stem curling to the right at its foot
const BAR = 'M3.2 10Q3.9 6.7 7 6.6L20.6 6.6';
const STEM = 'M12.6 6.6L11.9 15.2Q11.5 19.7 16.6 19.4';
const TICK_MS = 1000;

type Retry = NonNullable<Extract<ApiTauPart, { type: 'waiting' }>['retry']>;

/** As iOS says it, lowercase as the chat's other statuses */
function retryText({ attempt, at, reason }: Retry) {
  const left = at !== undefined ? at - Date.now() : 0;
  let text = left > 500 ? `${STRINGS.RetryingIn} ${formatElapsed(Math.ceil(left / 1000) * 1000)}` : STRINGS.Retrying;
  if (attempt > 2) text += ` (${STRINGS.Attempt} ${attempt})`;
  return `${text}: ${reason}`;
}

const WaitingTau = ({ retry }: { retry?: Retry }) => {
  useIntervalForceUpdate(retry?.at !== undefined ? TICK_MS : undefined);
  return (
    <div className={styles.waitingRow}>
      <div className={styles.waiting} data-tau-part="waiting" role="img" aria-label="Working">
        <svg
          width="24"
          height="24"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2.2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path className={styles.waitingTrack} d={BAR} />
          <path className={styles.waitingTrack} d={STEM} />
          <path className={styles.waitingBar} d={BAR} pathLength={1} />
          <path className={styles.waitingStem} d={STEM} pathLength={1} />
        </svg>
      </div>
      {retry && <span className={styles.retry} data-tau-part="retry">{retryText(retry)}</span>}
    </div>
  );
};

export default memo(WaitingTau);
