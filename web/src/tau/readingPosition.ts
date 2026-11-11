// The reading position in its desktop form (docs/reading-position.md; docs/web.md "Reading position"): what was seen,
// where a chat opens, turns and the return stack, in Web A's message list (`MessageList`, one hook and its opening
// scroll). Not iOS's sending part: a message sent here goes to the top, ChatGPT's way (src/tau/liveTail.ts).
//
// - Seen is on screen, the tab visible: the frontier (the newest message on screen and how far down it) moves as rows
//   are laid out in view, never back; the server reads the newest entry seen (session.ts `seenThrough`).
// - Where a chat opens: the view left (the message at the bottom and how much of it was above the bottom), at the end
//   too; then, if what follows it is unseen, down so the last lines seen sit near the top with a little above them.
// - Turns: Mod+Up goes to the start of the turn above (a message of the user's), pushing where it left from; the down
//   button and Mod+Down go back to the last such point, else to the end; Mod+Shift+Down to the end. A point whose row
//   is on screen again is dropped.
import type { ElementRef } from '../lib/teact/teact';
import { useEffect } from '../lib/teact/teact';
import { getActions, getGlobal } from '../global';

import type { Frontier, SavedView } from './reading';

import { selectCurrentMessageList } from '../global/selectors';
import animateScroll, { isAnimatingScroll } from '../util/animateScroll';
import { IS_MAC_OS } from '../util/browser/windowEnvironment';
import {
  getEffectiveMessageListBottomReserve, getMessageListTopReserve,
} from '../components/middle/helpers/messageListReserves';
import { entryIdOf } from './api/builders';
import { seenThrough } from './api/session';
import { advanceFrontier, frontierOf, savedView, saveView } from './reading';

// What stays above the last lines seen when a chat opens at what follows them: a line or two
const CONTEXT_PX = 48;
// The frontier counts as at the view's bottom this far below it (rounding, a reserve that changed)
const FRONTIER_SLACK_PX = 24;
// A turn's start lands this far below the top of the view
const TURN_MARGIN_PX = 8;
// After opening, new rows below a view the user has not moved are judged again for this long (the subscribe's)
const REJUDGE_MS = 4000;

type Row = { id: number; top: number; bottom: number; isOwn: boolean };

const stacks = new Map<string, SavedView[]>();
const lists = new Map<string, HTMLElement>();
// Lists whose opening scroll is done: the view they show is the user's to save
const laidOut = new WeakSet<HTMLElement>();
const openingFrontiers = new WeakMap<HTMLElement, Frontier | undefined>();

/**
 * The list's rows in content coordinates: messages by their entries' IDs, not local ones (on their way, the τ, a
 * streaming draft: fractions, as `message-12-0001`)
 */
function rowsOf(container: HTMLElement): Row[] {
  const base = container.getBoundingClientRect().top - container.scrollTop;
  const rows: Row[] = [];
  for (const element of container.querySelectorAll<HTMLElement>('.message-list-item[id^="message-"]')) {
    const match = /^message-(\d+)$/.exec(element.id);
    if (!match) continue;
    const rect = element.getBoundingClientRect();
    if (!rect.height) continue;
    rows.push({
      id: Number(match[1]),
      top: rect.top - base,
      bottom: rect.bottom - base,
      isOwn: element.classList.contains('own'),
    });
  }
  return rows.sort((a, b) => a.top - b.top);
}

/** The visible part of the list, in content coordinates: under the header, above the field */
function viewOf(container: HTMLElement) {
  const top = container.scrollTop + getMessageListTopReserve(container);
  const bottom = container.scrollTop + container.clientHeight - getEffectiveMessageListBottomReserve(container);
  return { top, bottom };
}

/** The chat shown: a list on its way out (another chat opening over it) measures nothing */
function isCurrent(chatId: string) {
  return selectCurrentMessageList(getGlobal())?.chatId === chatId;
}

function measureSeen(chatId: string, container: HTMLElement) {
  if (document.visibilityState !== 'visible' || !container.isConnected || !laidOut.has(container)) return;
  if (!isCurrent(chatId)) return;
  const view = viewOf(container);
  const rows = rowsOf(container);
  let seen: Frontier | undefined;
  for (const row of rows) {
    if (row.bottom <= view.top || row.top >= view.bottom) continue;
    if (!seen || row.id > seen.id) seen = { id: row.id, px: Math.min(view.bottom, row.bottom) - row.top };
  }
  if (seen) advanceFrontier(chatId, seen);
  const frontier = frontierOf(chatId);
  const newestRow = Math.max(0, ...rows.map((row) => row.id));
  if (frontier) seenThrough(chatId, entryIdOf(frontier.id), entryIdOf(newestRow));
  // The view: the row at the bottom, and how much of it is above the bottom
  const bottomRow = rows.filter((row) => row.top < view.bottom).at(-1);
  if (bottomRow) saveView(chatId, { id: bottomRow.id, offset: view.bottom - bottomRow.top });
  // Return points on screen again go
  const newest = rows.filter((row) => row.top < view.bottom && row.bottom > view.top).at(-1);
  const stack = stacks.get(chatId);
  if (newest && stack?.length && !isJumping(container)) {
    stacks.set(chatId, stack.filter((point) => point.id > newest.id));
  }
}

