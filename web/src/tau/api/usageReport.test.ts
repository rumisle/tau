import { describe, expect, it } from 'vitest';

import type { UsageReport, UsageTotals } from './usageReport';

import {
  changeText, mergeReports, niceCeiling, percentText, repliesText, shortModelName,
} from './usageReport';

const totals = (cost: number, output: number, replies = 1): UsageTotals => ({
  cost, input: 0, output, cacheRead: 0, cacheWrite: 0, replies,
});

function report(day: string, model: string, cost: number, conversationId: number): UsageReport {
  return {
    days: [{ day, models: { [model]: totals(cost, 100) } }],
    models: [{ model, ...totals(cost, 100) }],
    conversations: [{ conversationId, ...totals(cost, 100) }],
    total: { ...totals(cost, 100), conversations: 1 },
    previous: totals(cost / 2, 50),
  };
}

describe('mergeReports', () => {
  it('sums days by date and models by name, and sorts models and chats by cost', () => {
    const merged = mergeReports([
      report('2026-10-21', 'anthropic/opus', 1, 3),
      report('2026-10-20', 'anthropic/opus', 2, 2 ** 40 + 3),
      report('2026-10-21', 'openai/gpt', 5, 7),
    ])!;
    expect(merged.days.map((day) => day.day)).toEqual(['2026-10-20', '2026-10-21']);
    expect(merged.days[1].models['anthropic/opus'].cost).toBe(1);
    expect(merged.days[1].models['openai/gpt'].cost).toBe(5);
    expect(merged.models.map((each) => [each.model, each.cost])).toEqual([['openai/gpt', 5], ['anthropic/opus', 3]]);
    expect(merged.conversations.map((each) => each.conversationId)).toEqual([7, 2 ** 40 + 3, 3]);
    expect(merged.total).toMatchObject({ cost: 8, replies: 3, conversations: 3 });
    expect(merged.previous.cost).toBe(4);
  });

  it('leaves one report as it is, and none as none', () => {
    const one = report('2026-10-21', 'a/b', 1, 1);
    expect(mergeReports([one])).toBe(one);
    expect(mergeReports([])).toBeUndefined();
  });
});

describe('usage words', () => {
  it('names models as people read them, and what their count is of', () => {
    expect(shortModelName('anthropic/claude-opus-4')).toBe('claude-opus-4');
    expect(shortModelName('tau/cache-warming')).toBe('Cache Warming');
    expect(shortModelName('tau/compaction')).toBe('Compaction');
    expect(repliesText('a/b', 1)).toBe('1 answer');
    expect(repliesText('tau/cache-warming', 3)).toBe('3 refreshes');
    expect(repliesText('tau/compaction', 2)).toBe('2 summaries');
  });

  it('shares, changes and the chart\'s top', () => {
    expect([0, 0.004, 0.5].map(percentText)).toEqual(['0%', '<1%', '50%']);
    expect(changeText(12, 10)).toBe('+20%');
    expect(changeText(5, 10)).toBe('\u221250%');
    expect(changeText(5, 0)).toBeUndefined();
    expect([0, 0.7, 3, 45, 101].map(niceCeiling)).toEqual([0, 1, 5, 50, 200]);
  });
});
