// Send's menu while the agent works, on a right-click on Send, in place of Web A's (Send Without Sound, Schedule): the
// field's message as a follow-up, after the run instead of at its next step, or Stop and Send (docs/sending.md; iOS
// opens it with a long press, as Telegram's send button opens Schedule Message).
import { memo } from '../../lib/teact/teact';

import { STRINGS } from '../strings';

import Menu from '../../components/ui/Menu';
import MenuItem from '../../components/ui/MenuItem';

type OwnProps = {
  isOpen: boolean;
  onFollowUp: NoneToVoidFunction;
  onStopAndSend: NoneToVoidFunction;
  onClose: NoneToVoidFunction;
  onCloseAnimationEnd?: NoneToVoidFunction;
};

const SendMenu = ({
  isOpen, onFollowUp, onStopAndSend, onClose, onCloseAnimationEnd,
}: OwnProps) => {
  return (
    <Menu
      isOpen={isOpen}
      autoClose
      positionX="right"
      positionY="bottom"
      className="CustomSendMenu fluid with-menu-transitions tau-send-menu"
      onClose={onClose}
      onCloseAnimationEnd={onCloseAnimationEnd}
    >
      <MenuItem icon="schedule" onClick={onFollowUp}>{STRINGS.SendFollowUp}</MenuItem>
      <MenuItem icon="stop" onClick={onStopAndSend}>{STRINGS.SendStopAndSend}</MenuItem>
    </Menu>
  );
};

export default memo(SendMenu);
