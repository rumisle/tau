// A compaction's summary in the chat (iOS's ChatMessageItem `.compacted`): a card on the service fill, as Telegram's
// service messages with content: "Context compacted", when and why, then the summary the model now reads, folded to
// its first lines with a fade until clicked. Its right-click menu has Restore Full Context (components/MessageMenu.tsx).
import { memo, useLayoutEffect, useRef, useState } from '../../lib/teact/teact';

import type { ApiMessage } from '../../api/types';
import type { ThemeKey } from '../../types';
import type { ApiTauPart } from '../api/types';

import buildClassName from '../../util/buildClassName';
import { formatDateTime, secondsToDate } from '../../util/localization/dateFormat';
import { STRINGS } from '../strings';

import useLang from '../../hooks/useLang';

import RichContent from '../../components/iv/RichContent';

import styles from './TauMessage.module.scss';

// Folded: the first lines, as iOS's 96 pt
const FOLDED_PX = 96;
// How far the mouse may move between press and release for a click
const DRAG_PX = 4;
const SUMMARY_FONT_ADJUST = 14 / 18;

type OwnProps = {
  part: Extract<ApiTauPart, { type: 'compaction' }>;
  message: ApiMessage;
  theme: ThemeKey;
};

const CompactionCard = ({ part, message, theme }: OwnProps) => {
  const lang = useLang();
  const [isExpanded, setIsExpanded] = useState(false);
  const [isFoldable, setIsFoldable] = useState(false);
  const summaryRef = useRef<HTMLDivElement>();
  const downAtRef = useRef<{ x: number; y: number }>();

  useLayoutEffect(() => {
    // Only where there is something to fold, as iOS: more than a few lines past the fold
    setIsFoldable((summaryRef.current?.scrollHeight ?? 0) > FOLDED_PX + 16);
  }, [part.summary]);

  const time = formatDateTime(lang, secondsToDate(message.date), { time: 'short' });
  const when = part.reason === 'threshold' ? `${STRINGS.CompactedAutomatically} ${time}`
    : part.reason === 'overflow' ? `${STRINGS.CompactedAfterOverflow} ${time}` : `${STRINGS.CompactedAt} ${time}`;
  const isFolded = isFoldable && !isExpanded;

  return (
    <div
      className={buildClassName(styles.compaction, isFoldable && styles.clickable)}
      data-tau-part="compaction"
      data-tau-expanded={isExpanded || undefined}
      onMouseDown={(e) => {
        downAtRef.current = { x: e.clientX, y: e.clientY };
      }}
      onClick={(e) => {
        const from = downAtRef.current;
        const isDrag = from && Math.hypot(e.clientX - from.x, e.clientY - from.y) > DRAG_PX;
        if (isFoldable && !isDrag) setIsExpanded(!isExpanded);
      }}
    >
      <div className={styles.compactionTitle}>{STRINGS.ContextCompacted}</div>
      <div className={styles.compactionWhen}>{when}</div>
      <div
        ref={summaryRef}
        className={buildClassName(styles.compactionSummary, isFolded && styles.folded)}
        style={isFolded ? `max-height: ${FOLDED_PX}px` : undefined}
      >
        <RichContent
          blocks={part.summary}
          theme={theme}
          fontSizeAdjust={SUMMARY_FONT_ADJUST}
          chatId={message.chatId}
          messageId={message.id}
        />
      </div>
      {isFoldable && (
        <i className={buildClassName('icon', isExpanded ? 'icon-up' : 'icon-down', styles.compactionArrow)} />
      )}
    </div>
  );
};

export default memo(CompactionCard);
