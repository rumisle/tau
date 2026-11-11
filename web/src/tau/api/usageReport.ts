// What the models cost (docs/protocol.md `usage.report`, iOS's UsageReport): one server's report as the server sends
// it, several servers' merged, and how Settings > Usage words it.
import { formatCost, formatTokens } from './numbers';

export type UsageTotals = {
  cost: number; input: number; output: number; cacheRead: number; cacheWrite: number; replies: number;
};
export type UsageDay = { day: string; models: Record<string, UsageTotals> };
export type UsageReport = {
  days: UsageDay[];
  // `provider/modelId`, the costliest first
  models: (UsageTotals & { model: string })[];
  // The costliest conversations, by global ID
  conversations: (UsageTotals & { conversationId: number })[];
  total: UsageTotals & { conversations: number };
  // The span just before, for the change
  previous: UsageTotals;
};

/** What the server's ledger calls the prompt cache refreshes, and the summaries compaction asks for */
export const CACHE_WARMING_MODEL = 'tau/cache-warming';
export const COMPACTION_MODEL = 'tau/compaction';
const KEPT_CONVERSATIONS = 20;

export const emptyTotals = (): UsageTotals => ({
  cost: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, replies: 0,
});

export const tokensOf = (totals: UsageTotals) => totals.input + totals.output + totals.cacheRead + totals.cacheWrite;

export function addTotals<T extends UsageTotals>(into: T, more: UsageTotals) {
  into.cost += more.cost ?? 0;
  into.input += more.input ?? 0;
  into.output += more.output ?? 0;
  into.cacheRead += more.cacheRead ?? 0;
  into.cacheWrite += more.cacheWrite ?? 0;
  into.replies += more.replies ?? 0;
  return into;
}

export function dayTotal(day: UsageDay) {
  return Object.values(day.models).reduce((sum, totals) => addTotals(sum, totals), emptyTotals());
}

const byCostThenTokens = (a: UsageTotals, b: UsageTotals) => b.cost - a.cost || tokensOf(b) - tokensOf(a);

/** Several servers' reports as one: days by date, models and conversations summed and sorted again */
export function mergeReports(reports: UsageReport[]): UsageReport | undefined {
  if (reports.length <= 1) return reports[0];
  const days = new Map<string, Record<string, UsageTotals>>();
  const models = new Map<string, UsageTotals & { model: string }>();
  for (const report of reports) {
    for (const day of report.days) {
      const into = days.get(day.day) ?? {};
      days.set(day.day, into);
      for (const [model, totals] of Object.entries(day.models)) {
        into[model] = addTotals(into[model] ?? emptyTotals(), totals);
      }
    }
    for (const entry of report.models) {
      const into = models.get(entry.model) ?? { ...emptyTotals(), model: entry.model };
      models.set(entry.model, addTotals(into, entry));
    }
  }
  return {
    days: [...days.keys()].sort().map((day) => ({ day, models: days.get(day)! })),
    models: [...models.values()].sort(byCostThenTokens),
    conversations: reports.flatMap((report) => report.conversations).sort(byCostThenTokens)
      .slice(0, KEPT_CONVERSATIONS),
    total: reports.reduce((sum, report) => {
      addTotals(sum, report.total);
      sum.conversations += report.total.conversations ?? 0;
      return sum;
    }, { ...emptyTotals(), conversations: 0 }),
    previous: reports.reduce((sum, report) => addTotals(sum, report.previous), emptyTotals()),
  };
}

/** The part of `provider/modelId` people read: the model's name */
export function shortModelName(model: string) {
  if (model === CACHE_WARMING_MODEL) return 'Cache Warming';
  if (model === COMPACTION_MODEL) return 'Compaction';
  const slash = model.indexOf('/');
  return slash < 0 ? model : model.slice(slash + 1);
}

const plural = (count: number, one: string, many: string) => (count === 1 ? `1 ${one}` : `${count} ${many}`);

/** What a model's count is of: answers, cache refreshes, summaries */
export function repliesText(model: string, count: number) {
  if (model === CACHE_WARMING_MODEL) return plural(count, 'refresh', 'refreshes');
  if (model === COMPACTION_MODEL) return plural(count, 'summary', 'summaries');
  return plural(count, 'answer', 'answers');
}

export const answersText = (count: number) => plural(count, 'answer', 'answers');

export function percentText(share: number) {
  const percent = share * 100;
  if (percent > 0 && percent < 1) return '<1%';
  return `${Math.round(percent)}%`;
}

/** The change from the span before, as "+12%" or "−5%" (a minus sign), none when there was nothing before */
export function changeText(now: number, before: number) {
  if (!(before > 0)) return undefined;
  const delta = ((now - before) / before) * 100;
  return delta >= 0 ? `+${Math.round(delta)}%` : `\u2212${Math.round(-delta)}%`;
}

/** "Oct 21" from "2026-10-21" */
export function dayTitle(day: string) {
  const date = new Date(`${day}T00:00:00Z`);
  if (Number.isNaN(date.getTime())) return day;
  return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
}

/** The chart's top: the largest day rounded up to 1, 2 or 5 times a power of ten */
export function niceCeiling(value: number) {
  if (!(value > 0)) return 0;
  const power = 10 ** Math.floor(Math.log10(value));
  for (const step of [1, 2, 5, 10]) {
    if (step * power >= value) return step * power;
  }
  return 10 * power;
}

export type UsageMetric = 'cost' | 'tokens';

export const metricValue = (totals: UsageTotals, metric: UsageMetric) => (
  metric === 'cost' ? totals.cost : tokensOf(totals)
);

export const formatMetric = (value: number, metric: UsageMetric) => (
  metric === 'cost' ? formatCost(value) : formatTokens(Math.round(value))
);
