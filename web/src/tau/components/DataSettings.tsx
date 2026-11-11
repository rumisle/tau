// Settings > Data and Storage (iOS's DataStorageController, after Telegram's): what tau keeps in this browser, and
// what it sends to and receives from each server; in place of Web A's auto-download settings, which tau has no use
// for. Chat history has no copy here yet, so no per-chat sizes or Clear Cache.
import { memo, useEffect, useState } from '../../lib/teact/teact';

import { servers } from '../api/session';
import {
  formatBytes, networkUsage, onNetworkUsage, resetNetworkUsage,
} from '../api/usage';
import { draftBytes } from '../db/drafts';
import { outboxBytes } from '../db/outbox';
import { outboxFileBytes } from '../db/outboxFiles';
import { STRINGS } from '../strings';

import useForceUpdate from '../../hooks/useForceUpdate';
import useHistoryBack from '../../hooks/useHistoryBack';

import Island, { IslandDescription, IslandTitle } from '../../components/gili/layout/Island';
import ListItem from '../../components/ui/ListItem';

type OwnProps = {
  isActive?: boolean;
  onReset: () => void;
};

const value = (bytes: number) => <span className="settings-item__current-value">{formatBytes(bytes)}</span>;

const DataSettings = ({ isActive, onReset }: OwnProps) => {
  useHistoryBack({ isActive, onBack: onReset });
  const [unsent, setUnsent] = useState(0);
  const [drafts, setDrafts] = useState(0);
  const forceUpdate = useForceUpdate();

  useEffect(() => {
    if (!isActive) return undefined;
    void Promise.all([outboxBytes(), outboxFileBytes()]).then(([items, files]) => setUnsent(items + files));
    setDrafts(draftBytes());
    // While it shows, the counts go up with the socket's frames
    return onNetworkUsage(forceUpdate);
  }, [isActive, forceUpdate]);

  const usage = networkUsage();
  const since = new Date(usage.since).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
  return (
    <div className="settings-content custom-scroll">
      <IslandTitle>{STRINGS.StorageUsage}</IslandTitle>
      <Island>
        <ListItem narrow inactive rightElement={value(unsent)}>{STRINGS.UnsentMessages}</ListItem>
        <ListItem narrow inactive rightElement={value(drafts)}>{STRINGS.Drafts}</ListItem>
      </Island>
      <IslandDescription>{STRINGS.StorageFooter}</IslandDescription>

      <IslandTitle>{STRINGS.NetworkUsage}</IslandTitle>
      <Island>
        {servers().map(({ origin }) => {
          const { sent = 0, received = 0 } = usage.byOrigin[origin] ?? {};
          return (
            <ListItem key={origin} narrow multiline inactive rightElement={value(sent + received)}>
              <span className="title">{new URL(origin).host}</span>
              <span className="subtitle">
                {`${STRINGS.Sent} ${formatBytes(sent)}, ${STRINGS.Received.toLowerCase()} ${formatBytes(received)}`}
              </span>
            </ListItem>
          );
        })}
      </Island>
      <Island>
        <ListItem narrow destructive onClick={resetNetworkUsage}>{STRINGS.ResetStatistics}</ListItem>
      </Island>
      <IslandDescription>{`${STRINGS.Since} ${since}.`}</IslandDescription>
    </div>
  );
};

export default memo(DataSettings);
