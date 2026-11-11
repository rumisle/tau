// A subagent's card, as the iOS app draws it: the quote (its name, working or how it ended, its task), and its answer
// when it reported one
import { memo } from '../../lib/teact/teact';

import type { ApiMessage } from '../../api/types';
import type { ThemeKey } from '../../types';
import type { ApiTauPart } from '../api/types';

import buildClassName from '../../util/buildClassName';

import RichContent from '../../components/iv/RichContent';
import Spinner from '../../components/ui/Spinner';

import styles from './TauMessage.module.scss';

const ANSWER_FONT_ADJUST = 15 / 18;

type OwnProps = {
  part: Extract<ApiTauPart, { type: 'subagent' }>;
  theme: ThemeKey;
  message: ApiMessage;
};

const SubagentCard = ({ part, theme, message }: OwnProps) => {
  return (
    <div className={buildClassName(styles.card, styles.subagent)} data-tau-part="subagent">
      <div className={styles.quote}>
        <div className={styles.quoteHeader}>
          <span className={styles.subagentName}>{part.name}</span>
          {part.state && (
            <span className={buildClassName(styles.subagentState, part.isFailed && styles.failed)}>{part.state}</span>
          )}
          {part.isWorking && <Spinner className={styles.spinner} color="blue" />}
        </div>
        <div className={styles.task}>{part.task}</div>
      </div>
      {part.answer && (
        <div className={styles.answer}>
          <RichContent
            blocks={part.answer}
            theme={theme}
            fontSizeAdjust={ANSWER_FONT_ADJUST}
            chatId={message.chatId}
            messageId={message.id}
          />
        </div>
      )}
    </div>
  );
};

export default memo(SubagentCard);
