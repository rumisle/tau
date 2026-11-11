// What the transcript shows where the answer will be, while the agent works and has written nothing yet (iOS's
// ChatWaitingNode): a τ that a pen keeps tracing over its faint outline, from the bar to the end of the stem, then
// lifting off the same way, in the accent color.
import { memo } from '../../lib/teact/teact';

import styles from './TauMessage.module.scss';

// A lowercase tau in 24 px: the bar with its left end hooked down, and the stem curling to the right at its foot
const BAR = 'M3.2 10Q3.9 6.7 7 6.6L20.6 6.6';
const STEM = 'M12.6 6.6L11.9 15.2Q11.5 19.7 16.6 19.4';

const WaitingTau = () => {
  return (
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
  );
};

export default memo(WaitingTau);
