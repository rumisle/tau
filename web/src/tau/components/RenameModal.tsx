// Rename (ios/Tau/Chat/RenameChatController.swift, Telegram's title alert): a small dialog with the title selected,
// Enter saves and Esc cancels; then Telegram's toast with Undo. Web A's `updateChat` action carries it, which calls
// `updateChatTitle` (src/tau/api/methods.ts), so Undo is that action again with the title before. Its own root, so
// it outlives the menu that opened it.
import { memo, useEffect, useRef, useState } from '../../lib/teact/teact';
import TeactDOM from '../../lib/teact/teact-dom';
import { getActions } from '../../global';

import { normalizeTitle } from '../api/session';
import { STRINGS } from '../strings';

import Button from '../../components/ui/Button';
import InputText from '../../components/ui/InputText';
import Modal from '../../components/ui/Modal';

type OwnProps = {
  chatId: string;
  title: string;
  isOpen: boolean;
  onClose: NoneToVoidFunction;
};

const RenameModal = ({
  chatId, title, isOpen, onClose,
}: OwnProps) => {
  const [value, setValue] = useState(title);
  const inputRef = useRef<HTMLInputElement>();
  const isEmpty = !normalizeTitle(value);

  useEffect(() => {
    if (!isOpen) return;
    // Focused with the title selected to type over, at once: what is typed from the first key replaces it
    inputRef.current?.focus();
    inputRef.current?.select();
  }, [isOpen]);

  const save = () => {
    // The field's own value: Teact renders what was typed on the next frame, and Enter can come before it
    const next = normalizeTitle(inputRef.current?.value ?? value);
    if (!next) return;
    onClose();
    if (next === title) return;
    const { updateChat, showNotification } = getActions();
    // Web A's action asks for the about too: tau has none, and answers no updateChatAbout
    updateChat({ chatId, title: next, about: '' });
    showNotification({
      message: `${STRINGS.RenameDone} **${next}**`,
      actionText: STRINGS.Undo,
      action: { action: 'updateChat', payload: { chatId, title, about: '' } },
    });
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      onEnter={save}
      title={STRINGS.MenuRename}
      className="tau-rename"
      isSlim
    >
      <InputText
        ref={inputRef}
        value={value}
        maxLength={64}
        onChange={(e) => setValue(e.currentTarget.value)}
      />
      <div className="dialog-buttons mt-2">
        <Button className="confirm-dialog-button" isText disabled={isEmpty} onClick={save}>{STRINGS.Save}</Button>
        <Button className="confirm-dialog-button" isText onClick={onClose}>{STRINGS.Cancel}</Button>
      </div>
    </Modal>
  );
};

const Memo = memo(RenameModal);

let root: HTMLDivElement | undefined;
let opened = 0;
const CLOSE_MS = 300;

/** Opens Rename for a chat, over everything */
export function openRename(chatId: string, title: string) {
  if (!root) {
    root = document.createElement('div');
    document.body.appendChild(root);
  }
  const container = root;
  const render = (isOpen: boolean) => TeactDOM.render(
    <Memo key={`${chatId}-${title}`} chatId={chatId} title={title} isOpen={isOpen} onClose={() => close()} />,
    container,
  );
  const token = ++opened;
  const close = () => {
    render(false);
    // After the modal's closing animation, unless it opened again meanwhile
    window.setTimeout(() => {
      if (opened === token) TeactDOM.render(undefined, container);
    }, CLOSE_MS);
  };
  render(true);
}
