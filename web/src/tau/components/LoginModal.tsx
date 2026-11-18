// Add Account (docs/accounts.md; iOS's AddAccountController and LoginController): every provider's sign-in and API
// key, then the login the server runs: the device code with the page a click away, the page and a field for the code
// or address to paste back, a field for a key, the flow's choices; it closes once the account is added. Closing it
// cancels the login. Its own root, so it outlives the screen that opened it.
import type { ElementRef } from '../../lib/teact/teact';
import { memo, useEffect, useRef, useState } from '../../lib/teact/teact';
import TeactDOM from '../../lib/teact/teact-dom';
import { getActions } from '../../global';

import type { AccountsState, LoginPrompt, ProviderAccount, ProviderEntry } from '../api/accounts';

import { copyTextToClipboard } from '../../util/clipboard';
import {
  accountTitle, authUrlOf, deviceCodeOf, progressOf, serviceName,
} from '../api/accounts';
import { accountsOfServers, onAccountsChange, requestAccounts } from '../api/session';
import { STRINGS } from '../strings';

import Island, { IslandDescription, IslandTitle } from '../../components/gili/layout/Island';
import Button from '../../components/ui/Button';
import ListItem from '../../components/ui/ListItem';
import Modal from '../../components/ui/Modal';
import Spinner from '../../components/ui/Spinner';
import ProviderAvatar from './ProviderAvatar';

import styles from './AccountsSettings.module.scss';

type OwnProps = {
  slot: number;
  // Sign in again to this one's provider
  account?: ProviderAccount;
  isOpen: boolean;
  onClose: NoneToVoidFunction;
};

type Chosen = ProviderEntry | { id: string; name: string };

// Subscriptions first, the best known first
const KNOWN = ['anthropic', 'openai-codex', 'github-copilot'];

const LoginModal = ({
  slot, account, isOpen, onClose,
}: OwnProps) => {
  const [state, setState] = useState<AccountsState | undefined>(() => stateOf(slot));
  const [chosen, setChosen] = useState<{ provider: Chosen; type: 'oauth' | 'api_key' }>();
  const [loginId, setLoginId] = useState<string>();
  const [startError, setStartError] = useState<string>();
  const [answer, setAnswer] = useState('');
  const [answered, setAnswered] = useState<string>();
  const inputRef = useRef<HTMLInputElement>();

  useEffect(() => onAccountsChange(() => setState(stateOf(slot))), [slot]);

  const start = (provider: Chosen, type: 'oauth' | 'api_key') => {
    setChosen({ provider, type });
    setLoginId(undefined);
    setStartError(undefined);
    setAnswer('');
    setAnswered(undefined);
    requestAccounts<{ login: string }>(slot, 'accounts.login', { provider: provider.id, type })
      .then(({ login }) => setLoginId(login))
      .catch((err: Error) => setStartError(err.message));
  };

  useEffect(() => {
    if (isOpen && account) start({ id: account.provider, name: account.providerName }, account.type);
    // Once, for the account to sign in to again
    // eslint-disable-next-line react-hooks-static-deps/exhaustive-deps
  }, [isOpen]);

  const login = loginId ? state?.logins.find((each) => each.id === loginId) : undefined;
  const done = login?.done;

  useEffect(() => {
    if (!done || !('accountId' in done)) return;
    const added = state?.accounts.find((each) => each.id === done.accountId);
    getActions().showNotification({ message: `${STRINGS.AccountsSignedInAs} **${added ? accountTitle(added) : ''}**` });
    onClose();
    // On the account added only
    // eslint-disable-next-line react-hooks-static-deps/exhaustive-deps
  }, [done]);

  useEffect(() => {
    if (login?.prompt && login.prompt.id !== answered) inputRef.current?.focus();
  }, [login?.prompt, answered]);

  const close = () => {
    if (loginId && !done) void requestAccounts(slot, 'accounts.cancel', { login: loginId }).catch(() => undefined);
    onClose();
  };

  const send = (prompt: LoginPrompt, value: string) => {
    if (!loginId || !value.trim()) return;
    setAnswered(prompt.id);
    requestAccounts(slot, 'accounts.answer', { login: loginId, prompt: prompt.id, value: value.trim() })
      .catch((err: Error) => {
        setAnswered(undefined);
        getActions().showNotification({ message: err.message });
      });
  };

  const title = chosen
    ? (chosen.type === 'oauth' ? serviceName(chosen.provider.id, chosen.provider.name, true) : chosen.provider.name)
    : STRINGS.AccountsAdd;
  const prompt = login?.prompt && login.prompt.id !== answered ? login.prompt : undefined;
  const isTyped = prompt && prompt.type !== 'select';

  return (
    <Modal
      isOpen={isOpen}
      onClose={close}
      onEnter={isTyped ? () => send(prompt, inputRef.current?.value ?? answer) : undefined}
      title={title}
      className={styles.modal}
      hasCloseButton
    >
      {!chosen ? <Providers providers={state?.providers ?? []} onChoose={start} /> : (
        <div data-tau-login={login?.id}>
          {startError || (done && 'error' in done) ? (
            <>
              <IslandTitle>{STRINGS.AccountsFailed}</IslandTitle>
              <Island>
                <ListItem withPrimaryColor onClick={() => start(chosen.provider, chosen.type)}>
                  {STRINGS.AccountsTryAgain}
                </ListItem>
              </Island>
              <IslandDescription>{startError ?? (done as { error: string }).error}</IslandDescription>
            </>
          ) : !login ? (
            <Island><Waiting text={STRINGS.AccountsStarting} /></Island>
          ) : (
            <LoginSteps
              login={login}
              prompt={prompt}
              isSending={Boolean(login.prompt && login.prompt.id === answered)}
              answer={answer}
              inputRef={inputRef}
              onAnswer={setAnswer}
              onSend={send}
            />
          )}
        </div>
      )}
    </Modal>
  );
};

