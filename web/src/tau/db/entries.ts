// What this browser keeps of each server's chats (docs/chat-open.md, docs/network.md; iOS's EntryCache): the chat list
// with the version it is at, and each conversation's newest entries, in IndexedDB. Entries never change, so a cached
// one is always right; another database (`serverId`) drops everything. Conversation IDs are the server's own here, so
// a server that takes another slot keeps its cache. Every read and write goes through one queue, so a save, a preload
// and a reset never interleave, and a read sees what was queued before it.
import { createStore, del, entries, get, set } from 'idb-keyval';
import type { Dialog, Entry } from 'tau-client/protocol';

import { globalId, localId, mapIds, slotOf } from '../api/servers';

const STORE = createStore('tau-cache', 'chats');
/** The newest entries a conversation keeps */
export const KEPT_ENTRIES = 300;

export type CachedConversation = { entries: Entry[]; hasOlder: boolean };
type CachedDialogs = { dialogs: Dialog[]; version?: string };

let queue: Promise<unknown> = Promise.resolve();

function serial<T>(work: () => Promise<T>): Promise<T> {
  const result = queue.then(work, work);
  queue = result.catch(() => undefined);
  return result;
}

const serverKey = (origin: string) => `${origin} server`;
const dialogsKey = (origin: string) => `${origin} dialogs`;
const conversationKey = (origin: string, id: number) => `${origin} c${localId(id)}`;

// The server's IDs on disk, the slot's in the app
const toLocal = <T>(value: T) => mapIds(value as any, (id) => localId(id)) as T;
const toGlobal = <T>(value: T, slot: number) => mapIds(value as any, (id) => globalId(slot, id)) as T;

/** The database a server's cache is for */
export function readServerId(origin: string) {
  return serial(() => get<string>(serverKey(origin), STORE));
}

/** Another database: everything kept of the server goes, and the cache is for the new one */
export function resetCache(origin: string, serverId: string) {
  return serial(async () => {
    for (const [key] of await entries<string, unknown>(STORE)) {
      if (key.startsWith(`${origin} `)) await del(key, STORE);
    }
    await set(serverKey(origin), serverId, STORE);
  });
}

export async function readDialogs(origin: string, slot: number) {
  const cached = await serial(() => get<CachedDialogs>(dialogsKey(origin), STORE));
  return cached && { dialogs: toGlobal(cached.dialogs, slot), version: cached.version };
}

export function saveDialogs(origin: string, dialogs: Dialog[], version: string | undefined) {
  return serial(() => set(dialogsKey(origin), { dialogs: toLocal(dialogs), version }, STORE));
}

export async function readConversation(origin: string, id: number): Promise<CachedConversation | undefined> {
  const cached = await serial(() => get<CachedConversation>(conversationKey(origin, id), STORE));
  return cached && { entries: toGlobal(cached.entries, slotOf(id)), hasOlder: cached.hasOlder };
}

/** A conversation's newest entries; `hasOlder`: entries exist before them */
export function saveConversation(origin: string, id: number, kept: Entry[], hasOlder: boolean) {
  const newest = kept.slice(-KEPT_ENTRIES);
  return serial(() => set(conversationKey(origin, id), {
    entries: toLocal(newest), hasOlder: hasOlder || kept.length > newest.length,
  }, STORE));
}

/**
 * A preload's entries into a conversation's cache: after what it has, or in place of it (`replacing`: a gap between
 * the two, or nothing cached), `hasOlder` then the server's
 */
export function mergeConversation(origin: string, id: number, added: Entry[], replacing: boolean, hasOlder: boolean) {
  return serial(async () => {
    const key = conversationKey(origin, id);
    const cached = replacing ? undefined : await get<CachedConversation>(key, STORE);
    const byId = new Map<number, Entry>();
    for (const entry of cached?.entries ?? []) byId.set(entry.id, entry);
    for (const entry of toLocal(added)) byId.set(entry.id, entry);
    const sorted = [...byId.values()].sort((a, b) => a.id - b.id);
    const newest = sorted.slice(-KEPT_ENTRIES);
    await set(key, {
      entries: newest, hasOlder: (cached?.hasOlder ?? hasOlder) || sorted.length > newest.length,
    }, STORE);
  });
}

/** The newest entry a conversation's cache has */
export async function cachedNewest(origin: string, id: number) {
  const cached = await serial(() => get<CachedConversation>(conversationKey(origin, id), STORE));
  return cached?.entries.at(-1)?.id;
}

const isConversationKey = (key: string) => / c\d+$/.test(key);

/** What the chats' entries kept take, every server's */
export async function cacheBytes() {
  const all = await serial(() => entries<string, unknown>(STORE));
  return all.reduce((sum, [key, value]) => sum
    + (isConversationKey(key) ? new TextEncoder().encode(JSON.stringify(value)).length : 0), 0);
}

/** Clear Cache: the chats' entries go (they load again from their server when opened); the chat list stays */
export function clearCache() {
  return serial(async () => {
    for (const [key] of await entries<string, unknown>(STORE)) {
      if (isConversationKey(key)) await del(key, STORE);
    }
  });
}
