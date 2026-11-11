// Where the outbox lasts (docs/sending.md rule 1): IndexedDB, one outbox per tab, each tab holding a Web Lock while it
// is open. A tab adopts the outboxes of tabs that are gone (closed, crashed, reloaded), so what they had not sent goes
// on; it never writes another live tab's, which sends its own over its own socket.
import { createStore, del, entries, set } from 'idb-keyval';
import type { OutboxState } from 'tau-client/outbox';
import { emptyOutboxState } from 'tau-client/outbox';

const STORE = createStore('tau-outbox', 'outboxes');
const LOCK = 'tau-outbox:';

export async function openOutboxState(origin: string) {
  const key = `${origin} ${crypto.randomUUID()}`;
  await new Promise<void>((held) => {
    void navigator.locks.request(`${LOCK}${key}`, () => {
      held();
      // Held until the tab goes
      return new Promise(() => undefined);
    });
  });
  const state = emptyOutboxState();
  // One tab adopts at a time, so two opening together do not both take a closed tab's messages
  await navigator.locks.request(`${LOCK}adopt ${origin}`, async () => {
    const { held = [] } = await navigator.locks.query();
    const alive = new Set(held.map((lock) => lock.name));
    const adopted: string[] = [];
    for (const [name, value] of await entries<string, OutboxState>(STORE)) {
      if (!name.startsWith(`${origin} `) || name === key || alive.has(`${LOCK}${name}`)) continue;
      merge(state, value);
      adopted.push(name);
    }
    await set(key, state, STORE);
    for (const name of adopted) await del(name, STORE);
  });
  return { state, persist: (snapshot: OutboxState) => set(key, snapshot, STORE) };
}

/** Another tab's outbox into this one: its operations after this one's, in their order */
function merge(state: OutboxState, other: OutboxState) {
  for (const item of [...other.items].sort((a, b) => a.seq - b.seq)) {
    state.items.push({ ...item, seq: state.nextSeq++ });
  }
  state.creates.push(...other.creates);
  Object.assign(state.withdrawOutcomes, other.withdrawOutcomes);
  Object.assign(state.created, other.created);
  state.serverId ??= other.serverId;
}

/** What the messages in the outboxes of every tab and server take on disk, as JSON (an empty outbox: none) */
export async function outboxBytes() {
  const all = await entries<string, OutboxState>(STORE);
  return all.reduce((sum, [, value]) => sum
    + (value.items.length ? new TextEncoder().encode(JSON.stringify(value)).length : 0), 0);
}
