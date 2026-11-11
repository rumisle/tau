import type { Entry } from 'tau-client/protocol';
import { describe, expect, it } from 'vitest';

import { computeUsage, describeContext, formatCost, formatTokens, summarizeUsage } from './agent';

const answer = (id: number, usage?: object): Entry => ({
  id, kind: 'pi.assistant', conversationId: 1, model: [{ role: 'assistant', content: [], usage }],
});

describe('computeUsage', () => {
  const ledger = {
    models: {
      'dev/echo': { input: 1000, output: 200, cacheRead: 50, cacheWrite: 10, cost: { total: 0.012 } },
      'dev/parrot': { input: 500, output: 100, cacheRead: 0, cacheWrite: 0, cost: { total: 0.5 } },
    },
  };

  it('fills the context from the latest response since the newest compaction; spend from the ledger', () => {
    const entries = [
      answer(2, { input: 9000, output: 1000, cacheRead: 0, cacheWrite: 0 }),
      { id: 3, kind: 'pi.compaction', conversationId: 1 },
      answer(4, { input: 30000, output: 2000, cacheRead: 8000, cacheWrite: 1000 }),
      answer(5, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }),
    ];
    const usage = computeUsage(entries, undefined, ledger, 200_000, 0.1);
    expect(usage.contextTokens).toBe(41_000);
    expect(usage.models.map((each) => each.model)).toEqual(['dev/parrot', 'dev/echo']);
    expect(usage.total).toEqual({
      input: 1500, output: 300, cacheRead: 50, cacheWrite: 10, cost: 0.512,
    });
    expect(usage.cost).toBeCloseTo(0.612);
    expect(describeContext(usage)).toBe('21%, 41k of 200k');
    expect(summarizeUsage(usage)).toBe('21%, $0.61');
  });

  it('is empty before the first response of a context, and past a reset', () => {
    const usage = computeUsage([answer(2, { input: 10 }), { id: 3, kind: 'pi.reset', conversationId: 1 }], 1, {});
    expect(usage.contextTokens).toBeUndefined();
    expect(summarizeUsage(usage)).toBe('Empty, $0');
  });

  it('formats as iOS does', () => {
    expect([999, 1000, 1500, 41_000, 1_200_000].map(formatTokens)).toEqual(['999', '1k', '1.5k', '41k', '1.2M']);
    expect([0, 0.004, 0.512].map(formatCost)).toEqual(['$0', '$0.0040', '$0.51']);
  });
});
