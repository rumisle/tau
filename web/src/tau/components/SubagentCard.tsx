// A subagent's card, as the iOS app draws it: the quote (its name, working or how it ended, its task), and its answer
// when it reported one
import { memo, useRef } from '../../lib/teact/teact';

import type { ApiMessage } from '../../api/types';
import type { ThemeKey } from '../../types';
import type { ApiTauPart } from '../api/types';

import buildClassName from '../../util/buildClassName';
import { openConversation } from '../api/session';

import RichContent from '../../components/iv/RichContent';
import Spinner from '../../components/ui/Spinner';

import styles from './TauMessage.module.scss';

const ANSWER_FONT_ADJUST = 15 / 18;

type OwnProps = {
  part: Extract<ApiTauPart, { type: 'subagent' }>;
  theme: ThemeKey;
  message: ApiMessage;
};

// How far the mouse may move between press and release for a click
const DRAG_PX = 4;

const SubagentCard = ({ part, theme, message }: OwnProps) => {
  const downAtRef = useRef<{ x: number; y: number }>();
  const { conversationId } = part;
  return (
    <div
      className={buildClassName(styles.card, styles.subagent, conversationId !== undefined && styles.clickable)}
      data-tau-part="subagent"
      // A click opens its conversation (iOS: a tap); a drag that selects its text does not
      onMouseDown={(e) => {
        downAtRef.current = { x: e.clientX, y: e.clientY };
      }}
      onClick={(e) => {
        const from = downAtRef.current;
        const isDrag = from && Math.hypot(e.clientX - from.x, e.clientY - from.y) > DRAG_PX;
        if (conversationId !== undefined && !isDrag) openConversation(conversationId);
      }}
    >
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
      {part.meta && !part.answer && <div className={styles.subagentMeta}>{part.meta}</div>}
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
