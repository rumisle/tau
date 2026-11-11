// A chat's agent as the chat menu shows and changes it: its model and thinking level, the server's models, and the
// requests that change them, in order with the chat's messages (docs/sending.md rule 2). As iOS's ServerStore.agent:
// a choice shows at once and stands until the conversation's `pi.agent` doc agrees.
import type { Entry, JsonObject } from 'tau-client/protocol';

import {
  currentClient, dialogs, docsOf, draftState, entriesOf, getOutbox, isDraftChat, onConversationChange, setDraftAgent,
} from './session';

export type ModelRef = { provider: string; modelId: string };
export type ModelInfo = {
  provider: string;
  id: string;
  name: string;
  reasoning?: boolean;
  thinkingLevels: string[];
  contextWindow?: number;
};
export type Agent = { model?: ModelRef; thinkingLevel: string };

const FALLBACK_LEVELS = ['off', 'low', 'medium', 'high'];
// How long a confirmed choice waits for the doc to say the same before the doc is believed again
const CONFIRMED_TTL_MS = 5000;

let models: ModelInfo[] | undefined;
let modelsRequest: Promise<ModelInfo[] | undefined> | undefined;
const overrides = new Map<number, { agent: Agent; token: number; confirmed: boolean }>();
let nextToken = 0;
const listeners = new Set<() => void>();

onConversationChange(() => emit());

export function onAgentChange(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function emit() {
  for (const listener of listeners) listener();
}

/** The models the server has credentials for, asked once per page */
export function loadModels() {
  if (models) return Promise.resolve(models);
  const client = currentClient();
  if (!client) return Promise.resolve(undefined);
  modelsRequest ??= client.request<{ models: ModelInfo[] }>('models.list')
    .then((result) => {
      models = result.models;
      emit();
      return models;
    })
    .catch(() => undefined)
    .finally(() => {
      modelsRequest = undefined;
    });
  return modelsRequest;
}

export function cachedModels() {
  return models;
}

export function modelInfo(model?: ModelRef) {
  return model && models?.find((each) => each.provider === model.provider && each.id === model.modelId);
}

export function modelName(model?: ModelRef) {
  if (!model) return 'Default';
  return modelInfo(model)?.name ?? model.modelId;
}

// Models picked lately, newest first, on this device (iOS keeps its recent models so)
const RECENT_KEY = 'tau-recent-models';
const RECENT_COUNT = 5;

export function recentModels(): string[] {
  try {
    return JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]') as string[];
  } catch {
    return [];
  }
}

export function rememberModel(key: string) {
  const next = [key, ...recentModels().filter((each) => each !== key)].slice(0, RECENT_COUNT);
  localStorage.setItem(RECENT_KEY, JSON.stringify(next));
}

/** The levels the chat's model has, `off` first (pi-ai's getSupportedThinkingLevels) */
export function thinkingLevels(agent: Agent) {
  return modelInfo(agent.model)?.thinkingLevels ?? FALLBACK_LEVELS;
}

export function thinkingTitle(level: string) {
  return level.charAt(0).toUpperCase() + level.slice(1);
}

function defaults(): Agent {
  const hello = currentClient()?.hello as { defaultModel?: ModelRef; defaultThinkingLevel?: string } | undefined;
  return { model: hello?.defaultModel, thinkingLevel: hello?.defaultThinkingLevel ?? 'off' };
}

function fromPatch(base: Agent, patch?: JsonObject): Agent {
  if (!patch) return base;
  return {
    model: (patch.model as ModelRef | undefined) ?? base.model,
    // null clears it back to the server's default, which the menu shows as Off
    // eslint-disable-next-line no-null/no-null
    thinkingLevel: patch.thinkingLevel === null ? 'off' : (patch.thinkingLevel as string | undefined)
      ?? base.thinkingLevel,
  };
}

