// Several servers at once (docs/web.md "Several servers"; iOS's MultiStore): each server has a slot, and a
// conversation's ID carries its server's slot above bit 40, so the first server's IDs are its own. The IDs are made
// global on the socket, as its frames come and go, so everything above it (replicas, dialogs, the outbox, Web A's chat
// IDs) sees one space of conversations.
import { createStore, get, set } from 'idb-keyval';
import type { SocketLike } from 'tau-client/connection';

const SHIFT = 2 ** 40;

export type ServerConfig = {
  slot: number;
  origin: string;
};

/** The global ID of conversation `local` on server `slot` */
export function globalId(slot: number, local: number) {
  return slot === 0 ? local : slot * SHIFT + local;
}

export function slotOf(id: number) {
  return Math.floor(id / SHIFT);
}

export function localId(id: number) {
  return id % SHIFT;
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

/**
 * A frame's conversation IDs mapped by `map`: every number under a `conversationId` key (requests' params, entries,
 * submissions, a parent's or owner's, a subagent tool's details) and a conversation record's `id`
 */
export function mapIds(value: Json, map: (id: number) => number): Json {
  if (Array.isArray(value)) return value.map((each) => mapIds(each, map));
  if (!value || typeof value !== 'object') return value;
  const result: Record<string, Json> = {};
  for (const [key, each] of Object.entries(value)) {
    if (key === 'conversationId' && typeof each === 'number') {
      result[key] = map(each);
    } else if (key === 'conversation' && each && typeof each === 'object' && !Array.isArray(each)
      && typeof each.id === 'number') {
      result[key] = { ...(mapIds(each, map) as object), id: map(each.id) };
    } else {
      result[key] = mapIds(each, map);
    }
  }
  return result;
}

/** A WebSocket for server `slot`, its frames' conversation IDs global on this side */
export function mappedSocket(socket: WebSocket, slot: number): SocketLike {
  if (slot === 0) return socket;
  const toLocal = (id: number) => (slotOf(id) === slot ? localId(id) : id);
  const toGlobal = (id: number) => globalId(slot, id);
  return {
    send: (data: string) => socket.send(JSON.stringify(mapIds(JSON.parse(data) as Json, toLocal))),
    close: () => socket.close(),
    addEventListener: (type, listener) => {
      if (type !== 'message') {
        socket.addEventListener(type, listener);
        return;
      }
      socket.addEventListener('message', (event) => {
        listener({ data: JSON.stringify(mapIds(JSON.parse(String(event.data)) as Json, toGlobal)) });
      });
    },
  };
}

// The servers added beside the one that served the app, which is slot 0 and not stored
const SERVERS = createStore('tau-servers', 'servers');
const KEY = 'list';

export async function readServers(): Promise<ServerConfig[]> {
  return (await get<ServerConfig[]>(KEY, SERVERS)) ?? [];
}

export function writeServers(servers: ServerConfig[]) {
  return set(KEY, servers, SERVERS);
}

/** An address as typed, as an origin: `host:port` is https unless it is this machine */
export function originOf(address: string) {
  const trimmed = address.trim().replace(/\/+$/, '');
  if (!trimmed) return undefined;
  const withScheme = /^[a-z]+:\/\//i.test(trimmed) ? trimmed
    : /^(localhost|127\.0\.0\.1)(:|$)/.test(trimmed) ? `http://${trimmed}` : `https://${trimmed}`;
  try {
    const url = new URL(withScheme);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined;
    return url.origin;
  } catch {
    return undefined;
  }
}
