// A server's logins to model providers, their logins in progress and their plan usage (docs/accounts.md): the state
// `accounts.subscribe` gives and each `accounts` push replaces, and what Settings > Accounts says of it.

export type UsageWindow = { id: string; label: string; usedPercent: number; resetsAt?: number; seconds?: number };
export type PlanUsage = { at: number; windows: UsageWindow[]; credits?: string; error?: string };
export type ProviderAccount = {
  id: string;
  provider: string;
  providerName: string;
  type: 'oauth' | 'api_key';
  label?: string;
  email?: string;
  plan?: string;
  keyHint?: string;
  active: boolean;
  addedAt: number;
  problem?: string;
  usage?: PlanUsage;
};
export type AmbientLogin = { provider: string; providerName: string; source: string };
export type LoginEvent =
  | { type: 'info'; message: string; links?: { url: string; label?: string }[] }
  | { type: 'auth_url'; url: string; instructions?: string }
  | { type: 'device_code'; userCode: string; verificationUri: string; expiresInSeconds?: number }
  | { type: 'progress'; message: string };
export type LoginPrompt = { id: string; message: string; placeholder?: string } & (
  | { type: 'text' | 'secret' | 'manual_code' }
  | { type: 'select'; options: { id: string; label: string; description?: string }[] }
);
export type LoginSession = {
  id: string;
  provider: string;
  providerName: string;
  type: 'oauth' | 'api_key';
  startedAt: number;
  events: LoginEvent[];
  prompt?: LoginPrompt;
  done?: { accountId: string } | { error: string } | { cancelled: true };
};
export type ProviderEntry = {
  id: string;
  name: string;
  oauth?: { name: string; subscription: boolean };
  apiKey?: { name: string };
};
export type AccountsState = {
  accounts: ProviderAccount[];
  ambient: AmbientLogin[];
  logins: LoginSession[];
  providers: ProviderEntry[];
};

export type UsageLevel = 'normal' | 'ahead' | 'high' | 'out';

const DAY = 86_400;
const HOUR = 3_600;
const WEEK = 7 * DAY;
// Usage past an even pace by this many points, from a third of a week or half of a shorter window, is ahead of it
const AHEAD_MARGIN = 15;
const AHEAD_FLOOR_WEEK = 30;
const AHEAD_FLOOR = 50;
const HIGH = 90;

/** The provider as people know it: Claude for Anthropic's subscription sign-in, ChatGPT for OpenAI Codex's */
export function serviceName(provider: string, providerName: string, isSubscription: boolean) {
  if (provider === 'anthropic' && isSubscription) return 'Claude';
  if (provider === 'openai-codex') return 'ChatGPT';
  return providerName;
}

/** What the account is called: the user's name for it, else who it is, else its key or its kind */
export function accountTitle(account: ProviderAccount) {
  if (account.label) return account.label;
  if (account.email) return account.email;
  if (account.keyHint) return `Key ending ${account.keyHint}`;
  return account.type === 'api_key' ? 'API Key' : 'Account';
}

/** How much of the window's time has gone, 0 to 1: where an even pace would be now */
export function elapsedOf(window: UsageWindow, now: number) {
  if (window.resetsAt === undefined || !window.seconds) return undefined;
  return Math.min(1, Math.max(0, 1 - (window.resetsAt - now) / 1000 / window.seconds));
}

export function levelOf(window: UsageWindow, now: number): UsageLevel {
  if (window.usedPercent >= 100) return 'out';
  if (window.usedPercent >= HIGH) return 'high';
  const elapsed = elapsedOf(window, now);
  if (elapsed === undefined) return 'normal';
  const floor = (window.seconds ?? 0) > DAY ? AHEAD_FLOOR_WEEK : AHEAD_FLOOR;
  return window.usedPercent >= floor && window.usedPercent > elapsed * 100 + AHEAD_MARGIN ? 'ahead' : 'normal';
}

/** "42%", whole numbers, but never 100% before it is all used */
export function percentText(value: number) {
  return `${value >= 100 ? 100 : Math.min(99, Math.round(value))}%`;
}

/** "2h 14m", "3d 5h", "12m" */
export function durationText(ms: number) {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  const days = Math.floor(seconds / DAY);
  const hours = Math.floor((seconds % DAY) / HOUR);
  const minutes = Math.floor((seconds % HOUR) / 60);
  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  return `${Math.max(1, minutes)}m`;
}

/** "5-Hour Limit", "Weekly Limit", "Opus Weekly Limit" */
export function windowTitle(window: UsageWindow) {
  const seconds = window.seconds ?? 0;
  let span = window.label;
  if (Math.abs(seconds - WEEK) < HOUR) span = 'Weekly';
  else if (seconds > 0 && seconds % DAY === 0) span = `${seconds / DAY}-Day`;
  else if (seconds > 0) span = `${Math.round(seconds / HOUR)}-Hour`;
  if (['5h', 'week', 'primary', 'secondary'].includes(window.id)) return `${span} Limit`;
  return `${window.label.split(' ')[0]} ${span} Limit`;
}

/** Ahead of pace or near the end: what lasts until it resets, as the usage monitor says it */
export function paceText(window: UsageWindow, now: number) {
  const level = levelOf(window, now);
  if (level === 'out') return 'Used up';
  if (level === 'normal' || window.resetsAt === undefined || window.resetsAt <= now) return undefined;
  const left = Math.max(0, 100 - window.usedPercent);
  const remaining = (window.resetsAt - now) / 1000;
  if ((window.seconds ?? 0) > DAY && remaining > DAY) {
    return `Keep under ${Math.round(left / (remaining / DAY))}% a day to last until it resets`;
  }
  return `Keep under ${Math.round(left / Math.max(remaining / HOUR, 0.1))}% an hour to last until it resets`;
}

/** Accounts to see to: one to sign in to again, or the one in use out of a limit */
export function attentionCount(state: AccountsState) {
  return state.accounts.filter((account) => account.problem
    || (account.active && account.usage?.windows.some((window) => window.usedPercent >= 100))).length;
}

/** The latest page and code to show */
export function deviceCodeOf(login: LoginSession) {
  return login.events.findLast(
    (event): event is Extract<LoginEvent, { type: 'device_code' }> => event.type === 'device_code',
  );
}

export function authUrlOf(login: LoginSession) {
  return login.events.findLast(
    (event): event is Extract<LoginEvent, { type: 'auth_url' }> => event.type === 'auth_url',
  );
}

export function progressOf(login: LoginSession) {
  return login.events.findLast(
    (event): event is Extract<LoginEvent, { type: 'progress' }> => event.type === 'progress',
  )?.message;
}
