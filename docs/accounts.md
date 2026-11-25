# Accounts

Status: built on the server (server/src/accounts.ts, server/src/plan-usage.ts) and in the app (ios/Tau/Accounts, the
usage widget in ios/TauWidgets/AccountsWidget.swift) and in the web client (Settings > Accounts, in Devices' place:
web/src/tau/components/AccountsSettings.tsx and LoginModal.tsx, where an account opens in a dialog and a right
click has its actions). A dev server
(`--dev-tps`) has a Dev Account provider whose sign-in completes on its own, with usage (server/src/dev-accounts.ts),
for the app's UI test `testAccounts`.

The server's logins to model providers: several accounts per provider, one of them in use, added and switched from
the app or the web, with each account's plan usage.

## What there was

The server read and wrote pi's `~/.pi/agent/auth.json` (server/src/credentials.ts): one credential per provider,
shared with the pi CLI on the same machine, added only by `pi /login` in a terminal. Two programs holding one OAuth
login refresh it in turn, and each refresh rotates the refresh token, so the one that refreshes second is logged out.

## Decisions

- **The server keeps its own accounts**, in `tau.accounts.json` beside the database (`<db>.accounts.json` for `--db`),
  owner-only. Not in the database: copying or backing up `tau.db` should not copy the logins. The server no longer
  reads pi's file; moving an existing server's logins over is done by hand, once.
- **Several accounts per provider; one is in use.** Signing in again to an account it has (the same provider and email) replaces its credential. Switching is by hand. It applies to the whole server: a run that is
  going uses the new account from its next request. A new account is put in use when it is added, as Telegram does.
- **Logins run on the server.** pi's login flows talk to the user through `prompt` and `notify` (pi-ai
  `AuthInteraction`); the server runs the flow and sends both to the clients, which answer prompts. A login outlives
  the client that started it (switching to the browser and back does not end it) and ends after 15 minutes.
- **Headless methods only.** A flow that asks to pick between `browser` and another method gets the other one from the
  server, without asking: the browser method waits for a redirect to the server's own localhost, which a phone cannot
  reach. That leaves the device code (Codex, Copilot, xAI, Kimi, Meta, Radius), the copied code (Claude), the
  pasted redirect URL (ChatGPT's OpenAI login, OpenRouter) and API keys.
- **Usage is asked for**, every 5 minutes for every subscription account that has a usage endpoint, and at once when
  the Accounts tab opens or is pulled. Each answer of an account in use also carries its 5-hour and weekly numbers in
  its response headers; they update the shown usage in between, without a request. An API key shows usage only where
  its provider tells a plan's: OpenCode Go (`GET opencode.ai/zen/go/v1/usage` with the key: `rolling`, `weekly` and
  `monthly`, each a `percent` and `resetsAt`) and Mistral (`GET api.mistral.ai/v1/billing/budget` with the key, as the
  Vibe CLI reads it: `vibe_budget`, the month's allowance a plan's key draws on, and `api_budget`, a pay-as-you-go
  key's, each a `usage_percentage` from 0 to 100 and `reset_at`) and OpenRouter (`GET openrouter.ai/api/v1/key`: the
  key's `budgets`, each `limit_usd`, `spend_usd`, `reset_interval` and `resets_at`; `GET /api/v1/credits`: the account's
  `total_credits` and `total_usage`, a window of its own with what is left, not extra usage), and a provider from
  outside tau whose file says how (`usage.apiKey`, docs/deploy.md), asked on the same schedule, its answer checked
  (`usageReport`): a malformed one, a throw or none in 30 s is the account's usage error. Other keys show none: tau
  does not split its cost counters by account.
- **A window without a limit**: `usedPercent` is optional. Without it a window is spend only, its `amount`
  ("$2,383.76 spent"), its `title` and its `resetsAt` when known: a pay-as-you-go key that reports what it has spent and
  no budget. The account's page shows its title and amount without a bar; the list, its label and the amount's first
  word, the figure ("Month $2,383.76"), where a limit's bar and percent are; the widget leaves it out (nothing to run
  out of), and an account with nothing else; the tab's badge and the levels (ahead, past 90%, used up) ignore it. A
  report needs one of the two, a percent or an amount. An app from before this shows such a window as 0%.
- **The app has an Accounts tab**, left of Chats: a server's accounts in one list. With several servers, the chat
  list's folder tabs (ChatListFolderTabsNode) name them under the title and a swipe goes between their lists, as
  between folders; with one, there are no tabs. Usage is what it is opened for; adding, switching and removing are
  there too.
