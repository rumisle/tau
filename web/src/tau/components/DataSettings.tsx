// Settings > Data and Storage (iOS's DataStorageController, after Telegram's): what tau keeps in this browser, and
// what it sends to and receives from each server; in place of Web A's auto-download settings, which tau has no use
// for. Clear Cache drops the chats' kept entries (db/entries.ts), which load again when opened.
import { memo, useEffect, useState } from '../../lib/teact/teact';
import { getActions } from '../../global';

import { servers } from '../api/session';
import {
  formatBytes, networkUsage, onNetworkUsage, resetNetworkUsage,
} from '../api/usage';
import { draftBytes } from '../db/drafts';
import { cacheBytes, clearCache } from '../db/entries';
import { outboxBytes } from '../db/outbox';
import { outboxFileBytes } from '../db/outboxFiles';
import { STRINGS } from '../strings';

import useForceUpdate from '../../hooks/useForceUpdate';
import useHistoryBack from '../../hooks/useHistoryBack';

import Island, { IslandDescription, IslandTitle } from '../../components/gili/layout/Island';
import ConfirmDialog from '../../components/ui/ConfirmDialog';
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
  const [history, setHistory] = useState(0);
  const [isClearing, setIsClearing] = useState(false);
  const forceUpdate = useForceUpdate();

  useEffect(() => {
    if (!isActive) return undefined;
    void Promise.all([outboxBytes(), outboxFileBytes()]).then(([items, files]) => setUnsent(items + files));
    void cacheBytes().then(setHistory);
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
        <ListItem narrow inactive rightElement={value(history)}>{STRINGS.ChatHistory}</ListItem>
        <ListItem narrow inactive rightElement={value(unsent)}>{STRINGS.UnsentMessages}</ListItem>
        <ListItem narrow inactive rightElement={value(drafts)}>{STRINGS.Drafts}</ListItem>
      </Island>
      <IslandDescription>{STRINGS.StorageFooter}</IslandDescription>
      <Island>
        <ListItem narrow destructive disabled={!history} onClick={() => setIsClearing(true)}>
          {`${STRINGS.ClearCache} (${formatBytes(history)})`}
        </ListItem>
      </Island>
      <IslandDescription>{STRINGS.ClearCacheFooter}</IslandDescription>
      <ConfirmDialog
        isOpen={isClearing}
        title={STRINGS.ClearCache}
        text={STRINGS.ClearCacheFooter}
        confirmLabel={`${STRINGS.Clear} ${formatBytes(history)}`}
        confirmIsDestructive
        confirmHandler={() => {
          setIsClearing(false);
          const bytes = history;
          void clearCache().then(() => {
            setHistory(0);
            getActions().showNotification({ message: `${formatBytes(bytes)} ${STRINGS.Cleared}` });
          });
        }}
        onClose={() => setIsClearing(false)}
      />

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
