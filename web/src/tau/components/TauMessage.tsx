// A tau answer as the iOS app draws it (ios/Tau/Chat/ChatMessageItem.swift): no bubble, the answer's Markdown at
// full width, thinking dimmer and smaller, tool calls and subagents as cards, and the run's footer at its end. It
// keeps the message list's contract (`.message-list-item`, the bottom marker, the appearance transition) and nothing of
// Web A's bubble.
import {
  memo, useRef, useUnmountCleanup,
} from '../../lib/teact/teact';
import { getActions } from '../../global';

import type { ApiMessage } from '../../api/types';
import type { ObserveFn } from '../../hooks/useIntersectionObserver';
import type { ApiTauPart } from '../api/types';

import { getMessageHtmlId } from '../../global/helpers';
import { selectTheme } from '../../global/selectors';
import buildClassName from '../../util/buildClassName';
import { copyTextToClipboard } from '../../util/clipboard';
import { formatDateTime, secondsToDate } from '../../util/localization/dateFormat';
import { formatDuration } from './format';

import useSelector from '../../hooks/data/useSelector';
import { useOnIntersect } from '../../hooks/useIntersectionObserver';
import useLang from '../../hooks/useLang';
import useShowTransition from '../../hooks/useShowTransition';

import RichContent from '../../components/iv/RichContent';
import SubagentCard from './SubagentCard';
import ToolCard from './ToolCard';

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

/** A click on code, inline or a block, copies it, as Telegram's does (not a click that ends a selection) */
function handleCodeClick(e: React.MouseEvent<HTMLElement>) {
  const target = e.target as HTMLElement;
  if (target.closest('button') || !window.getSelection()?.isCollapsed) return;
  // Inline code is Web A's `code`, a block its CodeBlock's `pre`
  const code = target.closest<HTMLElement>('code, pre');
  if (!code) return;
  copyTextToClipboard(code.innerText.replace(/\n$/, ''));
  getActions().showNotification({ message: { key: 'TextCopied' } });
}

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
  const ref = useRef<HTMLDivElement>();
  const bottomMarkerRef = useRef<HTMLDivElement>();
  const tau = message.tau!;

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

  function renderPart(part: ApiTauPart, index: number) {
    switch (part.type) {
      case 'thinking':
        return <div key={index} className={styles.thinking} data-tau-part="thinking" dir="auto">{part.text}</div>;
      case 'text':
        return (
          <div key={index} className={styles.text} data-tau-part="text" onClick={handleCodeClick}>
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
    }
  }

  const { runEnd } = tau;
  const workedFor = runEnd?.workedForMs !== undefined && runEnd.workedForMs >= 1000
    ? `worked for ${formatDuration(runEnd.workedForMs)}` : undefined;

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
    >
      <div ref={bottomMarkerRef} className="bottom-marker" data-message-id={message.id} />
      {tau.parts.map(renderPart)}
      {runEnd && !message.isTypingDraft && (
        <div className={styles.footer} data-tau-part="footer">
          <span>{workedFor}</span>
          <span>{formatDateTime(lang, secondsToDate(message.date), { time: 'short' })}</span>
        </div>
      )}
    </div>
  );
};

export default memo(TauMessage);
