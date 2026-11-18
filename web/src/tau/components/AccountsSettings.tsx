// Settings > Accounts (docs/accounts.md; iOS's Accounts tab): a server's accounts in one list, each with its provider's
// logo, what it is under its name ("in use" when the provider has others), and its usage at the right in two small bars;
// the keys from the server's environment; Add Account last, which opens the login (LoginModal.tsx). Several servers:
// one at a time, picked above. A click opens the account with a large bar per limit; a right click has its actions.
// In Web A's settings in place of Devices, which tau has none of.
import { memo, useEffect, useState } from '../../lib/teact/teact';
import { getActions } from '../../global';

import type { ProviderAccount, UsageWindow } from '../api/accounts';
import type { ServerAccounts } from '../api/session';

import buildClassName from '../../util/buildClassName';
import {
  accountTitle, attentionCount, durationText, levelOf, paceText, percentText, serviceName, windowTitle,
} from '../api/accounts';
import { accountsOfServers, onAccountsChange, onServersChange, requestAccounts } from '../api/session';
import { STRINGS } from '../strings';

import useHistoryBack from '../../hooks/useHistoryBack';

import Island, { IslandDescription, IslandTitle } from '../../components/gili/layout/Island';
import Button from '../../components/ui/Button';
import ConfirmDialog from '../../components/ui/ConfirmDialog';
import InputText from '../../components/ui/InputText';
import ListItem from '../../components/ui/ListItem';
import Modal from '../../components/ui/Modal';
import { openLogin } from './LoginModal';
import ProviderAvatar from './ProviderAvatar';

import styles from './AccountsSettings.module.scss';

type OwnProps = {
  isActive?: boolean;
  onReset: () => void;
};

// Reset times count down while the screen shows
const TICK_MS = 30_000;
// Usage older than this is asked for again when the screen opens
const STALE_MS = 60_000;
const NOW_MS = 60_000;

const AccountsSettings = ({ isActive, onReset }: OwnProps) => {
  useHistoryBack({ isActive, onBack: onReset });
  const [servers, setServers] = useState(accountsOfServers);
  const [now, setNow] = useState(() => Date.now());
  const [opened, setOpened] = useState<{ slot: number; id: string }>();
  const [renaming, setRenaming] = useState<{ slot: number; account: ProviderAccount }>();
  const [signingOut, setSigningOut] = useState<{ slot: number; account: ProviderAccount }>();
  const [pickedSlot, setPickedSlot] = useState<number>();

  useEffect(() => {
    const update = () => setServers(accountsOfServers());
    const stopAccounts = onAccountsChange(update);
    const stopServers = onServersChange(update);
    return () => {
      stopAccounts();
      stopServers();
    };
  }, []);

  useEffect(() => {
    if (!isActive) return undefined;
    for (const server of accountsOfServers()) {
      const isStale = server.state?.accounts.some((account) => account.type === 'oauth'
        && Date.now() - (account.usage?.at ?? 0) > STALE_MS);
      if (isStale) void requestAccounts(server.slot, 'accounts.refresh').catch(() => undefined);
    }
    const timer = window.setInterval(() => setNow(Date.now()), TICK_MS);
    return () => window.clearInterval(timer);
  }, [isActive]);

  const server = servers.find((each) => each.slot === pickedSlot) ?? servers[0];
  const openedServer = opened && servers.find((each) => each.slot === opened.slot);
  const openedAccount = opened && openedServer?.state?.accounts.find((account) => account.id === opened.id);

  return (
    <div className="settings-content custom-scroll" data-tau-accounts>
      {servers.length > 1 && (
        <Island>
          <div className={styles.servers} role="tablist">
            {servers.map((each) => (
              <button
                key={each.slot}
                type="button"
                role="tab"
                aria-selected={each.slot === server.slot}
                className={buildClassName(styles.server, each.slot === server.slot && styles.selected)}
                onClick={() => setPickedSlot(each.slot)}
              >
                {each.name}
              </button>
            ))}
          </div>
        </Island>
      )}
      {server && (
        <ServerSection
          server={server}
          now={now}
          onOpen={(id) => setOpened({ slot: server.slot, id })}
          onRename={(account) => setRenaming({ slot: server.slot, account })}
          onSignOut={(account) => setSigningOut({ slot: server.slot, account })}
        />
      )}
      <AccountModal
        account={openedAccount}
        server={openedServer}
        now={now}
        onClose={() => setOpened(undefined)}
        onRename={(account) => setRenaming({ slot: opened!.slot, account })}
        onSignOut={(account) => setSigningOut({ slot: opened!.slot, account })}
      />
      <RenameAccountModal
        renaming={renaming}
        onClose={() => setRenaming(undefined)}
      />
      <ConfirmDialog
        isOpen={Boolean(signingOut)}
        title={STRINGS.AccountsSignOut}
        text={signingOut ? signOutText(signingOut.account, servers.find((each) => each.slot === signingOut.slot)) : ''}
        confirmLabel={STRINGS.AccountsSignOut}
        confirmIsDestructive
        confirmHandler={() => {
          void requestAccounts(signingOut!.slot, 'accounts.remove', { id: signingOut!.account.id });
          if (opened?.id === signingOut!.account.id) setOpened(undefined);
          setSigningOut(undefined);
        }}
        onClose={() => setSigningOut(undefined)}
      />
    </div>
  );
};

