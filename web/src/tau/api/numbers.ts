// Tokens and dollars as tau writes them, as iOS's formatTokens and formatCost: 950, 9.5k, 95k, 9.5M; $0, $0.0042, $4.20.

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
