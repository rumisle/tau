// A tau answer as the iOS app draws it (ios/Tau/Chat/ChatMessageItem.swift): no bubble, the answer's Markdown at
// full width, thinking dimmer and smaller, tool calls and subagents as cards, and the run's footer at its end. It
// keeps the message list's contract (`.message-list-item`, the bottom marker, the appearance transition) and nothing of
// Web A's bubble.
import {
  memo, useRef, useUnmountCleanup,
} from '../../lib/teact/teact';

import type { ApiMessage } from '../../api/types';
import type { ObserveFn } from '../../hooks/useIntersectionObserver';
import type { ApiTauPart } from '../api/types';

import { getMessageHtmlId } from '../../global/helpers';
import { selectTheme } from '../../global/selectors';
import buildClassName from '../../util/buildClassName';
import { formatDateTime, secondsToDate } from '../../util/localization/dateFormat';
import { selectTauSearchHighlight } from '../selectors';
import { STRINGS } from '../strings';
import { formatDuration } from './format';
import { useSearchHighlight } from './searchHighlight';

import useSelector from '../../hooks/data/useSelector';
import useContextMenuHandlers from '../../hooks/useContextMenuHandlers';
import { useOnIntersect } from '../../hooks/useIntersectionObserver';
import useLang from '../../hooks/useLang';
import useShowTransition from '../../hooks/useShowTransition';

import RichContent from '../../components/iv/RichContent';
import CompactionCard from './CompactionCard';
import ErrorCard from './ErrorCard';
import MessageMenu from './MessageMenu';
import SubagentCard from './SubagentCard';
import ToolCard from './ToolCard';
import WaitingTau from './WaitingTau';

import styles from './TauMessage.module.scss';

type OwnProps = {
  message: ApiMessage;
  isLastInList?: boolean;
  isJustAdded?: boolean;
  observeIntersectionForBottom?: ObserveFn;
  observeIntersectionForLoading?: ObserveFn;
  onMessageUnmount?: (messageId: number) => void;
};

const ANSWER_FONT_ADJUST = 17 / 18;

const TauMessage = ({
  message,
  isLastInList,
  isJustAdded,
  observeIntersectionForBottom,
  observeIntersectionForLoading,
  onMessageUnmount,
}: OwnProps) => {
  const lang = useLang();
  const theme = useSelector(selectTheme);
  const searchHighlight = useSelector(selectTauSearchHighlight);
  const ref = useRef<HTMLDivElement>();
  const bottomMarkerRef = useRef<HTMLDivElement>();
  const tau = message.tau!;

  useSearchHighlight(ref, searchHighlight, message.tau);
  useOnIntersect(bottomMarkerRef, message.isTypingDraft ? undefined : observeIntersectionForBottom);
  useShowTransition({
    ref,
    isOpen: true,
    noMountTransition: !isJustAdded,
    className: false,
  });
  useUnmountCleanup(() => {
    onMessageUnmount?.(message.id);
  });
  const {
    isContextMenuOpen, contextMenuAnchor, handleBeforeContextMenu, handleContextMenu, handleContextMenuClose,
    handleContextMenuHide,
  } = useContextMenuHandlers(ref, Boolean(message.isTypingDraft), true);

  function renderPart(part: ApiTauPart, index: number) {
    switch (part.type) {
      case 'thinking':
        return <div key={index} className={styles.thinking} data-tau-part="thinking" dir="auto">{part.text}</div>;
      case 'text':
        return (
          <div key={index} className={styles.text} data-tau-part="text">
            <RichContent
              blocks={part.blocks}
              theme={theme}
              fontSizeAdjust={ANSWER_FONT_ADJUST}
              chatId={message.chatId}
              messageId={message.id}
              observeIntersectionForLoading={observeIntersectionForLoading}
            />
          </div>
        );
      case 'tool':
        return <ToolCard key={part.id} part={part} />;
      case 'subagent':
        return <SubagentCard key={index} part={part} theme={theme} message={message} />;
      case 'waiting':
        return <WaitingTau key="waiting" retry={part.retry} />;
      case 'error':
        return <ErrorCard key="error" text={part.text} message={message} />;
      case 'compaction':
        return <CompactionCard key="compaction" part={part} message={message} theme={theme} />;
    }
  }

  const { runEnd } = tau;
  // How long the run took, and the model errors the server asked past, as iOS's footer
  const workedFor = [
    runEnd?.workedForMs !== undefined && runEnd.workedForMs >= 1000
      ? `worked for ${formatDuration(runEnd.workedForMs)}` : undefined,
    runEnd?.retries ? (runEnd.retries === 1 ? STRINGS.RetriedOnce
      : STRINGS.RetriedTimes.replace('{n}', String(runEnd.retries))) : undefined,
  ].filter(Boolean).join(', ') || undefined;

  return (
    <div
      ref={ref}
      id={getMessageHtmlId(message.id)}
      className={buildClassName(
        'message-list-item',
        styles.root,
        isLastInList && 'last-in-list',
      )}
      data-message-id={message.id}
      data-tau-row={tau.role}
      data-tau-draft={message.isTypingDraft || undefined}
      onMouseDown={handleBeforeContextMenu}
      onContextMenu={handleContextMenu}
    >
      <div ref={bottomMarkerRef} className="bottom-marker" data-message-id={message.id} />
      {tau.parts.map(renderPart)}
      {runEnd && !message.isTypingDraft && (
        <div className={styles.footer} data-tau-part="footer">
          <span>{workedFor}</span>
          <span>{formatDateTime(lang, secondsToDate(message.date), { time: 'short' })}</span>
        </div>
      )}
      {contextMenuAnchor && (
        <MessageMenu
          message={message}
          isOpen={isContextMenuOpen}
          anchor={contextMenuAnchor}
          onClose={handleContextMenuClose}
          onCloseAnimationEnd={handleContextMenuHide}
        />
      )}
    </div>
  );
};

export default memo(TauMessage);
