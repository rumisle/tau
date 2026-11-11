// A message's context menu (ios/Tau/Chat/ChatController.swift "Context menu"): tau's in place of Telegram's, on answers
// and on the user's bubbles alike; Copy copies the Markdown, or what is selected; a refused message offers its reason,
// Resend and Delete.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const answer = '[data-tau-row="assistant"]:not([data-tau-draft])';

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator('#editable-message-text')).toBeVisible();
}

const menu = (app: Page) => app.locator('.tau-message-menu');
const clipboard = (app: Page) => app.evaluate(() => navigator.clipboard.readText());

test('Copy on an answer copies its Markdown; with part of it selected, the selection', async ({ app, api }) => {
  await app.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await api.chat('Menu copy', ['hello']);
  await openChat(app, 'Menu copy');
  const row = app.locator(answer).last();
  await row.locator('[data-tau-part="text"] p').first().click({ button: 'right' });
  await expect(menu(app).locator('.MenuItem')).toHaveText(['Copy']);
  await menu(app).locator('.MenuItem').filter({ hasText: 'Copy' }).click();
  expect(await clipboard(app)).toBe('You said: hello\n\nThis is the dev echo model as dev/echo, thinking off (turn 1). '
    + 'Start a message with `$ ` to run a shell command.');

  await expect(menu(app)).toHaveCount(0);
  // Part of it selected: Copy Selected Text
  await row.locator('[data-tau-part="text"] p').first().selectText();
  await row.locator('[data-tau-part="text"] p').first().click({ button: 'right' });
  await menu(app).locator('.MenuItem').filter({ hasText: 'Copy Selected Text' }).click();
  expect(await clipboard(app)).toBe('You said: hello');
});

test('the user\'s bubble has tau\'s menu, not Telegram\'s', async ({ app, api }) => {
  await app.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await api.chat('Menu bubble', ['a message of mine']);
  await openChat(app, 'Menu bubble');
  await app.locator('.Message.own').filter({ hasText: 'a message of mine' }).click({ button: 'right' });
  await expect(menu(app).locator('.MenuItem')).toHaveText(['Copy']);
  await menu(app).locator('.MenuItem').click();
  expect(await clipboard(app)).toBe('a message of mine');
});

test('a refused message: its reason, Resend and Delete', async ({ app, api }) => {
  await api.chat('Menu refused', ['hello']);
  await openChat(app, 'Menu refused');
  // 21 files: more than a message carries, refused before it is sent
  await app.getByRole('button', { name: 'Add attachment' }).hover();
  const chooser = app.waitForEvent('filechooser');
  await app.locator('.AttachMenu .MenuItem').filter({ hasText: 'File' }).click();
  await (await chooser).setFiles(Array.from({ length: 21 }, (_, i) => ({
    name: `f${i}.txt`, mimeType: 'text/plain', buffer: Buffer.from(`${i}\n`),
  })));
  await app.locator('.modal-dialog').getByRole('textbox').click();
  await app.keyboard.press('Enter');
  const bubble = app.locator('.Message.own').filter({ hasText: 'f0.txt' }).first();
  await expect(app.locator('.Message.own .MessageOutgoingStatus--failed').first()).toBeVisible();
  await bubble.click({ button: 'right' });
  await expect(menu(app).locator('.MenuItem')).toHaveText(['A message can carry at most 20 files', 'Resend', 'Delete']);
  await menu(app).locator('.MenuItem').filter({ hasText: 'Delete' }).click();
  await expect(app.locator('.Message.own').filter({ hasText: 'f0.txt' })).toHaveCount(0);
});