function ServerSection({
  server, now, onOpen, onRename, onSignOut,
}: {
  server: ServerAccounts;
  now: number;
  onOpen: (id: string) => void;
  onRename: (account: ProviderAccount) => void;
  onSignOut: (account: ProviderAccount) => void;
}) {
  const { state } = server;
  if (!state) {
    return (
      <>
        <Island>
          <ListItem inactive>
            <span className={styles.muted}>
              {server.hasNoAccounts ? STRINGS.AccountsNotAvailable : STRINGS.AccountsStarting}
            </span>
          </ListItem>
        </Island>
        {server.hasNoAccounts && <IslandDescription>{`${server.name} ${STRINGS.AccountsTooOld}`}</IslandDescription>}
      </>
    );
  }
  // Subscriptions first, then keys, as the server has them otherwise
  const accounts = [...state.accounts.filter((account) => account.type === 'oauth'),
    ...state.accounts.filter((account) => account.type !== 'oauth')];
  return (
    <Island>
      {accounts.map((account) => (
        <AccountRow
          key={account.id}
          slot={server.slot}
          account={account}
          hasSiblings={state.accounts.some((each) => each.provider === account.provider && each.id !== account.id)}
          now={now}
          onOpen={() => onOpen(account.id)}
          onRename={() => onRename(account)}
          onSignOut={() => onSignOut(account)}
        />
      ))}
      {state.ambient.map((ambient) => (
        <ListItem
          key={ambient.provider}
          className={styles.account}
          multiline
          inactive
          leftElement={<ProviderAvatar provider={ambient.provider} name={ambient.providerName} />}
        >
          <span className="title">{ambient.providerName}</span>
          <span className="subtitle">{`${STRINGS.AccountsFrom} ${ambient.source}`}</span>
        </ListItem>
      ))}
      <ListItem icon="add" withPrimaryColor onClick={() => openLogin(server.slot)}>
        {STRINGS.AccountsAdd}
      </ListItem>
    </Island>
  );
}

function AccountRow({
  slot, account, hasSiblings, now, onOpen, onRename, onSignOut,
}: {
  slot: number;
  account: ProviderAccount;
  hasSiblings: boolean;
  now: number;
  onOpen: NoneToVoidFunction;
  onRename: NoneToVoidFunction;
  onSignOut: NoneToVoidFunction;
}) {
  const windows = (account.usage?.windows ?? []).slice(0, 2);
  return (
    <ListItem
      className={styles.account}
      multiline
      leftElement={<ProviderAvatar provider={account.provider} name={account.providerName} />}
      rightElement={windows.length ? (
        <span className={styles.windows}>
          {windows.map((window) => <SmallWindow key={window.id} window={window} now={now} />)}
        </span>
      ) : undefined}
      contextActions={[
        ...(account.active ? [] : [{
          title: STRINGS.AccountsUse, icon: 'check' as const, handler: () => putInUse(slot, account),
        }]),
        { title: STRINGS.MenuRename, icon: 'edit' as const, handler: onRename },
        {
          title: STRINGS.AccountsSignOut, icon: 'delete' as const, destructive: true, handler: onSignOut,
        },
      ]}
      withPortalForMenu
      onClick={onOpen}
    >
      <span className="title">{accountTitle(account)}</span>
      <span className={buildClassName('subtitle', account.problem && styles.problem)}>
        {account.problem ? STRINGS.AccountsSignInAgain : subtitleOf(account, hasSiblings)}
      </span>
    </ListItem>
  );
}