- **Warnings that do not nag**: the tab's badge only when something needs doing (an account to sign in to again, the
  account in use out of a limit); a failed answer whose error is the provider's limit or login has a button to the
  Accounts tab, not a guess at which account to switch to; the widget for looking.
- **A home and lock screen widget** shows accounts' usage bars, fetched by the widget itself from the server.

## Usage sources (checked November 2026)

| Provider | Endpoint (OAuth token) | Headers on each answer |
|---|---|---|
| Claude (`anthropic`, OAuth) | `GET api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`: `limits` (since November 2026: `kind` `session`, `weekly_all` or `weekly_scoped` with a `scope` naming a model such as Fable, `group`, `percent`, `resets_at`), read first; else `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` (`utilization` 0 to 100, `resets_at`); `extra_usage` | `anthropic-ratelimit-unified-5h-utilization` (0 to 1), `-5h-reset` (Unix s), `-7d-utilization`, `-7d-reset`, `-status` |
| ChatGPT (`openai-codex`) | `GET chatgpt.com/backend-api/wham/usage` with `chatgpt-account-id`: `rate_limit.primary_window` / `secondary_window` (`used_percent`, `limit_window_seconds`, `reset_at`), `additional_rate_limits`, `credits` | `x-codex-primary-used-percent`, `-primary-window-minutes`, `-primary-reset-at`, the same for `secondary` |

Who the account is, asked at start, when the Accounts tab asks every usage (at most hourly an account) and when an
account's screen opens (at most every minute), so an upgrade shows: Claude's `GET api.anthropic.com/api/oauth/profile` (`account.email`, `organization.organization_type` such as `claude_pro`, and `rate_limit_tier`, which alone tells
Ultra, once Max 20x, from Max, once Max 5x: both are `claude_max`); Codex's access token is a JWT with `https://api.openai.com/profile.email` and
`https://api.openai.com/auth.chatgpt_plan_type`. Other providers' accounts are named by the user.

## Protocol

```ts
type Window = {
  id: string;
  label: string;                        // short, for the list and the widget: "5h", "Week", "Fable", "Key"
  title: string;                        // whole, for the account's page: "5-Hour Limit", "Fable Weekly Limit", "Credits"
  usedPercent?: number;                 // 0 to 100; none for spend without a limit, which its amount says
  resetsAt?: number /* ms */; seconds?: number;
  amount?: string;                      // in money, where the provider tells it: "$9.63 of $12.00 spent", "$4.77 of $103.00 left"
};
type Usage = { at: number; windows: Window[]; credits?: string /* extra usage beyond the plan */; error?: string };
type Account = {
  id: string; provider: string; providerName: string; type: "oauth" | "api_key";
  label?: string;                       // the user's name for it
  email?: string; plan?: string;        // as the provider says, when it does
  keyHint?: string;                     // an API key's last 4 characters
  active: boolean; addedAt: number;
  problem?: string;                     // its login no longer refreshes: sign in again
  usage?: Usage;
};
type Ambient = { provider: string; providerName: string; source: string };   // a key from the server's environment
type LoginState = {
  id: string; provider: string; providerName: string; startedAt: number;
  events: AuthEvent[];                  // pi's notify events, in order: info, auth_url, device_code, progress
  prompt?: { id: string } & AuthPrompt; // waiting for accounts.answer
  done?: { accountId: string } | { error: string } | { cancelled: true };
};
type AccountsState = { accounts: Account[]; ambient: Ambient[]; logins: LoginState[]; providers: ProviderInfo[] };
type ProviderInfo = { id: string; name: string; oauth?: { name: string; subscription: boolean }; apiKey?: { name: string } };
```

- `accounts.subscribe {}` -> `AccountsState`, then `{ event: "accounts", state: AccountsState }` on every change.
- `accounts.refresh { id? }` -> `{}`: ask one account's usage now (the app does when its screen opens), or every
  account's. An account is asked at most every 20 seconds, and not while its endpoint said 429 (its Retry-After, else
  10 minutes): the numbers had stand. `accounts.use` asks the account's usage too.
- `accounts.login { provider, type }` -> `{ login: id }`.
- `accounts.answer { login, prompt, value }` -> `{}`; `accounts.cancel { login }` -> `{}`.
- `accounts.use { id }`, `accounts.rename { id, label }` (empty: none), `accounts.remove { id }` -> `{}`.

Credentials never leave the server.

## Later

- A bar over the composer when the account in use passes 90% of a limit, with the way to the Accounts tab.
- A push when a limit the account in use ran out of resets.
- Copilot's and OpenRouter's usage.
- Picking the widget's account (an App Intent configuration); it shows the accounts in use for now.
- Switching on its own when an account runs out.
