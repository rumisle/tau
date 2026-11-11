// The connect screen, in place of Web A's login (docs/web.md "The token"): shown when this origin's server wants a
// token the app does not have, or refused the one it had
import type { ChangeEvent, FormEvent } from 'react';
import {
  memo, useEffect, useState,
} from '../../lib/teact/teact';

import type { AuthStatus } from '../api/session';

import { getAuthStatus, onAuthStatus, submitToken } from '../api/session';
import { STRINGS } from '../strings';

import Button from '../../components/ui/Button';
import InputText from '../../components/ui/InputText';
import Loading from '../../components/ui/Loading';

import '../../components/auth/Auth.scss';

const Connect = () => {
  const [status, setStatus] = useState<AuthStatus>(getAuthStatus);
  const [token, setToken] = useState('');
  const [isLoading, setIsLoading] = useState(false);

  useEffect(() => onAuthStatus(setStatus), []);

  const handleChange = (e: ChangeEvent<HTMLInputElement>) => {
    setToken(e.currentTarget.value.trim());
  };

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!token) return;
    setIsLoading(true);
    await submitToken(token);
    setIsLoading(false);
  };

  const error = status === 'wrongToken' ? STRINGS.ConnectWrongToken
    : status === 'unreachable' ? STRINGS.ConnectUnreachable : undefined;
  const isAsking = status === 'needsToken' || status === 'wrongToken';

  return (
    <div id="auth-phone-number-form" className="custom-scroll" data-tau-connect={status}>
      <div className="auth-form">
        <h1>{STRINGS.ConnectTitle}</h1>
        {isAsking ? (
          <>
            <p className="note">{STRINGS.ConnectNote}</p>
            <form className="form" action="" onSubmit={handleSubmit}>
              <InputText
                id="tau-token"
                label={STRINGS.ConnectToken}
                value={token}
                error={error}
                autoComplete="off"
                onChange={handleChange}
              />
              <Button className="auth-button" type="submit" ripple isLoading={isLoading} disabled={!token}>
                {STRINGS.ConnectButton}
              </Button>
            </form>
          </>
        ) : (
          <>
            <p className="note">{error ?? STRINGS.ConnectConnecting}</p>
            <Loading />
          </>
        )}
      </div>
    </div>
  );
};

export default memo(Connect);
