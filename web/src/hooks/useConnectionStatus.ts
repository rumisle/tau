import type { GlobalState } from '../global/types';
import type { LangFn } from '../util/localization';

import { IS_TAU } from '../tau/config'; // tau: Connecting apart from no network
import useBrowserOnline from './window/useBrowserOnline';

export enum ConnectionStatus {
  waitingForNetwork,
  syncing,
  online,
}

type ConnectionStatusPosition =
  'overlay'
  | 'minimized'
  | 'middleHeader'
  | 'none';

export default function useConnectionStatus(
  lang: LangFn,
  connectionState: GlobalState['connectionState'],
  isSyncing: boolean | undefined,
  hasMiddleHeader: boolean,
  isMinimized?: boolean,
  isDisabled?: boolean,
) {
  let status: ConnectionStatus;
  const isBrowserOnline = useBrowserOnline();
  if (!isBrowserOnline || connectionState === 'connectionStateConnecting') {
    status = ConnectionStatus.waitingForNetwork;
  } else if (isSyncing) {
    status = ConnectionStatus.syncing;
  } else {
    status = ConnectionStatus.online;
  }

  let position: ConnectionStatusPosition;
  if (status === ConnectionStatus.online || isDisabled) {
    position = 'none';
  } else if (hasMiddleHeader) {
    position = 'middleHeader';
  } else if (isMinimized) {
    position = 'minimized';
  } else {
    position = 'overlay';
  }

  let text: string | undefined;
  if (status === ConnectionStatus.waitingForNetwork) {
    // tau: online, the server is what is not there yet: Connecting, as iOS's title says
    text = IS_TAU && isBrowserOnline ? lang('Connecting') : lang('WaitingForNetwork');
  } else if (status === ConnectionStatus.syncing) {
    text = lang('Updating');
  }

  if (position === 'middleHeader') {
    text = text!.toLowerCase().replace(/\.+$/, '');
  }

  return {
    connectionStatus: status,
    connectionStatusPosition: position,
    connectionStatusText: text,
  };
}
