// Several servers (docs/web.md "Several servers"): another server added by its address and token in Servers, its chats
// in the one list beside this page's server's, sent to and answered there; New Chat on it from the New Message
// button's right-click; the list kept over a reload; removed, its chats leave.
import type { Page } from '@playwright/test';

import type { Dialog } from '../../client/src/protocol.ts';

import {
  expect, SECOND_TOKEN, startSecondServer, test,
} from './fixtures.ts';

// The chat's field (Web A keeps the last chat's, out of sight, for Back)
const field = '#editable-message-text >> visible=true';
const answers = '[data-tau-row="assistant"]:not([data-tau-draft])';
const listItem = (app: Page, title: string) => app.locator('.chat-list .ListItem')
  .filter({ has: app.locator('.fullName').getByText(title, { exact: true }) });

async function openServers(app: Page) {
  await app.getByRole('button', { name: 'Open menu' }).click();
  await app.locator('.MenuItem').filter({ hasText: 'Servers' }).click();
  await expect(app.locator('.tau-servers .modal-dialog')).toBeVisible();
}

test('a second server: added, its chats in the list and answered there, New Chat on it, removed', async ({ app, api }) => {
  const second = await startSecondServer();
  try {
    const { dialog } = await second.client.request('conversation.create', {
      title: 'Over there', requestId: crypto.randomUUID(),
    });
    await api.chat('Over here', ['hello']);
    await expect(listItem(app, 'Over here')).toBeVisible();

    await openServers(app);
    await app.locator('.tau-servers .ListItem').filter({ hasText: 'Add Server' }).click();
    await expect(app.locator('.tau-servers input').first()).toBeFocused();
    await app.keyboard.type(second.host);
    await app.locator('.tau-servers input').nth(1).click();
    // A wrong token first: refused, and said so
    await app.keyboard.type('not-the-token-0123456789');
    await app.keyboard.press('Enter');
    await expect(app.locator('.tau-servers')).toContainText('did not take this token');
    await app.locator('.tau-servers input').nth(1).fill(SECOND_TOKEN);
    await app.locator('.tau-servers').getByRole('button', { name: 'Add' }).click();
    const row = app.locator('.tau-server').filter({ hasText: second.host });
    await expect(row).toContainText('Connected');
    await app.keyboard.press('Escape');

    // Its chat in the one list, sent to and answered on that server
    await listItem(app, 'Over there').click();
    await app.locator(field).click();
    await app.keyboard.type('across servers');
    await app.keyboard.press('Enter');
    await expect(app.locator(answers).filter({ hasText: 'You said: across servers' })).toContainText('dev/parrot');
    const { entries } = await second.client.request('conversation.history', {
      conversationId: dialog.conversation.id, limit: 10,
    });
    expect(entries.some((entry: { kind: string }) => entry.kind === 'pi.user')).toBe(true);

    // New Chat on it, from the button's right-click
    await app.locator('.chat-list').hover();
    await app.getByRole('button', { name: 'New Message' }).click({ button: 'right' });
    await app.locator('.MenuItem:visible').filter({ hasText: second.host }).click();
    await expect(app.locator('.MiddleHeader')).toContainText(second.host);
    // Once the last chat has slid out of sight
    await expect(app.locator(field)).toHaveCount(1);
    await app.locator(field).click();
    await app.keyboard.type('a new one there');
    await app.keyboard.press('Enter');
    await expect(app.locator(answers).filter({ hasText: 'You said: a new one there' })).toContainText('dev/parrot');
    await expect.poll(async () => {
      const { dialogs } = await second.client.request('dialogs.subscribe', {});
      return (dialogs as Dialog[]).length;
    }).toBe(2);

    // Kept over a reload
    await app.reload();
    await expect(listItem(app, 'Over there')).toBeVisible();
    await expect(listItem(app, 'Over here')).toBeVisible();

    // Removed: its chats leave the list, this server's stay
    await openServers(app);
    await app.locator('.tau-server').filter({ hasText: second.host }).click({ button: 'right' });
    await app.locator('.MenuItem:visible').filter({ hasText: 'Remove' }).click();
    await expect(app.locator('.tau-server')).toHaveCount(1);
    await app.keyboard.press('Escape');
    await expect(listItem(app, 'Over there')).toHaveCount(0);
    await expect(listItem(app, 'Over here')).toBeVisible();
  } finally {
    await second.stop();
  }
});