function stateOf(slot: number) {
  return accountsOfServers().find((server) => server.slot === slot)?.state;
}

function Providers({
  providers, onChoose,
}: {
  providers: ProviderEntry[];
  onChoose: (provider: ProviderEntry, type: 'oauth' | 'api_key') => void;
}) {
  const rank = (provider: ProviderEntry) => {
    const known = KNOWN.indexOf(provider.id);
    return known >= 0 ? known : KNOWN.length + (provider.oauth?.subscription ? 0 : 1);
  };
  const signIns = providers.filter((provider) => provider.oauth).sort((a, b) => rank(a) - rank(b));
  const keys = providers.filter((provider) => provider.apiKey).sort((a, b) => a.name.localeCompare(b.name));
  return (
    <>
      <IslandTitle>{STRINGS.AccountsSignIn}</IslandTitle>
      <Island>
        {signIns.map((provider) => (
          <ListItem
            key={provider.id}
            className={styles.account}
            multiline
            leftElement={<ProviderAvatar provider={provider.id} name={provider.name} />}
            onClick={() => onChoose(provider, 'oauth')}
          >
            <span className="title">{serviceName(provider.id, provider.name, true)}</span>
            <span className="subtitle">{provider.oauth!.name}</span>
          </ListItem>
        ))}
      </Island>
      <IslandTitle>{STRINGS.AccountsApiKey}</IslandTitle>
      <Island>
        {keys.map((provider) => {
          // "Anthropic API key" says nothing more than "Anthropic"; "AWS credentials or bearer token" does
          const keyName = provider.apiKey!.name;
          return (
            <ListItem
              key={provider.id}
              className={styles.account}
              multiline={!keyName.startsWith(provider.name)}
              leftElement={<ProviderAvatar provider={provider.id} name={provider.name} />}
              onClick={() => onChoose(provider, 'api_key')}
            >
              <span className="title">{provider.name}</span>
              {!keyName.startsWith(provider.name) && <span className="subtitle">{keyName}</span>}
            </ListItem>
          );
        })}
      </Island>
    </>
  );
}

