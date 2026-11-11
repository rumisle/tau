// tau's own strings, apart from Web A's language packs (which Web A fetches from Telegram's servers and tau does not
// answer, leaving its bundled fallback). English only for now.
export const STRINGS = {
  ConnectTitle: 'tau',
  ConnectNote: 'Paste the server\'s token. `tau setup` printed it, with a link that fills it in.',
  ConnectToken: 'Token',
  ConnectButton: 'Connect',
  ConnectWrongToken: 'The server did not take this token.',
  ConnectUnreachable: 'The server does not answer. It may be restarting.',
  ConnectConnecting: 'Connecting…',
  NewChat: 'New Chat',
} as const;