/** The chat's agent: a choice just made, else its `pi.agent` doc, else the chat list's model, else the defaults */
export function agentOf(chatId: string): Agent {
  if (isDraftChat(chatId)) return fromPatch(defaults(), draftState().agent);
  const conversationId = Number(chatId);
  const doc = docsOf(conversationId)?.['pi.agent'] as { model?: ModelRef; thinkingLevel?: string } | undefined;
  const stored = doc?.model ? { model: doc.model, thinkingLevel: doc.thinkingLevel ?? 'off' } : undefined;
  const override = overrides.get(conversationId);
  if (override) {
    if (override.confirmed && stored && sameAgent(stored, override.agent)) overrides.delete(conversationId);
    else return override.agent;
  }
  if (stored) return stored;
  const dialog = dialogs.dialogs.get(conversationId);
  return { ...defaults(), ...(dialog?.agent.model && { model: dialog.agent.model }) };
}

function sameAgent(a: Agent, b: Agent) {
  return a.model?.provider === b.model?.provider && a.model?.modelId === b.model?.modelId
    && a.thinkingLevel === b.thinkingLevel;
}

/** Picks a model or thinking level: shown at once, sent after what the chat has asked before */
export function configureAgent(chatId: string, change: { model?: ModelRef; thinkingLevel?: string }) {
  const patch: JsonObject = {};
  if (change.model) patch.model = change.model;
  // The protocol clears a field with null (AgentPatch)
  // eslint-disable-next-line no-null/no-null
  if (change.thinkingLevel) patch.thinkingLevel = change.thinkingLevel === 'off' ? null : change.thinkingLevel;
  const next = fromPatch(agentOf(chatId), patch);
  if (change.model && !change.thinkingLevel) {
    // Fitted to the model, as the server fits it (pi's clampThinkingLevel), so the menu does not show a level it lacks
    const levels = thinkingLevels(next);
    if (!levels.includes(next.thinkingLevel)) next.thinkingLevel = levels.at(-1) ?? 'off';
  }
  const outbox = getOutbox();
  if (isDraftChat(chatId)) {
    // Not created yet: the create asks for it, or, already on its way, a configure follows it
    setDraftAgent(patch);
    const { requestId } = draftState();
    if (requestId && outbox.create(requestId) && !outbox.updateCreate(requestId, { agent: draftState().agent })) {
      void outbox.request('conversation.configure', { createRequestId: requestId }, { agent: patch }).catch(() => {});
    }
    return;
  }
  const conversationId = Number(chatId);
  const token = ++nextToken;
  overrides.set(conversationId, { agent: next, token, confirmed: false });
  emit();
  outbox.request('conversation.configure', { conversationId }, { agent: patch })
    .then(() => {
      const override = overrides.get(conversationId);
      if (override?.token !== token) return;
      // The doc's change may come after the answer; until then the choice stands
      override.confirmed = true;
      window.setTimeout(() => {
        if (overrides.get(conversationId)?.token === token) {
          overrides.delete(conversationId);
          emit();
        }
      }, CONFIRMED_TTL_MS);
    })
    .catch(() => {
      if (overrides.get(conversationId)?.token !== token) return;
      overrides.delete(conversationId);
      emit();
    });
}

/** Compact Context: not repeated after a lost connection, as two in a row would summarize the summary */
export function compact(chatId: string) {
  if (isDraftChat(chatId)) return Promise.resolve();
  return getOutbox().request('conversation.compact', { conversationId: Number(chatId) }, {}, { repeatable: false });
}

export type TokenUsage = { input: number; output: number; cacheRead: number; cacheWrite: number; cost: number };
export type Usage = {
  // Tokens the model saw in the latest response of the current context, as pi's footer shows
  contextTokens?: number;
  contextWindow?: number;
  // Spend by `provider/modelId`, most expensive first; the whole spend, refreshes that kept the cache warm included
  models: { model: string; usage: TokenUsage }[];
  total: TokenUsage;
  cost: number;
};

function tokenUsage(object: any): TokenUsage {
  return {
    input: object?.input ?? 0,
    output: object?.output ?? 0,
    cacheRead: object?.cacheRead ?? 0,
    cacheWrite: object?.cacheWrite ?? 0,
    cost: object?.cost?.total ?? 0,
  };
}