function LoginSteps({
  login, prompt, isSending, answer, inputRef, onAnswer, onSend,
}: {
  login: NonNullable<AccountsState['logins'][number]>;
  prompt?: LoginPrompt;
  isSending: boolean;
  answer: string;
  inputRef: ElementRef<HTMLInputElement>;
  onAnswer: (value: string) => void;
  onSend: (prompt: LoginPrompt, value: string) => void;
}) {
  const device = deviceCodeOf(login);
  const page = authUrlOf(login);
  const progress = progressOf(login);
  const host = (url: string) => new URL(url).host;
  const open = (url: string) => window.open(url, '_blank', 'noopener');
  return (
    <>
      {device ? (
        <>
          <IslandTitle>{`${STRINGS.AccountsEnterCode} ${host(device.verificationUri)}`}</IslandTitle>
          <Island>
            <button
              type="button"
              className={styles.code}
              data-tau-login-code
              onClick={() => {
                copyTextToClipboard(device.userCode);
                getActions().showNotification({ message: STRINGS.AccountsCodeCopied });
              }}
            >
              {device.userCode}
            </button>
          </Island>
          <Island>
            <ListItem
              withPrimaryColor
              onClick={() => {
                copyTextToClipboard(device.userCode);
                open(device.verificationUri);
              }}
            >
              {`${STRINGS.AccountsCopyAndOpen} ${host(device.verificationUri)}`}
            </ListItem>
            <ListItem withPrimaryColor onClick={() => copyLink(device.verificationUri)}>
              {STRINGS.AccountsCopyLink}
            </ListItem>
            <Waiting text={progress ?? STRINGS.AccountsWaiting} />
          </Island>
          <IslandDescription>{STRINGS.AccountsClosesItself}</IslandDescription>
        </>
      ) : page && (
        <>
          <Island>
            <ListItem withPrimaryColor onClick={() => open(page.url)}>
              {`${STRINGS.AccountsOpen} ${host(page.url)}`}
            </ListItem>
            <ListItem withPrimaryColor onClick={() => copyLink(page.url)}>{STRINGS.AccountsCopyLink}</ListItem>
          </Island>
          <IslandDescription>
            {login.prompt?.type !== 'manual_code' ? STRINGS.AccountsSignInThere
              : login.provider === 'anthropic' ? STRINGS.AccountsPasteCode : STRINGS.AccountsPasteAddress}
          </IslandDescription>
        </>
      )}
      {prompt?.type === 'select' && (
        <>
          <IslandTitle>{prompt.message}</IslandTitle>
          <Island>
            {prompt.options.map((option) => (
              <ListItem
                key={option.id}
                multiline={Boolean(option.description)}
                onClick={() => onSend(prompt, option.id)}
              >
                <span className="title">{option.label}</span>
                {option.description && <span className="subtitle">{option.description}</span>}
              </ListItem>
            ))}
          </Island>
        </>
      )}
      {prompt && prompt.type !== 'select' && (
        <>
          <IslandTitle>{prompt.type === 'manual_code' ? STRINGS.AccountsPasteHere : prompt.message}</IslandTitle>
          <div className={styles.answer}>
            <div className="input-group">
              <input
                ref={inputRef}
                className="form-control"
                type={prompt.type === 'secret' ? 'password' : 'text'}
                value={answer}
                placeholder={prompt.type === 'secret' ? STRINGS.AccountsKey : prompt.placeholder}
                autoComplete="off"
                spellCheck={false}
                onChange={(e) => onAnswer(e.currentTarget.value)}
              />
            </div>
            <Button
              className={styles.continue}
              disabled={!answer.trim()}
              onClick={() => onSend(prompt, inputRef.current?.value ?? answer)}
            >
              {STRINGS.AccountsContinue}
            </Button>
          </div>
        </>
      )}
      {(isSending || (!prompt && !device)) && (
        <Island><Waiting text={progress ?? STRINGS.AccountsSigningIn} /></Island>
      )}
    </>
  );
}

function copyLink(url: string) {
  copyTextToClipboard(url);
  getActions().showNotification({ message: STRINGS.AccountsLinkCopied });
}

function Waiting({ text }: { text: string }) {
  return (
    <ListItem inactive leftElement={<Spinner className={styles.spinner} color="gray" />}>
      <span className={styles.muted} data-tau-login-waiting>{text}</span>
    </ListItem>
  );
}

const Memo = memo(LoginModal);

let root: HTMLDivElement | undefined;
let opened = 0;
const CLOSE_MS = 300;

/** Add Account on the server in `slot`; with an account, its provider's login again */
export function openLogin(slot: number, account?: ProviderAccount) {
  if (!root) {
    root = document.createElement('div');
    document.body.appendChild(root);
  }
  const container = root;
  const token = ++opened;
  const render = (isOpen: boolean) => TeactDOM.render(
    <Memo key={token} slot={slot} account={account} isOpen={isOpen} onClose={() => close()} />, container,
  );
  const close = () => {
    render(false);
    window.setTimeout(() => {
      if (opened === token) TeactDOM.render(undefined, container);
    }, CLOSE_MS);
  };
  render(true);
}
