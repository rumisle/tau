# tau

A coding agent built on [pi-durable](https://github.com/earendil-works/pi/tree/main/packages/durable). The iOS client
is built from Telegram's components.

## Requirements

- Linux with systemd, Node 22.18+
- A model login or API key
- A route from the phone to the server: plain `ws://` over [Tailscale](https://tailscale.com) (`*.ts.net`) or the
  local network, or `wss://` anywhere behind a TLS reverse proxy

## Server

```bash
curl -fsSL https://github.com/rumisle/tau/releases/latest/download/install.sh | sh
```

Installs a systemd user service and prints the address and token. Options: `~/.config/tau/flags`.

Models use [pi](https://github.com/earendil-works/pi)'s logins (`pi`, then `/login`) or provider API keys in the
shell environment.

```bash
tau upgrade
tau rollback
tau status
```

## App

TestFlight by invitation, or build `ios/` (ios/README.md). Add the server in Settings > Servers.

## Notifications

TestFlight build: ask for a relay token, then add to `~/.config/tau/flags`:

```
--push-relay <url> --push-relay-token-file ~/.config/tau/relay-token
```

Own build: `--apns-key <AuthKey_ID.p8> --apns-team <team id>`, or your own relay (relay/README.md).

## Development

AGENTS.md.

## License

GPL v3 or later. Built on Telegram-iOS (GPL v2 or later) and Telegram Desktop's wallpaper (GPL v3); third-party
notices are kept with each copied part (`ios/ThirdParty`).
