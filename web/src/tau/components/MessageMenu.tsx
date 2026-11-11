// A message's context menu, tau's in place of Web A's (ios/Tau/Chat/ChatController.swift, "Context menu"): Copy, or
// Copy Selected Text when part of the message is selected (Telegram's text selection lifted into the menu); for a
// message that did not go, the reason, Resend and Delete; one on its way can be deleted; the user's message, Edit.
import { memo, useRef } from '../../lib/teact/teact';
import { getActions } from '../../global';

import type { ApiMessage } from '../../api/types';
import type { IAnchorPosition } from '../../types';

import { getMessageHtmlId } from '../../global/helpers';
import { copyTextToClipboard } from '../../util/clipboard';
import { isLocalMessageId } from '../../util/keys/messageKey';
import {
  deleteOutgoing, isDraftChat, outgoingForMessage, resendOutgoing,
} from '../api/session';
import { STRINGS } from '../strings';

import useLang from '../../hooks/useLang';
import useLastCallback from '../../hooks/useLastCallback';

import Menu from '../../components/ui/Menu';
import MenuItem from '../../components/ui/MenuItem';
import MenuSeparator from '../../components/ui/MenuSeparator';

type OwnProps = {
  message: ApiMessage;
  isOpen: boolean;
  anchor: IAnchorPosition;
  onClose: NoneToVoidFunction;
  onCloseAnimationEnd: NoneToVoidFunction;
};

/** The text of the message the user selected, when the selection is in it */
function selectedTextIn(message: ApiMessage) {
  const selection = window.getSelection();
  const element = document.getElementById(getMessageHtmlId(message.id));
  if (!selection || selection.isCollapsed || !element) return undefined;
  const range = selection.getRangeAt(0);
  if (!element.contains(range.commonAncestorContainer)) return undefined;
  return selection.toString() || undefined;
}

const MessageMenu = ({
  message, isOpen, anchor, onClose, onCloseAnimationEnd,
}: OwnProps) => {
  const lang = useLang();
  const menuRef = useRef<HTMLDivElement>();
  // Read when the menu opens: a click in it would clear the selection
  const selectedRef = useRef<string | undefined>();
  if (isOpen && selectedRef.current === undefined) selectedRef.current = selectedTextIn(message) ?? '';

  const text = message.tau?.copyText ?? message.content.text?.text ?? '';
  const outgoing = outgoingForMessage(message.chatId, message.id);
  const isFailed = outgoing?.state.type === 'failed';
  // The user's message in the transcript: an edit forks the chat before it (Web A's edit in the field, then a fork)
  const canEdit = message.isOutgoing && !outgoing && !isLocalMessageId(message.id) && !isDraftChat(message.chatId);

  const getTriggerElement = useLastCallback(() => document.getElementById(getMessageHtmlId(message.id)));
  const getRootElement = useLastCallback(() => document.querySelector('.MessageList') ?? document.body);
  const getMenuElement = useLastCallback(() => menuRef.current);
  const getLayout = useLastCallback(() => ({ withPortal: true }));

  const copy = (value: string) => {
    copyTextToClipboard(value);
    getActions().showNotification({ message: { key: 'TextCopied' } });
    onClose();
  };

  const selected = selectedRef.current;

  return (
    <Menu
      ref={menuRef}
      isOpen={isOpen}
      anchor={anchor}
      getTriggerElement={getTriggerElement}
      getRootElement={getRootElement}
      getMenuElement={getMenuElement}
      getLayout={getLayout}
      className="tau-message-menu"
      autoClose
      withPortal
      onClose={onClose}
      onCloseAnimationEnd={() => {
        selectedRef.current = undefined;
        onCloseAnimationEnd();
      }}
    >
      {isFailed && outgoing.state.type === 'failed' && (
        <>
          <MenuItem disabled>{outgoing.state.message}</MenuItem>
          <MenuSeparator />
          <MenuItem
            icon="reload"
            onClick={() => {
              resendOutgoing(outgoing.requestId);
              onClose();
            }}
          >
            {STRINGS.MenuResend}
          </MenuItem>
        </>
      )}
      {selected ? (
        <MenuItem icon="copy" onClick={() => copy(selected)}>{lang('ContextCopySelected')}</MenuItem>
      ) : text && (
        <MenuItem icon="copy" onClick={() => copy(text)}>{lang('Copy')}</MenuItem>
      )}
      {canEdit && (
        <MenuItem
          icon="edit"
          onClick={() => {
            getActions().startEditingMessage({ messageId: message.id });
            onClose();
          }}
        >
          {lang('Edit')}
        </MenuItem>
      )}
      {outgoing && (outgoing.state.type === 'failed' || outgoing.state.type === 'pending'
        || outgoing.state.type === 'queued') && (
        <MenuItem
          icon="delete"
          destructive
          onClick={() => {
            deleteOutgoing(outgoing.requestId);
            onClose();
          }}
        >
          {lang('Delete')}
        </MenuItem>
      )}
    </Menu>
  );
};

export default memo(MessageMenu);
