// Read state and the chat list's marks (docs/protocol.md conversation.read, conversation.mark): reading a chat moves
// the server's read mark, Mark as Unread and Archive reach the server, and come back from it.
import type { Page } from '@playwright/test';

import type { TauClient } from '../../client/src/connection.ts';
import type { Dialog } from '../../client/src/protocol.ts';

import { expect, test } from './fixtures.ts';

// A chat's row by its title (the Archived Chats row lists the titles it holds)
const listItem = (app: Page, title: string) => app.locator('.chat-list .ListItem')
  .filter({ has: app.locator('.fullName').getByText(title, { exact: true }) });

async function dialogOf(api: { client: TauClient }, id: number) {
  const { dialogs } = await api.client.request('dialogs.subscribe', {});
  return (dialogs as Dialog[]).find((dialog) => dialog.conversation.id === id)!;
}

async function menu(app: Page, title: string, item: string) {
  await listItem(app, title).click({ button: 'right' });
  await app.locator('.ContextMenuContainer .MenuItem, .menu-container .MenuItem').filter({ hasText: item }).first().click();
}

test('an answer is unread until the chat is open; then the server has it read', async ({ app, api }) => {
  const id = await api.chat('Read me', ['hello']);
  // Telegram's unread badge, the count alone
  const badge = listItem(app, 'Read me').getByText('1', { exact: true });
  await expect(badge).toHaveText('1');
  await listItem(app, 'Read me').click();
  await expect(badge).toHaveCount(0);
  await expect.poll(async () => (await dialogOf(api, id)).unreadCount).toBe(0);
});

test('Mark as Unread and Archive reach the server; Unarchive brings the chat back', async ({ app, api }) => {
  const id = await api.chat('Marks', ['hello']);
  await listItem(app, 'Marks').click();
  await expect.poll(async () => (await dialogOf(api, id)).unreadCount).toBe(0);
  await menu(app, 'Marks', 'Mark as unread');
  await expect.poll(async () => (await dialogOf(api, id)).markedUnread).toBe(true);

  await menu(app, 'Marks', 'Archive');
  await expect.poll(async () => (await dialogOf(api, id)).archived).toBe(true);
  await expect(listItem(app, 'Marks')).toHaveCount(0);
  // From another device: back in the main list
  await api.client.request('conversation.mark', { conversationId: id, archived: false });
  await expect(listItem(app, 'Marks')).toBeVisible();
});
