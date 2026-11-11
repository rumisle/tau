// The server's address and token (docs/web.md "Serving and connecting"). The app talks to the server that served it;
// the token comes from the connect screen or a `#token=` link, is kept in IndexedDB per server, and goes on the
// WebSocket in `Sec-WebSocket-Protocol`, never in a URL.
import { createStore, del, get, set } from 'idb-keyval';

const TOKENS = createStore('tau', 'tokens');
const PROTOCOL = 'tau.v1';
const TOKEN_PROTOCOL = 'tau.token.';
// Where the socket connects: any path upgrades on the server; the dev server proxies this one to it
const SOCKET_PATH = '/socket';

export function serverOrigin() {
  return window.location.origin;
}

export function socketUrl() {
  return socketUrlOf(window.location.origin);
}

/** A server's socket: `wss:` for an `https:` origin */
export function socketUrlOf(origin: string) {
  const { protocol, host } = new URL(origin);
  return `${protocol === 'https:' ? 'wss:' : 'ws:'}//${host}${SOCKET_PATH}`;
}

/** `tau.v1`, and the token as base64url (a subprotocol takes only an HTTP token's characters) */
export function socketProtocols(token?: string) {
  return token === undefined ? [PROTOCOL] : [PROTOCOL, `${TOKEN_PROTOCOL}${encodeBase64Url(token)}`];
}

export function readToken(origin: string): Promise<string | undefined> {
  return get<string>(origin, TOKENS);
}

export function saveToken(origin: string, token: string) {
  return set(origin, token, TOKENS);
}

export function forgetToken(origin: string) {
  return del(origin, TOKENS);
}

/**
 * A `#token=` link's token (`tau setup` prints one): kept for this server and taken out of the address bar. The
 * fragment never reaches the server or its logs.
 */
export function takeLinkToken() {
  const match = /^#token=([^&]+)$/.exec(window.location.hash);
  if (!match) return undefined;
  const token = decodeURIComponent(match[1]);
  window.history.replaceState(undefined, '', window.location.pathname + window.location.search);
  return saveToken(serverOrigin(), token);
}

/** Whether the server takes the token: `GET /auth`, 204 or 401 */
export async function probe(origin: string, token?: string): Promise<'ok' | 'token' | 'unreachable'> {
  try {
    const response = await fetch(`${origin}/auth`, {
      headers: token === undefined ? {} : { authorization: `Bearer ${token}` },
      cache: 'no-store',
    });
    if (response.status === 401) return 'token';
    return response.ok ? 'ok' : 'unreachable';
  } catch {
    return 'unreachable';
  }
}

function encodeBase64Url(text: string) {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
