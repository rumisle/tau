# tau

A coding agent you talk to from your iPhone. The agent runs on your own machine, built on
[pi-durable](https://github.com/earendil-works/pi/tree/main/packages/durable); the app is made from Telegram's iOS code,
so it feels like a messenger.

Durable writes every step of the agent's work to a database before showing it. Close the app, lose the network, or
restart the server mid-answer: the work goes on, or picks up where it stopped, and the app catches up when it is back.

## What it does

- **Chats with an agent on your machine.** It reads and edits files, runs commands, writes scripts that call its
  tools, and starts subagents that work in parallel, each in a chat of its own.
- **Answers as they are written**, with Markdown, code, tables and math, and each tool call as a card you can open.
- **Steer while it works**: a message sent mid-answer reaches the agent at its next step; or queue it for after.
- **Photos and files** both ways, and the share sheet: send anything from any app to a chat.
- **Notifications** when an answer is ready, shown as the chat's messages, with Reply. What they say is encrypted
  for your phone.
- **Live Activity** on the Lock Screen and in the Dynamic Island while the agent works.
- **Several servers** in one chat list, with folders, search across all chats, and Telegram's themes.
- **Skills**: folders in `~/.agents/skills` (or a project's `.agents/skills`) that the agent reads when a task
  matches.

## What you need

- A Linux machine with systemd for the server (a Mac works too, from the source: AGENTS.md), with Node 22.18 or later.
- A model: a Claude or ChatGPT subscription, or an API key (Anthropic, OpenAI, Google and others).
- A way for the phone to reach the machine. [Tailscale](https://tailscale.com) is the simple one: the app talks
  to servers on your tailnet (`*.ts.net`) and on your local network.
- The app on your iPhone: through TestFlight if you were invited, or built from `ios/` with Xcode (ios/README.md).

## Install the server

```bash
curl -fsSL https://github.com/rumisle/tau/releases/latest/download/install.sh | sh
```

It checks Node, downloads the latest release (about 2 MB), checks that it starts, and sets it up as a systemd user
service that starts at boot. At the end it prints the server's address and token.

The server runs as you and works on your files, so keep the token to yourself. Its options are in
`~/.config/tau/flags`; after a change, `systemctl --user restart tau-server`.

## Log in to a model

The server uses the same logins as the [pi](https://github.com/earendil-works/pi) command line:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi        # then /login, and choose your provider
```

API keys in your shell's environment work too (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …): the service starts through
a login shell, so it sees what your terminal sees. The default model for new chats is `--model` in
`~/.config/tau/flags`; each chat can pick its own in the app.

## Connect the app

In the app: Settings > Servers > Add, with the address and the token the installer printed (for example
`myserver.tail1234.ts.net:7878`). Add as many servers as you like; their chats share one list.

## Notifications

Apple delivers notifications only to an app's own key. So:

- **With the TestFlight app**, your server sends them through the relay that holds the app's key. Ask for a relay
  token, save it in `~/.config/tau/relay-token` (`chmod 600`), and add to `~/.config/tau/flags`:

  ```
  --push-relay https://<the relay's address> --push-relay-token-file ~/.config/tau/relay-token
  ```

- **With your own build**, use your own APNs key (`--apns-key ~/.config/tau/AuthKey_<id>.p8 --apns-team <team id>`),
  or deploy your own relay (relay/README.md).

The app makes a key of its own and gives it to your server, which encrypts what each notification says with it: the
relay and Apple carry only ciphertext. The Live Activity's text is not encrypted yet.

## Upgrade

```bash
tau upgrade     # the latest release: checked before the switch, and switched back if it does not stay up
tau rollback    # the version before
tau status
```

An agent can upgrade its own server from a chat: the switch happens outside the service, and the chat resumes on the
new version. Your chats and settings are kept apart from the code and are not touched.

## Working on tau

AGENTS.md: the layout, the docs on each part, running from the source, and the tests.

## License

GPL v3 or later (`LICENSE`). The app is built on Telegram-iOS's code, which Telegram licenses under the GPL v2 or later
(telegram.org/apps), and bundles Telegram Desktop's default wallpaper pattern, GPL v3 with an OpenSSL exception
(`ios/ThirdParty/tdesktop/NOTICE`); with Apache 2.0 parts (Texture's AsyncDisplayKit, lottie-ios), which the GPL v2 does
not take, the whole is GPL v3. The server uses pi (MIT), and the app SwiftMath (MIT). Each part copied in keeps its
notice: `ios/ThirdParty/Telegram/NOTICE`, and the LICENSE files of the modules that have one.
