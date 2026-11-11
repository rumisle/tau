// Times and lines as the iOS app writes them (ios/Tau/Chat/ChatMessageItem.swift)

/** As iOS's `formatElapsed`: 5s, 2m 05s */
export function formatElapsed(ms: number) {
  const seconds = Math.floor(ms / 1000);
  const pad = (n: number) => String(n).padStart(2, '0');
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${pad(seconds % 60)}s`;
  return `${Math.floor(seconds / 3600)}h ${pad(Math.floor((seconds % 3600) / 60))}m`;
}

export function clipLines(text: string, count: number, fromStart: boolean) {
  const lines = text.split('\n');
  if (lines.length <= count) return text;
  return fromStart ? `${lines.slice(0, count).join('\n')}\n…` : `…\n${lines.slice(-count).join('\n')}`;
}

/** As iOS's `formatDuration`: 4.2s, 38s, 2m 05s, 1h 03m */
export function formatDuration(ms: number) {
  const duration = ms / 1000;
  if (duration < 10) return `${duration.toFixed(1)}s`;
  const seconds = Math.round(duration);
  if (seconds < 60) return `${seconds}s`;
  const pad = (n: number) => String(n).padStart(2, '0');
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${pad(seconds % 60)}s`;
  return `${Math.floor(seconds / 3600)}h ${pad(Math.floor((seconds % 3600) / 60))}m`;
}
