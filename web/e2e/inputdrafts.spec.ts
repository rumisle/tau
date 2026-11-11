// What is written and not sent (docs/sending.md "Edits and drafts"): kept per chat on this device, over a reload, with
// Telegram's red "Draft:" in the list; sending it clears it. New Chat keeps one of its own.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';
const listItem = (app: Page, title: string) => app.locator('.chat-list .ListItem')
  .filter({ has: app.locator('.fullName').getByText(title, { exact: true }) });

test('a chat\'s draft outlives a reload, shows as Draft: in the list, and goes once sent', async ({ app, api }) => {
  await api.chat('Draft kept', ['hello']);
  await listItem(app, 'Draft kept').click();
  await app.locator(field).click();
  await app.keyboard.type('half a thought');
  // Reloaded before the save a second after typing stops: saved as the page unloads. A frame first, for the composer
  // to have the text (it renders on the next frame, as after any keystroke)
  await app.waitForTimeout(200);
  await app.reload();
  await expect(listItem(app, 'Draft kept')).toContainText('Draft:');
  await expect(listItem(app, 'Draft kept')).toContainText('half a thought');
  await listItem(app, 'Draft kept').click();
  await expect(app.locator(field)).toHaveText('half a thought');

  await app.locator(field).click();
  await app.keyboard.press('End');
  await app.keyboard.type(', finished');
  await app.keyboard.press('Enter');
  await expect(app.locator('.Message.own').filter({ hasText: 'half a thought, finished' })).toBeVisible();
  await app.reload();
  await expect(listItem(app, 'Draft kept')).not.toContainText('Draft:');
  await listItem(app, 'Draft kept').click();
  await expect(app.locator(field)).toHaveText('');
});

test('New Chat keeps what was written in it', async ({ app }) => {
  await app.locator('.chat-list').hover();
  await app.getByRole('button', { name: 'New Message' }).click();
  await expect(app.locator('.MiddleHeader').getByText('New Chat')).toBeVisible();
  await app.locator(field).click();
  await app.keyboard.type('an idea for later');
  await app.waitForTimeout(200);
  await app.reload();
  await app.locator('.chat-list').hover();
  await app.getByRole('button', { name: 'New Message' }).click();
  await expect(app.locator(field)).toHaveText('an idea for later');
});
