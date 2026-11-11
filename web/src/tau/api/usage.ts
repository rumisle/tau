// Network Usage (iOS's NetworkUsage, after Telegram's): the bytes of the socket's frames to and from each server, since
// the statistics were reset. Kept in localStorage, written a moment after they change. A browser does not say which
// network it is on, so there is one count, not Wi-Fi's and mobile's.
const KEY = 'tau-network-usage';
const SAVE_MS = 1000;

export type Counters = { sent: number; received: number };
type Stored = { since: number; byOrigin: Record<string, Counters> };

let stored: Stored | undefined;
let saveTimer: number | undefined;
const listeners = new Set<() => void>();

function load(): Stored {
  if (stored) return stored;
  try {
    stored = JSON.parse(localStorage.getItem(KEY) ?? 'null') as Stored | undefined ?? undefined;
  } catch {
    stored = undefined;
  }
  if (!stored?.byOrigin) {
    stored = { since: Date.now(), byOrigin: {} };
    save();
  }
  return stored;
}

function save() {
  window.clearTimeout(saveTimer);
  saveTimer = undefined;
  if (stored) localStorage.setItem(KEY, JSON.stringify(stored));
}

export function addUsage(origin: string, sent: number, received: number) {
  const counters = load().byOrigin[origin] ??= { sent: 0, received: 0 };
  counters.sent += sent;
  counters.received += received;
  saveTimer ??= window.setTimeout(save, SAVE_MS);
  for (const listener of listeners) listener();
}

export function networkUsage(): Readonly<Stored> {
  return load();
}

export function resetNetworkUsage() {
  stored = { since: Date.now(), byOrigin: {} };
  save();
  for (const listener of listeners) listener();
}

export function onNetworkUsage(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** A socket's frames counted for its server, as UTF-8 */
export function countSocket(socket: WebSocket, origin: string) {
  const encoder = new TextEncoder();
  const sizeOf = (data: unknown) => (typeof data === 'string' ? encoder.encode(data).length
    : data instanceof Blob ? data.size : data instanceof ArrayBuffer ? data.byteLength : 0);
  const send = socket.send.bind(socket);
  socket.send = (data) => {
    addUsage(origin, sizeOf(data), 0);
    send(data);
  };
  socket.addEventListener('message', (event) => addUsage(origin, 0, sizeOf(event.data)));
}

// What the last second counted, as the page goes
window.addEventListener('pagehide', save);

/** Bytes as iOS's ByteCountFormatter says them (decimal, as Files does): Zero KB, 512 bytes, 12 KB, 1.4 MB */
export function formatBytes(bytes: number) {
  if (bytes === 0) return 'Zero KB';
  if (bytes < 1000) return bytes === 1 ? '1 byte' : `${bytes} bytes`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  // As ByteCountFormatter: whole kilobytes, one decimal above
  const shown = unit === 0 ? Math.round(value) : Math.round(value * 10) / 10;
  return `${shown} ${units[unit]}`;
}
