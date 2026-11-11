// The messages waiting for the agent, above the field (docs/sending.md "What the user sees"; iOS's
// InputAccessoryPanelView after Telegram's ChatInputMessageAccessoryPanel), in Web A's embedded-message bar, where a
// reply or an edit shows: "Steer" or "Follow-up", the first one's text, the clock while it goes and a check once the
// server holds it; several split the line into segments, as the pinned messages bar does. × withdraws it. A click or a
// right-click opens what can be done with it before the model has it: Edit, Send as Follow-up or as Steer, Send Now,
// Delete; with several, each is a submenu.
import { memo, useEffect, useRef, useState } from '../../lib/teact/teact';
import { getActions } from '../../global';

import type { QueuedMessage } from '../api/queue';

import buildClassName from '../../util/buildClassName';
import { queuedPreview } from '../api/queue';
import {
  moveQueued, onConversationChange, queueOf, sendQueuedNow, withdrawQueued,
} from '../api/session';
import { STRINGS } from '../strings';

import useContextMenuHandlers from '../../hooks/useContextMenuHandlers';
import useLastCallback from '../../hooks/useLastCallback';

import Icon from '../../components/common/icons/Icon';
import PinnedMessageNavigation from '../../components/middle/PinnedMessageNavigation';
import Button from '../../components/ui/Button';
import Menu from '../../components/ui/Menu';
import MenuItem, { MenuItemSubtitle, MenuItemTitle } from '../../components/ui/MenuItem';
import MenuSeparator from '../../components/ui/MenuSeparator';
import NestedMenuItem from '../../components/ui/NestedMenuItem';
import CompactionPill from './CompactionPill';

type OwnProps = {
  chatId: string;
};

const titleOf = (queued: QueuedMessage) => (queued.mode === 'followUp' ? STRINGS.QueueFollowUp : STRINGS.QueueSteer);

/** Above the field: the compaction running, as a pill, and the queue */
const QueuePanel = ({ chatId }: OwnProps) => {
  return (
    <>
      <CompactionPill chatId={chatId} />
      <QueueBar chatId={chatId} />
    </>
  );
};

const QueueBar = ({ chatId }: OwnProps) => {
  const conversationId = Number(chatId);
  const [queue, setQueue] = useState<QueuedMessage[]>(() => queueOf(conversationId));
  const ref = useRef<HTMLDivElement>();

  useEffect(() => {
    setQueue(queueOf(conversationId));
    return onConversationChange((id) => {
      if (id === conversationId) setQueue(queueOf(conversationId));
    });
  }, [conversationId]);

  const {
    isContextMenuOpen, contextMenuAnchor, handleContextMenu, handleContextMenuClose, handleContextMenuHide,
  } = useContextMenuHandlers(ref);

  const getTriggerElement = useLastCallback(() => ref.current);
  const getRootElement = useLastCallback(() => ref.current!);
  const getMenuElement = useLastCallback(() => ref.current?.querySelector('.tau-queue-menu .bubble'));

  const withdraw = (queued: QueuedMessage, restore: boolean) => {
    if (!withdrawQueued(conversationId, queued, restore)) {
      getActions().showNotification({ message: STRINGS.QueueAlreadyDelivered });
      return;
    }
    if (restore) document.querySelector<HTMLElement>('#editable-message-text')?.focus();
  };

  // Emptied with its menu closing (Edit, Delete of the last one): the menu's end never comes, and would block the next
  useEffect(() => {
    if (!queue.length) handleContextMenuHide();
  }, [queue.length, handleContextMenuHide]);

  const first = queue[0];
  if (!first) return undefined;

  const run = (action: () => void) => () => {
    handleContextMenuClose();
    action();
  };

  const renderActions = (queued: QueuedMessage) => {
    const other = queued.mode === 'steer' ? 'followUp' : 'steer';
    return (
      <>
        <MenuItem icon="edit" onClick={run(() => withdraw(queued, true))}>{STRINGS.QueueEdit}</MenuItem>
        <MenuItem
          icon={other === 'followUp' ? 'schedule' : 'forward'}
          onClick={run(() => moveQueued(conversationId, queued, other))}
        >
          {other === 'followUp' ? STRINGS.QueueAsFollowUp : STRINGS.QueueAsSteer}
        </MenuItem>
        <MenuItem icon="send" onClick={run(() => sendQueuedNow(conversationId, queued))}>
          <MenuItemTitle>{STRINGS.QueueSendNow}</MenuItemTitle>
          <MenuItemSubtitle>{STRINGS.QueueSendNowNote}</MenuItemSubtitle>
        </MenuItem>
        <MenuSeparator />
        <MenuItem icon="delete" destructive onClick={run(() => withdraw(queued, false))}>
          {STRINGS.QueueDelete}
        </MenuItem>
      </>
    );
  };

  return (
    <div
      ref={ref}
      className={buildClassName('ComposerEmbeddedMessage', 'open', 'tau-queue-panel', queue.length > 1 && 'several')}
      onContextMenu={handleContextMenu}
    >
      <div className="ComposerEmbeddedMessage_inner">
        <div className="embedded-left-icon" aria-hidden>
          <Icon name={first.mode === 'followUp' ? 'schedule' : 'forward'} />
        </div>
        <div
          className="EmbeddedMessage inside-input no-selection"
          role="button"
          tabIndex={0}
          title={STRINGS.QueueHint}
          onClick={handleContextMenu}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              handleContextMenu(e as unknown as React.MouseEvent);
            }
          }}
        >
          <div className="hover-effect" />
          {/* Its index counts from the bottom: the first queued is the top segment */}
          {queue.length > 1 && <PinnedMessageNavigation count={queue.length} index={queue.length - 1} />}
          <div className="message-text">
            <p className="embedded-text-wrapper">{queuedPreview(first)}</p>
            <div className="message-title">
              {titleOf(first)}
              <Icon
                name={first.isSending ? 'message-pending' : 'check'}
                className="tau-queue-status"
              />
            </div>
          </div>
        </div>
        <Button
          className="embedded-cancel"
          round
          faded
          color="translucent"
          ariaLabel={STRINGS.QueueDelete}
          onClick={() => withdraw(first, false)}
          iconName="close"
        />
      </div>
      <Menu
        isOpen={isContextMenuOpen}
        anchor={contextMenuAnchor}
        getTriggerElement={getTriggerElement}
        getRootElement={getRootElement}
        getMenuElement={getMenuElement}
        className="tau-queue-menu"
        autoClose
        onClose={handleContextMenuClose}
        onCloseAnimationEnd={handleContextMenuHide}
      >
        {queue.length === 1 ? renderActions(first) : queue.map((queued) => (
          <NestedMenuItem key={queued.id} submenu={renderActions(queued)}>
            <MenuItemTitle>{queuedPreview(queued)}</MenuItemTitle>
            <MenuItemSubtitle>{titleOf(queued)}</MenuItemSubtitle>
          </NestedMenuItem>
        ))}
      </Menu>
    </div>
  );
};

export default memo(QueuePanel);