/** The service and plan, or what it is; with "in use" when the provider has others */
function subtitleOf(account: ProviderAccount, hasSiblings: boolean) {
  let text = account.type === 'api_key'
    ? `${account.providerName} ${STRINGS.AccountsApiKey}${account.label && account.keyHint
      ? ` ${STRINGS.AccountsKeyEnding} ${account.keyHint}` : ''}`
    : `${serviceName(account.provider, account.providerName, true)}${account.plan ? ` ${account.plan}` : ''}`;
  if (hasSiblings && account.active) text += `, ${STRINGS.AccountsInUse}`;
  return text;
}

function SmallWindow({ window, now }: { window: UsageWindow; now: number }) {
  const level = levelOf(window, now);
  return (
    <span className={styles.small} data-level={level}>
      <span className={styles.label}>{window.label}</span>
      <Bar window={window} now={now} />
      <span className={styles.percent}>{percentText(window.usedPercent)}</span>
    </span>
  );
}

/** The used part in its level's color over the track, and a tick where an even pace would be now */
function Bar({ window, now, isLarge }: { window: UsageWindow; now: number; isLarge?: boolean }) {
  const elapsed = window.resetsAt !== undefined && window.seconds
    ? Math.min(1, Math.max(0, 1 - (window.resetsAt - now) / 1000 / window.seconds)) : undefined;
  return (
    <span className={buildClassName(styles.bar, isLarge && styles.large)} data-level={levelOf(window, now)}>
      <span className={styles.fill} style={`width: ${Math.min(100, Math.max(0, window.usedPercent))}%`} />
      {elapsed !== undefined && elapsed > 0 && elapsed < 1 && (
        <span className={styles.pace} style={`left: ${elapsed * 100}%`} />
      )}
    </span>
  );
}

function putInUse(slot: number, account: ProviderAccount) {
  void requestAccounts(slot, 'accounts.use', { id: account.id }).then(() => {
    const service = serviceName(account.provider, account.providerName, account.type === 'oauth');
    getActions().showNotification({ message: `**${accountTitle(account)}** ${STRINGS.AccountsInUseFor} ${service}` });
  });
}

function signOutText(account: ProviderAccount, server?: ServerAccounts) {
  return `${accountTitle(account)} ${STRINGS.AccountsSignedOutFrom} ${server?.name ?? ''}.`;
}

