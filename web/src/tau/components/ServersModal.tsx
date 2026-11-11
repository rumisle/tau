// Servers (ios/Tau/Settings/ServersController.swift, after Telegram's proxy list): every server this app talks to, with
// its status and how long it takes to answer; one is added by its address and token, and one added can be removed
// (its chats leave the list). From the main menu; its own root, so it outlives the menu.
import { memo, useEffect, useRef, useState } from '../../lib/teact/teact';
import TeactDOM from '../../lib/teact/teact-dom';

import type { ServerInfo } from '../api/session';

import { originOf } from '../api/servers';
import {
  addServer, hostOf, onServersChange, pingServer, removeServer, servers,
} from '../api/session';
import { STRINGS } from '../strings';

import Button from '../../components/ui/Button';
import InputText from '../../components/ui/InputText';
import ListItem from '../../components/ui/ListItem';
import Modal from '../../components/ui/Modal';

type OwnProps = {
  isOpen: boolean;
  onClose: NoneToVoidFunction;
};

const STATUS: Record<ServerInfo['status'], string> = {
  connecting: STRINGS.ServerConnecting,
  ready: STRINGS.ServerConnected,
  refused: STRINGS.ServerRefused,
  unreachable: STRINGS.ServerUnreachable,
};

const ServersModal = ({ isOpen, onClose }: OwnProps) => {
  const [list, setList] = useState(servers);
  const [pings, setPings] = useState<Record<number, number | undefined>>({});
  const [isAdding, setIsAdding] = useState(false);
  const [error, setError] = useState<string>();
  const [isBusy, setIsBusy] = useState(false);
  const addressRef = useRef<HTMLInputElement>();
  const tokenRef = useRef<HTMLInputElement>();

  useEffect(() => onServersChange(() => setList(servers())), []);

  useEffect(() => {
    if (!isOpen) return;
    for (const server of list) {
      void pingServer(server.slot).then((ms) => setPings((current) => ({ ...current, [server.slot]: ms })));
    }
    // Once per opening, and for a server added
    // eslint-disable-next-line react-hooks-static-deps/exhaustive-deps
  }, [isOpen, list.length]);

  useEffect(() => {
    if (isAdding) addressRef.current?.focus();
  }, [isAdding]);

  const add = async () => {
    // The fields' own values: Teact renders what was typed on the next frame
    const origin = originOf(addressRef.current?.value ?? '');
    const token = tokenRef.current?.value.trim() ?? '';
    if (!origin) {
      setError(STRINGS.ServerBadAddress);
      return;
    }
    setIsBusy(true);
    const result = await addServer(origin, token);
    setIsBusy(false);
    if (result === 'ok') {
      setIsAdding(false);
      setError(undefined);
    } else {
      setError(result === 'token' ? STRINGS.ServerRefused
        : result === 'known' ? STRINGS.ServerKnown : STRINGS.ServerUnreachable);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      onEnter={isAdding ? () => void add() : undefined}
      title={STRINGS.MenuServers}
      className="tau-servers"
      hasCloseButton
    >
      {list.map((server) => {
        const ping = pings[server.slot];
        return (
          <ListItem
            key={server.slot}
            className="tau-server"
            contextActions={server.slot === 0 ? undefined : [{
              title: STRINGS.ServerRemove,
              icon: 'delete',
              destructive: true,
              handler: () => void removeServer(server.slot),
            }]}
            withPortalForMenu
            multiline
          >
            <div className="multiline-item">
              <span className="title">{hostOf(server.origin)}</span>
              <span className="subtitle" data-status={server.status}>
                {STATUS[server.status]}
                {server.status === 'ready' && ping !== undefined ? ` · ${ping} ms` : ''}
                {` · ${server.chats} ${server.chats === 1 ? STRINGS.ServerChat : STRINGS.ServerChats}`}
                {server.slot === 0 ? ` · ${STRINGS.ServerThis}` : ''}
              </span>
            </div>
          </ListItem>
        );
      })}
      {isAdding ? (
        <div className="tau-server-add">
          <InputText ref={addressRef} placeholder={STRINGS.ServerAddress} />
          <InputText ref={tokenRef} placeholder={STRINGS.ServerToken} error={error} />
          <div className="dialog-buttons">
            <Button className="confirm-dialog-button" isText disabled={isBusy} onClick={() => void add()}>
              {STRINGS.ServerAdd}
            </Button>
            <Button className="confirm-dialog-button" isText onClick={() => setIsAdding(false)}>
              {STRINGS.Cancel}
            </Button>
          </div>
        </div>
      ) : (
        <ListItem icon="add" onClick={() => setIsAdding(true)}>{STRINGS.ServerAddTitle}</ListItem>
      )}
    </Modal>
  );
};

const Memo = memo(ServersModal);

let root: HTMLDivElement | undefined;
let opened = 0;
const CLOSE_MS = 300;

export function openServers() {
  if (!root) {
    root = document.createElement('div');
    document.body.appendChild(root);
  }
  const container = root;
  const render = (isOpen: boolean) => TeactDOM.render(<Memo isOpen={isOpen} onClose={() => close()} />, container);
  const token = ++opened;
  const close = () => {
    render(false);
    window.setTimeout(() => {
      if (opened === token) TeactDOM.render(undefined, container);
    }, CLOSE_MS);
  };
  render(true);
}
