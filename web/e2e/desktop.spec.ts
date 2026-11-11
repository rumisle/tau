// Desktop conventions (docs/web.md "Desktop, not iOS gestures"): a double-click selects a word and starts no reply,
// files dropped on the chat are sent as the paperclip sends them. (Up in an empty field edits: edits.spec.ts.)
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator(field)).toBeVisible();
}

test('a double-click on a bubble selects a word, with no reply', async ({ app, api }) => {
  await api.chat('Desktop keys', ['first message']);
  await openChat(app, 'Desktop keys');
  await app.locator('.Message.own').filter({ hasText: 'first message' }).locator('.text-content').dblclick();
  expect((await app.evaluate(() => window.getSelection()?.toString()))?.trim()).toMatch(/^(first|message)$/);
  await expect(app.locator('.ComposerEmbeddedMessage')).toHaveCount(0);
});

test('a file dropped on the chat goes as the paperclip\'s File does', async ({ app, api }) => {
  await api.chat('Desktop drop', ['hello']);
  await openChat(app, 'Desktop drop');
  const transfer = await app.evaluateHandle(() => {
    const data = new DataTransfer();
    data.items.add(new File(['# Dropped\n'], 'dropped.md', { type: 'text/markdown' }));
    return data;
  });
  const target = app.locator('.MessageList');
  await target.dispatchEvent('dragenter', { dataTransfer: transfer });
  await target.dispatchEvent('dragover', { dataTransfer: transfer });
  const zone = app.locator('.DropArea .DropTarget').last();
  await expect(zone).toBeVisible();
  await zone.dispatchEvent('drop', { dataTransfer: transfer });
  const modal = app.locator('.modal-dialog').filter({ hasText: 'dropped.md' });
  await expect(modal).toBeVisible();
  await modal.getByRole('textbox').click();
  await app.keyboard.press('Enter');
  await expect(app.locator('[data-tau-row="assistant"]:not([data-tau-draft])').filter({ hasText: '[dropped.md]' }))
    .toBeVisible();
});
