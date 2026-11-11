// Rename (docs/protocol.md conversation.rename): from the chat list's menu or the chat's ⋯ menu, a small dialog with the
// title selected; shown at once, on the server after, with a toast that undoes it. New Chat's create takes its name.
import type { Page } from '@playwright/test';

import type { TauClient } from '../../client/src/connection.ts';
import type { Dialog } from '../../client/src/protocol.ts';

import { expect, test } from './fixtures.ts';

const listItem = (app: Page, title: string) => app.locator('.chat-list .ListItem')
  .filter({ has: app.locator('.fullName').getByText(title, { exact: true }) });

async function titleOf(api: { client: TauClient }, id: number) {
  const { dialogs } = await api.client.request('dialogs.subscribe', {});
  return (dialogs as Dialog[]).find((dialog) => dialog.conversation.id === id)?.title;
}

test('Rename from the list: the dialog, the new title at once and on the server, Undo', async ({ app, api }) => {
  const id = await api.chat('Rename me', ['hello']);
  await listItem(app, 'Rename me').click({ button: 'right' });
  await app.locator('.MenuItem:visible').filter({ hasText: 'Rename' }).click();
  const dialog = app.locator('.tau-rename');
  await expect(dialog.getByRole('textbox')).toBeFocused();
  // The title selected: typing replaces it
  await app.keyboard.type('Renamed   chat ');
  await app.keyboard.press('Enter');
  await expect(dialog).toHaveCount(0);
  await expect(listItem(app, 'Renamed chat')).toBeVisible();
  await expect.poll(() => titleOf(api, id)).toBe('Renamed chat');
  await app.locator('.Notification').filter({ hasText: 'Chat renamed to Renamed chat' }).getByText('Undo').click();
  await expect(listItem(app, 'Rename me')).toBeVisible();
  await expect.poll(() => titleOf(api, id)).toBe('Rename me');
});

test('Rename from the chat\'s ⋯ menu; Esc leaves the title as it was', async ({ app, api }) => {
  const id = await api.chat('Menu rename', ['hello']);
  await listItem(app, 'Menu rename').click();
  await app.getByRole('button', { name: 'More options' }).click();
  await app.locator('.HeaderMenuContainer .MenuItem').filter({ hasText: 'Rename' }).click();
  await expect(app.locator('.tau-rename').getByRole('textbox')).toBeFocused();
  await app.keyboard.type('Never mind');
  await app.keyboard.press('Escape');
  await expect(app.locator('.tau-rename')).toHaveCount(0);
  await expect(app.locator('.MiddleHeader')).toContainText('Menu rename');

  await app.getByRole('button', { name: 'More options' }).click();
  await app.locator('.HeaderMenuContainer .MenuItem').filter({ hasText: 'Rename' }).click();
  await expect(app.locator('.tau-rename').getByRole('textbox')).toBeFocused();
  await app.keyboard.type('From the header');
  await app.locator('.tau-rename').getByRole('button', { name: 'Save' }).click();
  await expect(app.locator('.MiddleHeader')).toContainText('From the header');
  await expect.poll(() => titleOf(api, id)).toBe('From the header');
});

test('New Chat renamed before its first message is created with that name', async ({ app }) => {
  await app.locator('.chat-list').hover();
  await app.getByRole('button', { name: 'New Message' }).click();
  await expect(app.locator('.MiddleHeader').getByText('New Chat')).toBeVisible();
  await app.getByRole('button', { name: 'More options' }).click();
  await app.locator('.HeaderMenuContainer .MenuItem').filter({ hasText: 'Rename' }).click();
  await expect(app.locator('.tau-rename').getByRole('textbox')).toBeFocused();
  await app.keyboard.type('Named first');
  await app.keyboard.press('Enter');
  await expect(app.locator('.MiddleHeader')).toContainText('Named first');
  await app.locator('#editable-message-text').click();
  await app.keyboard.type('the first message');
  await app.keyboard.press('Enter');
  await expect(app.locator('[data-tau-row="assistant"]:not([data-tau-draft])')
    .filter({ hasText: 'You said: the first message' })).toBeVisible();
  // Its answer names no chat: it keeps the user's name
  await expect(listItem(app, 'Named first')).toHaveCount(1);
  await expect(app.locator('.MiddleHeader')).toContainText('Named first');
});
