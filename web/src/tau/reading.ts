// The reading position's state (docs/reading-position.md), per chat, in this browser: the seen frontier (the newest
// message seen and how far down it, which only moves forward) and the view left (the message at the bottom of the
// screen and how much of it was above the bottom), at the end too. Kept in localStorage per server origin.
import { serverOrigin } from './auth';

export type SavedView = { id: number; offset: number };
export type Frontier = { id: number; px: number };
type ChatReading = { view?: SavedView; frontier?: Frontier };

const keyOf = () => `tau-reading:${serverOrigin()}`;
const SAVE_DELAY_MS = 500;
let state: Record<string, ChatReading> | undefined;
let saveTimer: number | undefined;

function read() {
  if (state) return state;
  try {
    state = JSON.parse(localStorage.getItem(keyOf()) ?? '{}') as Record<string, ChatReading>;
  } catch {
    state = {};
  }
  return state;
}

function save() {
  if (saveTimer !== undefined) return;
  saveTimer = window.setTimeout(() => {
    saveTimer = undefined;
    localStorage.setItem(keyOf(), JSON.stringify(read()));
  }, SAVE_DELAY_MS);
}

/** Written at once: the page may be going */
export function flushReading() {
  if (saveTimer === undefined) return;
  window.clearTimeout(saveTimer);
  saveTimer = undefined;
  localStorage.setItem(keyOf(), JSON.stringify(read()));
}

window.addEventListener('pagehide', flushReading);

export function savedView(chatId: string) {
  return read()[chatId]?.view;
}

export function saveView(chatId: string, view: SavedView) {
  const chat = (read()[chatId] ??= {});
  if (chat.view?.id === view.id && Math.abs(chat.view.offset - view.offset) < 1) return;
  chat.view = view;
  save();
}

export function frontierOf(chatId: string) {
  return read()[chatId]?.frontier;
}

/** The frontier moved forward: true when it did */
export function advanceFrontier(chatId: string, seen: Frontier) {
  const chat = (read()[chatId] ??= {});
  const was = chat.frontier;
  if (was && (seen.id < was.id || (seen.id === was.id && seen.px <= was.px))) return false;
  chat.frontier = seen;
  save();
  return true;
}