/**
 * A conversation's usage (ios/Tau/Server/ServerStore.swift `usage`): `pi.usage`'s ledger by model, and the context's
 * fill from the latest response since the newest reset or compaction (an aborted or failed one reports nothing)
 */
export function computeUsage(
  entries: Entry[], head: number | undefined, usageDoc: any, contextWindow?: number, cacheCost = 0,
): Usage {
  const ledger = (usageDoc?.models ?? {}) as Record<string, unknown>;
  const byModel = Object.entries(ledger).map(([model, value]) => ({ model, usage: tokenUsage(value) }))
    .sort((a, b) => b.usage.cost - a.usage.cost);
  const total = byModel.reduce((sum, { usage }) => ({
    input: sum.input + usage.input,
    output: sum.output + usage.output,
    cacheRead: sum.cacheRead + usage.cacheRead,
    cacheWrite: sum.cacheWrite + usage.cacheWrite,
    cost: sum.cost + usage.cost,
  }), tokenUsage(undefined));
  let contextTokens: number | undefined;
  for (const entry of [...entries].sort((a, b) => b.id - a.id)) {
    if (head !== undefined && entry.id <= head) break;
    if (entry.kind === 'pi.reset' || entry.kind === 'pi.compaction') break;
    const usage = entry.kind === 'pi.assistant' ? (entry.model as any[] | undefined)?.[0]?.usage : undefined;
    if (!usage) continue;
    const value = tokenUsage(usage);
    const sum = value.input + value.output + value.cacheRead + value.cacheWrite;
    if (sum > 0) {
      contextTokens = sum;
      break;
    }
  }
  return {
    contextTokens, contextWindow, models: byModel, total, cost: total.cost + cacheCost,
  };
}

export function usageOf(chatId: string): Usage {
  const agent = agentOf(chatId);
  const window = modelInfo(agent.model)?.contextWindow;
  if (isDraftChat(chatId)) return computeUsage([], undefined, undefined, window);
  const conversationId = Number(chatId);
  const { entries, head } = entriesOf(conversationId);
  const cacheCost = (dialogs.dialogs.get(conversationId)?.cache?.cost as number | undefined) ?? 0;
  return computeUsage(entries, head, docsOf(conversationId)?.['pi.usage'], window, cacheCost);
}

export function formatTokens(count: number) {
  if (count < 1_000) return String(count);
  if (count < 10_000) return `${(count / 1_000).toFixed(1).replace(/\.0$/, '')}k`;
  if (count < 1_000_000) return `${Math.round(count / 1_000)}k`;
  return `${(count / 1_000_000).toFixed(1).replace(/\.0$/, '')}M`;
}

export function formatCost(cost: number) {
  if (cost === 0) return '$0';
  return cost < 0.01 ? `$${cost.toFixed(4)}` : `$${cost.toFixed(2)}`;
}

export function contextPercent(usage: Usage) {
  if (usage.contextTokens === undefined || !usage.contextWindow) return undefined;
  return Math.round((usage.contextTokens / usage.contextWindow) * 100);
}

/** "21%, 41k of 200k", or what is known of it */
export function describeContext(usage: Usage) {
  if (usage.contextTokens === undefined) return 'Empty';
  const percent = contextPercent(usage);
  if (percent === undefined) return `${formatTokens(usage.contextTokens)} tokens`;
  return `${percent}%, ${formatTokens(usage.contextTokens)} of ${formatTokens(usage.contextWindow!)}`;
}

/** The Usage row's second line: how full the context is, and the spend */
export function summarizeUsage(usage: Usage) {
  const percent = contextPercent(usage);
  const context = percent !== undefined ? `${percent}%`
    : usage.contextTokens === undefined ? 'Empty' : `${formatTokens(usage.contextTokens)} tokens`;
  return `${context}, ${formatCost(usage.cost)}`;
}