/** The scrollTop that puts a saved view back, if its row is laid out */
function scrollTopFor(container: HTMLElement, saved: SavedView) {
  const row = rowsOf(container).find((each) => each.id === saved.id);
  if (!row) return undefined;
  const visibleHeight = viewOf(container).bottom - container.scrollTop;
  return row.top + saved.offset - visibleHeight;
}

/** Down to what follows the view, if it is unseen: the last lines seen near the top, a little above them */
function unseenScrollTop(container: HTMLElement, scrollTop: number, frontier: Frontier | undefined) {
  if (!frontier) return undefined;
  const rows = rowsOf(container);
  const row = rows.find((each) => each.id === frontier.id);
  const last = rows.at(-1);
  if (!row || !last) return undefined;
  const seenTo = row.top + frontier.px;
  const topReserve = getMessageListTopReserve(container);
  const bottom = scrollTop + container.clientHeight - getEffectiveMessageListBottomReserve(container);
  // The frontier at the view's bottom (what follows the view is unseen), and something below it
  const hasUnseen = last.bottom > seenTo + 1;
  if (!hasUnseen || seenTo < bottom - CONTEXT_PX || seenTo > bottom + FRONTIER_SLACK_PX) return undefined;
  return Math.max(scrollTop, seenTo - CONTEXT_PX - topReserve);
}

/** Where the frontier's row is on screen, if it is laid out */
function frontierViewTop(frontier: Frontier | undefined, container: HTMLElement) {
  const element = frontier && container.querySelector<HTMLElement>(`#message-${frontier.id}`);
  return element ? element.getBoundingClientRect().top : undefined;
}

/**
 * Where a chat opens, on the list's first layout (MessageList's opening scroll): the view left, then down to what
 * follows it if unseen. Undefined: Web A's own (the end, for a chat never left here).
 */
export function tauOpeningScrollTop(chatId: string, container: HTMLElement) {
  // What was seen before it opened: what it shows now counts as seen, but not for judging where it opens
  openingFrontiers.set(container, frontierOf(chatId));
  // Measured from the next frame, once this scroll is applied
  requestAnimationFrame(() => {
    laidOut.add(container);
    measurers.get(container)?.();
  });
  const saved = savedView(chatId);
  if (!saved) return undefined;
  const restored = scrollTopFor(container, saved);
  if (restored === undefined) return undefined;
  const max = container.scrollHeight - container.clientHeight;
  const target = unseenScrollTop(container, restored, frontierOf(chatId)) ?? restored;
  return Math.max(0, Math.min(max, target));
}

const jumping = new WeakMap<HTMLElement, number>();
// Longer than Web A's longest scroll animation
const JUMP_MS = 1000;
// Web A's scroll animation starts a frame after it is asked for: a jump counts from then
const JUMP_START_MS = 100;

function isJumping(container: HTMLElement) {
  return isAnimatingScroll(container) || (jumping.get(container) ?? 0) > Date.now();
}

/**
 * Web A's own scroll animation (its bottom snap would hold a plain smooth scroll at the end): `element`'s top this far
 * below the top of the list
 */
function jumpTo(container: HTMLElement, element: HTMLElement, fromTop: number) {
  // The stack keeps still while a jump animates
  jumping.set(container, Date.now() + JUMP_START_MS);
  container.classList.remove('with-bottom-snap');
  animateScroll({ container, element, position: 'start', margin: fromTop });
  window.setTimeout(() => measurers.get(container)?.(), JUMP_MS + 50);
}

// Each list's measure, for after a jump or its opening scroll
const measurers = new WeakMap<HTMLElement, NoneToVoidFunction>();

const rowElement = (container: HTMLElement, id: number) => container.querySelector<HTMLElement>(`#message-${id}`);

/** Mod+Up: the start of the turn above, the view left pushed; at the first turn, the top */
export function previousTurn(chatId: string) {
  const container = lists.get(chatId);
  if (!container) return;
  // Points on screen go before this one is pushed
  if (!isAnimatingScroll(container)) {
    jumping.delete(container);
    measureSeen(chatId, container);
  }
  const view = viewOf(container);
  const rows = rowsOf(container);
  const target = rows.filter((row) => row.isOwn && row.top < view.top - 2).at(-1);
  const bottomRow = rows.filter((row) => row.top < view.bottom).at(-1);
  if (bottomRow) {
    const stack = stacks.get(chatId) ?? [];
    stack.push({ id: bottomRow.id, offset: view.bottom - bottomRow.top });
    stacks.set(chatId, stack);
  }
  const element = target && rowElement(container, target.id);
  if (element) {
    jumpTo(container, element, getMessageListTopReserve(container) + TURN_MARGIN_PX);
  } else {
    // The first turn: the top, where Web A loads what is above
    const first = rows[0] && rowElement(container, rows[0].id);
    if (first) jumpTo(container, first, getMessageListTopReserve(container));
  }
}

