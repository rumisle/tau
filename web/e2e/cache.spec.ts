// The entry cache (59f32bf, docs/chat-open.md, docs/network.md): the chat list and each opened chat's newest entries
// kept in IndexedDB, so a page loaded while the server is away starts with them, connecting; back, the list asks only
// for what changed since its version, and a chat for the entries after its newest; older pages come as the chat
// scrolls up to them.
import type { Page, WebSocketRoute } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';

/** The server reachable or not, the page served all the same: `/auth` and the socket go through routes */
async function awayRoutes(app: Page) {
  const state = { isAway: false, sent: [] as string[], current: undefined as WebSocketRoute | undefined };
  await app.route('**/auth', (route) => (state.isAway ? route.abort() : route.continue()));
  await app.routeWebSocket(/\/socket$/, (socket) => {
    if (state.isAway) {
      void socket.close();
      return;
    }
    state.current = socket;
    const server = socket.connectToServer();
    socket.onMessage((message) => {
      state.sent.push(String(message));
      server.send(message);
    });
  });
  return state;
}

/** What this browser keeps of the chats, by key */
function cachedKeys(app: Page) {
  return app.evaluate(() => new Promise<string[]>((done) => {
    const request = indexedDB.open('tau-cache');
    request.onsuccess = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains('chats')) {
        done([]);
        return;
      }
      const keys = db.transaction('chats').objectStore('chats').getAllKeys();
      keys.onsuccess = () => done(keys.result.map(String));
    };
  }));
}

const openChat = (app: Page, title: string) => app.locator('.chat-list .fullName')
  .getByText(title, { exact: true }).click();

test('a page loaded while the server is away starts with the chats kept, and an opened one opens at once', async ({ app, api }) => {
  const routes = await awayRoutes(app);
  const id = await api.chat('Kept chat', ['remember the walrus']);
  await api.chat('Never opened', ['nothing here']);
  await app.reload();
  await openChat(app, 'Kept chat');
  const answer = app.locator('[data-tau-row="assistant"]').filter({ hasText: 'You said: remember the walrus' });
  await expect(answer).toBeVisible();
  // Kept a moment after it changed: the list and the chat
  await expect.poll(() => cachedKeys(app)).toEqual(expect.arrayContaining([
    expect.stringMatching(/ dialogs$/), expect.stringMatching(new RegExp(` c${id}$`)),
  ]));

  routes.isAway = true;
  await routes.current!.close();
  await app.reload();
  const header = app.locator('.MiddleHeader');
  await expect(app.locator('.chat-list .fullName').getByText('Never opened', { exact: true })).toBeVisible();
  await openChat(app, 'Kept chat');
  await expect(answer).toBeVisible();
  await expect(header).toContainText('connecting');
  await expect(app.locator(field)).toBeVisible();

  // Back: the list asks for what changed since its version, the chat for what came after its newest entry
  await api.send(id, 'while you were away');
  routes.sent.length = 0;
  routes.isAway = false;
  await expect(app.locator('[data-tau-row="assistant"]').filter({ hasText: 'You said: while you were away' }))
    .toBeVisible({ timeout: 15_000 });
  await expect(header).not.toContainText('connecting');
  const requests = routes.sent.map((frame) => JSON.parse(frame) as { method: string; params: any });
  expect(requests.find((each) => each.method === 'dialogs.subscribe')?.params.since).toBeTruthy();
  expect(requests.find((each) => each.method === 'conversation.subscribe'
    && each.params.conversationId === id)?.params.after).toBeGreaterThan(0);
});

test('a long chat opens with its newest page; scrolled up, the older ones come', async ({ app, api }) => {
  // Each `$` message is several entries (the message, the call, its result, the answer): past a page of 100
  const messages = ['$ echo the very first', ...Array.from({ length: 33 }, (_, i) => `$ echo line ${i + 2}`)];
  const routes = await awayRoutes(app);
  await api.chat('Long chat', messages);
  await app.reload();
  await openChat(app, 'Long chat');
  await expect(app.locator('.Message.own').filter({ hasText: '$ echo line 34' })).toBeVisible();
  // The first message is not in the newest page; scrolling to the top brings it
  const first = app.locator('.Message.own').filter({ hasText: 'the very first' });
  await expect(first).toHaveCount(0);
  const list = app.locator('.MessageList').last();
  await expect(async () => {
    await list.evaluate((element) => element.scrollTo({ top: 0 }));
    await expect(first).toHaveCount(1, { timeout: 1000 });
  }).toPass({ timeout: 20_000 });
  // From the server, a page before the oldest entry the chat had
  const requests = routes.sent.map((frame) => JSON.parse(frame) as { method: string; params: any });
  expect(requests.find((each) => each.method === 'conversation.subscribe')?.params.limit).toBe(100);
  expect(requests.some((each) => each.method === 'conversation.history' && each.params.before > 0)).toBe(true);
});
