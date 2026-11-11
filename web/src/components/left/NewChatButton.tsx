import {
  useCallback, useEffect, useMemo, useState,
} from '../../lib/teact/teact';
import { getActions } from '../../global';

import buildClassName from '../../util/buildClassName';
import { hostOf, openNewChat, servers } from '../../tau/api/session'; // tau: New Chat is a draft at once
import { IS_TAU } from '../../tau/config'; // tau: New Chat is a draft at once

import useLang from '../../hooks/useLang';

import Icon from '../common/icons/Icon';
import Button from '../ui/Button';
import Menu from '../ui/Menu';
import MenuItem from '../ui/MenuItem';

import './NewChatButton.scss';

type OwnProps = {
  isShown: boolean;
  onNewPrivateChat: () => void;
  onNewChannel: () => void;
  onNewGroup: () => void;
  isAccountFrozen?: boolean;
};

const NewChatButton = ({
  isShown,
  onNewPrivateChat,
  onNewChannel,
  onNewGroup,
  isAccountFrozen,
}: OwnProps) => {
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  const { openFrozenAccountModal } = getActions();

  const shouldRender = isShown || isMenuOpen;

  useEffect(() => {
    if (!shouldRender) {
      setIsMenuOpen(false);
    }
  }, [shouldRender]);

  const lang = useLang();

  const fabClassName = buildClassName(
    'NewChatButton',
    shouldRender && 'revealed',
    isMenuOpen && 'menu-is-open',
  );

  const toggleIsMenuOpen = useCallback(() => {
    if (IS_TAU) { // tau: New Chat is a draft at once, no menu
      openNewChat();
      return;
    }
    if (isAccountFrozen) {
      openFrozenAccountModal();
      return;
    }
    setIsMenuOpen(!isMenuOpen);
  }, [isMenuOpen, isAccountFrozen]);

  const handleClose = useCallback(() => {
    setIsMenuOpen(false);
  }, []);

  const menuItems = useMemo(() => (
    <>
      <MenuItem icon="channel" onClick={onNewChannel}>{lang('NewChannel')}</MenuItem>
      <MenuItem icon="group" onClick={onNewGroup}>{lang('NewGroup')}</MenuItem>
      <MenuItem icon="user" onClick={onNewPrivateChat}>{lang('NewMessageTitle')}</MenuItem>
    </>
  ), [lang, onNewChannel, onNewGroup, onNewPrivateChat]);

  return (
    <div className={fabClassName} dir={lang.isRtl ? 'rtl' : undefined}>
      <Button
        round
        color="primary"
        className={isMenuOpen ? 'active' : ''}
        onClick={toggleIsMenuOpen}
        onContextMenu={IS_TAU ? (e) => { // tau: New Chat on another server, with several
          e.preventDefault(); // tau: see above
          if (servers().length > 1) setIsMenuOpen(true); // tau: see above
        } : undefined} // tau: see above
        ariaLabel={lang(isMenuOpen ? 'Close' : 'NewMessageTitle')}
        tabIndex={-1}
      >
        <Icon name="new-chat-filled" />
        <Icon name="close" />
      </Button>
      <Menu
        isOpen={isMenuOpen}
        positionX={lang.isRtl ? 'left' : 'right'}
        positionY="bottom"
        autoClose
        onClose={handleClose}
      >
        {IS_TAU ? servers().map((server) => ( // tau: the servers, New Chat on one (a right-click, with several)
          <MenuItem key={server.slot} icon="new-chat-filled" onClick={() => openNewChat(server.slot)}>
            {hostOf(server.origin)}
          </MenuItem>
        )) : menuItems}
      </Menu>
    </div>
  );
};

export default NewChatButton;
