// An error the run ended on (iOS's ChatMessageItem `.failed`): where the answer would be, a card with what went wrong
// and Retry, which sends the message before it again (the server's own retries are over, and the model never read
// the failed answer); when the provider refused the account, Accounts beside it, to Settings > Accounts.
import { memo } from '../../lib/teact/teact';
import { getActions } from '../../global';

import type { ApiMessage } from '../../api/types';
import { LeftColumnContent, SettingsScreens } from '../../types';

import { isAccountError } from '../api/modelErrors';
import { retryAfterError } from '../api/session';
import { STRINGS } from '../strings';

import styles from './TauMessage.module.scss';

const ErrorCard = ({ text, message }: { text: string; message: ApiMessage }) => {
  return (
    <div className={styles.errorCard} data-tau-part="error">
      <div className={styles.errorTitle}>{STRINGS.ModelFailed}</div>
      <div className={styles.errorText}>{text}</div>
      <div className={styles.errorButtons}>
        {isAccountError(text) && (
          <button type="button" className={styles.errorRetry} onClick={openAccounts}>{STRINGS.Accounts}</button>
        )}
        <button type="button" className={styles.errorRetry} onClick={() => retryAfterError(message.chatId, message.id)}>
          {STRINGS.Retry}
        </button>
      </div>
    </div>
  );
};

function openAccounts() {
  const { openLeftColumnContent, openSettingsScreen } = getActions();
  openLeftColumnContent({ contentKey: LeftColumnContent.Settings });
  openSettingsScreen({ screen: SettingsScreens.ActiveSessions });
}

export default memo(ErrorCard);
