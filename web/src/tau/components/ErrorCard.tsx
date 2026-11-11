// An error the run ended on (iOS's ChatMessageItem `.failed`): where the answer would be, a card with what went wrong
// and Retry, which sends the message before it again (the server's own retries are over, and the model never read
// the failed answer).
import { memo } from '../../lib/teact/teact';

import type { ApiMessage } from '../../api/types';

import { retryAfterError } from '../api/session';
import { STRINGS } from '../strings';

import styles from './TauMessage.module.scss';

const ErrorCard = ({ text, message }: { text: string; message: ApiMessage }) => {
  return (
    <div className={styles.errorCard} data-tau-part="error">
      <div className={styles.errorTitle}>{STRINGS.ModelFailed}</div>
      <div className={styles.errorText}>{text}</div>
      <button type="button" className={styles.errorRetry} onClick={() => retryAfterError(message.chatId, message.id)}>
        {STRINGS.Retry}
      </button>
    </div>
  );
};

export default memo(ErrorCard);