/** The down button and Mod+Down: back to the last return point; false when there is none (Web A goes to the end) */
export function tauScrollDown(chatId: string) {
  const container = lists.get(chatId);
  const point = stacks.get(chatId)?.pop();
  const element = point && container && rowElement(container, point.id);
  if (!element) return false;
  // Its row's top this far above the view's bottom
  const visibleBottom = container.clientHeight - getEffectiveMessageListBottomReserve(container);
  jumpTo(container, element, visibleBottom - point.offset);
  return true;
}

/** To the end directly: the return points are left behind */
export function clearReturnPoints(chatId: string) {
  stacks.delete(chatId);
}

const isMod = (e: KeyboardEvent) => (IS_MAC_OS ? e.metaKey : e.ctrlKey) && !e.altKey;

/** Typing in a field with text: its own Mod+Up and Down (to its start and end) */
function isEditingText(target: EventTarget | null) {
  const element = target as HTMLElement | null;
  if (!element || !(element.isContentEditable || element.tagName === 'INPUT' || element.tagName === 'TEXTAREA')) {
    return false;
  }
  const text = element.isContentEditable ? element.textContent : (element as HTMLInputElement).value;
  return Boolean(text?.trim());
}

/** To the end, as Web A's down button goes without a return point */
function toEnd(chatId: string) {
  clearReturnPoints(chatId);
  getActions().scrollMessageListToBottom();
}

/**
 * The reading position of the list on screen: what is seen and the view, measured as it scrolls, as its content
 * changes and as the tab comes back; turns by keyboard
 */
export function useTauReadingPosition(containerRef: ElementRef<HTMLDivElement>, chatId: string, isEnabled: boolean) {
  useEffect(() => {
    const container = containerRef.current;
    if (!isEnabled || !container) return undefined;
    lists.set(chatId, container);
    const openedAt = Date.now();
    let hasUserScrolled = false;
    let frame: number | undefined;
    let lastHeight = container.scrollHeight;
    let lastFrontierTop: number | undefined;
    const measure = () => {
      if (frame !== undefined) return;
      frame = requestAnimationFrame(() => {
        frame = undefined;
        // New rows below a view not moved since the chat opened (the subscribe's, after the browser's copy): what
        // follows the view is judged again. Only when the frontier's row kept its place on screen: one that moved had
        // rows put above it, which Web A is still anchoring
        const opening = openingFrontiers.get(container);
        const frontierTop = frontierViewTop(opening, container);
        const isSteady = frontierTop !== undefined && lastFrontierTop !== undefined
          && Math.abs(frontierTop - lastFrontierTop) <= 1;
        if (!hasUserScrolled && isSteady && Date.now() - openedAt < REJUDGE_MS && container.scrollHeight > lastHeight) {
          const target = unseenScrollTop(container, container.scrollTop, opening);
          if (target !== undefined && target > container.scrollTop + 1) container.scrollTop = target;
        }
        lastHeight = container.scrollHeight;
        lastFrontierTop = frontierViewTop(opening, container);
        measureSeen(chatId, container);
      });
    };
    measurers.set(container, measure);
    const markUser = () => {
      hasUserScrolled = true;
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (!isMod(e) || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') || isEditingText(e.target)) return;
      e.preventDefault();
      hasUserScrolled = true;
      if (e.key === 'ArrowUp') {
        previousTurn(chatId);
      } else if (e.shiftKey || !tauScrollDown(chatId)) {
        toEnd(chatId);
      }
    };
    // The list's size, and its rows as they come, go and change
    const resizes = new ResizeObserver(measure);
    resizes.observe(container);
    const children = new MutationObserver(measure);
    children.observe(container, { childList: true, subtree: true, characterData: true });
    container.addEventListener('scroll', measure, { passive: true });
    for (const event of ['wheel', 'pointerdown', 'touchstart']) container.addEventListener(event, markUser);
    document.addEventListener('visibilitychange', measure);
    document.addEventListener('keydown', onKeyDown);
    measure();
    return () => {
      if (frame !== undefined) cancelAnimationFrame(frame);
      resizes.disconnect();
      children.disconnect();
      container.removeEventListener('scroll', measure);
      for (const event of ['wheel', 'pointerdown', 'touchstart']) container.removeEventListener(event, markUser);
      document.removeEventListener('visibilitychange', measure);
      document.removeEventListener('keydown', onKeyDown);
      if (lists.get(chatId) === container) lists.delete(chatId);
    };
  }, [containerRef, chatId, isEnabled]);
}
