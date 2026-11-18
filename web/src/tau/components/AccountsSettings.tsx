// Settings > Accounts (docs/accounts.md; iOS's Accounts tab): each server's accounts by service, their usage in small
// bars with a tick where an even pace would be, the one in use checked; a click opens the account with a large bar per
// limit, a right click has its actions; Add Account opens the login (LoginModal.tsx); keys the server has from its
// environment. In Web A's settings in place of Devices, which tau has none of.
import { memo, useEffect, useState } from '../../lib/teact/teact';
import { getActions } from '../../global';

import type { ProviderAccount, UsageWindow } from '../api/accounts';
import type { ServerAccounts } from '../api/session';

import buildClassName from '../../util/buildClassName';
import {
  accountTitle, attentionCount, durationText, groupAccounts, levelOf, paceText, percentText, serviceName, windowTitle,
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

import styles from './AccountsSettings.module.scss';

type OwnProps = {
  isActive?: boolean;
  onReset: () => void;
};

// Reset times count down while the screen shows
const TICK_MS = 30_000;
// Usage older than this is asked for again when the screen opens
const STALE_MS = 60_000;
const NOW_MS = 90_000;
// Telegram's avatar colors, by the account
const AVATAR_COLORS = ['#FF516A', '#FFA85C', '#B694F9', '#54CB68', '#2A9EF1', '#29D6E0', '#FF7EAB'];

const AccountsSettings = ({ isActive, onReset }: OwnProps) => {
  useHistoryBack({ isActive, onBack: onReset });
  const [servers, setServers] = useState(accountsOfServers);
  const [now, setNow] = useState(() => Date.now());
  const [opened, setOpened] = useState<{ slot: number; id: string }>();
  const [renaming, setRenaming] = useState<{ slot: number; account: ProviderAccount }>();
  const [signingOut, setSigningOut] = useState<{ slot: number; account: ProviderAccount }>();

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

  const isSeveral = servers.length > 1;
  const openedServer = opened && servers.find((server) => server.slot === opened.slot);
  const openedAccount = opened && openedServer?.state?.accounts.find((account) => account.id === opened.id);

  return (
    <div className="settings-content custom-scroll" data-tau-accounts>
      {servers.map((server) => (
        <ServerSection
          key={server.slot}
          server={server}
          isSeveral={isSeveral}
          now={now}
          onOpen={(id) => setOpened({ slot: server.slot, id })}
          onRename={(account) => setRenaming({ slot: server.slot, account })}
          onSignOut={(account) => setSigningOut({ slot: server.slot, account })}
        />
      ))}
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
  server, isSeveral, now, onOpen, onRename, onSignOut,
}: {
  server: ServerAccounts;
  isSeveral: boolean;
  now: number;
  onOpen: (id: string) => void;
  onRename: (account: ProviderAccount) => void;
  onSignOut: (account: ProviderAccount) => void;
}) {
  const { state } = server;
  const header = isSeveral && <IslandTitle>{server.name}</IslandTitle>;
  if (!state) {
    return (
      <>
        {header}
        <Island>
          <ListItem inactive>
            <span className={styles.muted}>
              {server.hasNoAccounts ? STRINGS.AccountsNone : STRINGS.AccountsStarting}
            </span>
          </ListItem>
        </Island>
        {server.hasNoAccounts && <IslandDescription>{`${server.name} ${STRINGS.AccountsTooOld}`}</IslandDescription>}
      </>
    );
  }
  const groups = groupAccounts(state.accounts);
  const times = state.accounts.map((account) => account.usage?.at ?? 0).filter((at) => at > 0);
  const oldest = times.length ? Math.min(...times) : undefined;
  const addItem = (
    <ListItem icon="add" withPrimaryColor onClick={() => openLogin(server.slot)}>
      {STRINGS.AccountsAdd}
    </ListItem>
  );
  return (
    <>
      {header}
      {!state.accounts.length && (
        <Island>
          <ListItem inactive><span className={styles.muted}>{STRINGS.AccountsNone}</span></ListItem>
          {addItem}
        </Island>
      )}
      {groups.map(([name, accounts]) => (
        <>
          <IslandTitle key={`${name}-title`}>{name}</IslandTitle>
          <Island key={name}>
            {accounts.map((account) => (
              <AccountRow
                key={account.id}
                slot={server.slot}
                account={account}
                now={now}
                onOpen={() => onOpen(account.id)}
                onRename={() => onRename(account)}
                onSignOut={() => onSignOut(account)}
              />
            ))}
          </Island>
        </>
      ))}
      {state.accounts.length > 0 && <Island>{addItem}</Island>}
      {state.ambient.length > 0 && (
        <>
          <IslandTitle>{STRINGS.AccountsAmbient}</IslandTitle>
          <Island>
            {state.ambient.map((ambient) => (
              <ListItem key={ambient.provider} multiline inactive>
                <span className="title">{ambient.providerName}</span>
                <span className="subtitle">{ambient.source}</span>
              </ListItem>
            ))}
          </Island>
        </>
      )}
      {oldest !== undefined && (
        <IslandDescription>
          {`${now - oldest < NOW_MS ? STRINGS.AccountsAsOfNow
            : `${STRINGS.AccountsAsOf} ${durationText(now - oldest)} ${STRINGS.AccountsAgo}`} ${STRINGS.AccountsPace}`}
        </IslandDescription>
      )}
    </>
  );
}

function AccountRow({
  slot, account, now, onOpen, onRename, onSignOut,
}: {
  slot: number;
  account: ProviderAccount;
  now: number;
  onOpen: NoneToVoidFunction;
  onRename: NoneToVoidFunction;
  onSignOut: NoneToVoidFunction;
}) {
  const windows = (account.usage?.windows ?? []).slice(0, 2);
  const detail = account.problem ? `${STRINGS.AccountsSignInAgain}: ${account.problem}`
    : !windows.length ? detailOf(account) : undefined;
  return (
    <ListItem
      className={styles.account}
      multiline
      leftElement={<AccountAvatar account={account} />}
      rightElement={account.active ? <span className={styles.check} aria-label={STRINGS.AccountsInUse} /> : undefined}
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
      <span className="title">
        {accountTitle(account)}
        {account.plan && <span className={styles.plan}>{account.plan}</span>}
      </span>
      {detail ? (
        <span className={buildClassName('subtitle', account.problem && styles.problem)}>{detail}</span>
      ) : (
        <span className={buildClassName('subtitle', styles.windows)}>
          {windows.map((window) => <SmallWindow key={window.id} window={window} now={now} />)}
        </span>
      )}
    </ListItem>
  );
}

function detailOf(account: ProviderAccount) {
  if (account.keyHint) {
    return account.label ? `${STRINGS.AccountsApiKey}, ${STRINGS.AccountsKeyEnding} ${account.keyHint}`
      : STRINGS.AccountsApiKey;
  }
  if (account.type === 'api_key') return STRINGS.AccountsApiKey;
  if (account.usage?.error) return account.usage.error;
  return account.label && account.email ? account.email : serviceName(account.provider, account.providerName, true);
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

function AccountAvatar({ account, isLarge }: { account: ProviderAccount; isLarge?: boolean }) {
  const name = account.label ?? account.email ?? account.providerName;
  // Stable for the account, as its color on the phone is
  let hash = 0;
  for (const char of account.id) hash = (hash * 31 + char.charCodeAt(0)) % 65_536;
  return (
    <span
      className={buildClassName(styles.avatar, isLarge && styles.large)}
      style={`background-color: ${AVATAR_COLORS[hash % AVATAR_COLORS.length]}`}
    >
      {name.trim().charAt(0).toUpperCase()}
    </span>
  );
}

function putInUse(slot: number, account: ProviderAccount) {
  void requestAccounts(slot, 'accounts.use', { id: account.id }).then(() => {
    const service = serviceName(account.provider, account.providerName, account.type === 'oauth');
    getActions().showNotification({ message: `**${accountTitle(account)}** ${STRINGS.AccountsInUseFor} ${service}` });
  });
}

/** What signing out does: the account leaves the server; the one in use, another takes its place, if any */
function signOutText(account: ProviderAccount, server?: ServerAccounts) {
  const others = server?.state?.accounts.filter((each) => each.provider === account.provider && each.id !== account.id)
    ?? [];
  const service = serviceName(account.provider, account.providerName, account.type === 'oauth');
  let text = `${accountTitle(account)} ${STRINGS.AccountsSignOutConfirm} ${server?.name ?? ''}.`;
  if (account.active) {
    text += others.length ? ` ${STRINGS.AccountsAnotherInUse}` : ` ${STRINGS.AccountsNoneLeft} ${service}.`;
  }
  return text;
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
  if (!account || !server) return <Modal isOpen={false} onClose={onClose}>{undefined}</Modal>;
  const usage = account.usage;
  const service = serviceName(account.provider, account.providerName, account.type === 'oauth');
  const key = account.keyHint ? `${STRINGS.AccountsKeyEnding} ${account.keyHint}` : STRINGS.AccountsApiKey;
  let subtitle = account.type === 'api_key' ? `${account.providerName} ${key}`
    : `${service}${account.plan ? ` ${account.plan}` : ''}`;
  if (account.active) subtitle += `, ${STRINGS.AccountsInUse}`;
  return (
    <Modal isOpen onClose={onClose} hasCloseButton className={styles.modal} title={accountTitle(account)}>
      <div className={styles.header}>
        <AccountAvatar account={account} isLarge />
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
          {usage.error && <IslandDescription>{`${STRINGS.AccountsUsageFailed} ${usage.error}`}</IslandDescription>}
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
      <p className={styles.muted}>{STRINGS.AccountsNameHint}</p>
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