function AccountModal({
  account, server, now, onClose, onRename, onSignOut,
}: {
  account?: ProviderAccount;
  server?: ServerAccounts;
  now: number;
  onClose: NoneToVoidFunction;
  onRename: (account: ProviderAccount) => void;
  onSignOut: (account: ProviderAccount) => void;
}) {
  useEffect(() => {
    // Its numbers now: the server asks at most every 20 seconds
    if (!server || !account) return;
    void requestAccounts(server.slot, 'accounts.refresh', { id: account.id }).catch(() => undefined);
    // On opening only
    // eslint-disable-next-line react-hooks-static-deps/exhaustive-deps
  }, [account?.id]);
  if (!account || !server) return <Modal isOpen={false} onClose={onClose}>{undefined}</Modal>;
  const usage = account.usage;
  const hasSiblings = Boolean(server.state?.accounts.some((each) => each.provider === account.provider
    && each.id !== account.id));
  const subtitle = subtitleOf(account, hasSiblings);
  return (
    <Modal isOpen onClose={onClose} hasCloseButton className={styles.modal} title={accountTitle(account)}>
      <div className={styles.header}>
        <ProviderAvatar provider={account.provider} name={account.providerName} isLarge />
        <div className={styles.subtitle}>{subtitle}</div>
      </div>
      {account.problem && (
        <>
          <Island>
            <ListItem withPrimaryColor onClick={() => openLogin(server.slot, account)}>
              {STRINGS.AccountsSignInAgain}
            </ListItem>
          </Island>
          <IslandDescription>{`${STRINGS.AccountsProblem} ${account.problem}`}</IslandDescription>
        </>
      )}
      {!account.active && (
        <>
          <Island>
            <ListItem withPrimaryColor onClick={() => putInUse(server.slot, account)}>
              {STRINGS.AccountsUse}
            </ListItem>
          </Island>
          <IslandDescription>{STRINGS.AccountsUseFooter}</IslandDescription>
        </>
      )}
      {usage && usage.windows.length > 0 && (
        <>
          <IslandTitle>{STRINGS.AccountsUsage}</IslandTitle>
          <Island>
            {usage.windows.map((window) => {
              const pace = paceText(window, now);
              const level = levelOf(window, now);
              return (
                <div key={window.id} className={styles.window} data-level={level}>
                  <div className={styles.windowTop}>
                    <span>{windowTitle(window)}</span>
                    <span className={styles.windowPercent}>{percentText(window.usedPercent)}</span>
                  </div>
                  <Bar window={window} now={now} isLarge />
                  <div className={styles.windowNote}>
                    {window.resetsAt === undefined ? ''
                      : window.resetsAt <= now ? STRINGS.AccountsResetsNow
                        : `${STRINGS.AccountsResetsIn} ${durationText(window.resetsAt - now)}`}
                  </div>
                  {pace && <div className={styles.windowPace}>{pace}</div>}
                </div>
              );
            })}
            {usage.credits && (
              <ListItem inactive rightElement={<span className="settings-item__current-value">{usage.credits}</span>}>
                {STRINGS.AccountsBeyondPlan}
              </ListItem>
            )}
          </Island>
          {usage.at > 0 && (
            <IslandDescription>
              {now - usage.at < NOW_MS ? STRINGS.AccountsUpdatedNow
                : `${STRINGS.AccountsUpdated} ${durationText(now - usage.at)} ${STRINGS.AccountsAgo}`}
            </IslandDescription>
          )}
        </>
      )}
      <Island>
        <ListItem onClick={() => onRename(account)}>{STRINGS.MenuRename}</ListItem>
        <ListItem destructive onClick={() => onSignOut(account)}>
          {STRINGS.AccountsSignOut}
        </ListItem>
      </Island>
    </Modal>
  );
}

function RenameAccountModal({
  renaming, onClose,
}: {
  renaming?: { slot: number; account: ProviderAccount };
  onClose: NoneToVoidFunction;
}) {
  const [value, setValue] = useState('');
  useEffect(() => {
    setValue(renaming?.account.label ?? '');
  }, [renaming]);
  const save = () => {
    if (!renaming) return;
    void requestAccounts(renaming.slot, 'accounts.rename', { id: renaming.account.id, label: value.trim() });
    onClose();
  };
  return (
    <Modal isOpen={Boolean(renaming)} onClose={onClose} onEnter={save} title={STRINGS.AccountsName} isSlim>
      <InputText
        value={value}
        placeholder={renaming?.account.email ?? renaming?.account.providerName}
        onChange={(e) => setValue(e.currentTarget.value)}
      />
      <div className="dialog-buttons">
        <Button className="confirm-dialog-button" isText onClick={save}>{STRINGS.Save}</Button>
        <Button className="confirm-dialog-button" isText onClick={onClose}>{STRINGS.Cancel}</Button>
      </div>
    </Modal>
  );
}

/** How many accounts need something done, on every server: Settings' count beside Accounts */
export function useAccountsAttention() {
  const [count, setCount] = useState(countAttention);
  useEffect(() => onAccountsChange(() => setCount(countAttention())), []);
  return count;
}

function countAttention() {
  return accountsOfServers().reduce((sum, server) => sum + (server.state ? attentionCount(server.state) : 0), 0);
}

export default memo(AccountsSettings);
