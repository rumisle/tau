// The connection's state where Telegram shows it (the chat's header, the chat list's): "connecting" while the server
// is away, "waiting for network" when the device has none, as iOS's title says (c4c1f7e).
import type { WebSocketRoute } from '@playwright/test';

import { expect, test } from './fixtures.ts';

test('the header says connecting while the server is away, waiting for network when offline', async ({ app, api }) => {
  // The page's socket goes through a route the test can drop, and refuse while it wants the server away
  let current: WebSocketRoute | undefined;
  let isAway = false;
  await app.routeWebSocket(/\/socket$/, (socket) => {
    if (isAway) {
      void socket.close();
      return;
    }
    current = socket;
    socket.connectToServer();
  });
  await api.chat('Connection', ['hello']);
  await app.reload();
  await app.locator('.chat-list .fullName').getByText('Connection', { exact: true }).click();
  const header = app.locator('.MiddleHeader');
  await expect(header).toContainText('Connection');

  isAway = true;
  await current!.close();
  await expect(header).toContainText('connecting');
  await expect(header).not.toContainText('waiting for network');
  isAway = false;
  await expect(header).not.toContainText('connecting', { timeout: 15_000 });

  await app.context().setOffline(true);
  await expect(header).toContainText('waiting for network');
  await app.context().setOffline(false);
  await expect(header).not.toContainText('waiting for network', { timeout: 15_000 });
});
