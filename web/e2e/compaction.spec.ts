// Compaction (98a1bab; iOS: the pill and the summary's card): Compact Context in the ⋯ menu; while it runs, a pill with
// the τ and its time over the end of the chat, the menu saying so and the title "compacting for"; the chat goes on
// meanwhile. Then the summary as a card, folded until clicked; its right-click menu's Restore Full Context opens a copy
// from before the summary, which exists once something is sent in it.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator(field)).toBeVisible();
}

const menuItem = (app: Page, text: string) => app.locator('.HeaderMenuContainer .MenuItem').filter({ hasText: text });

test('Compact Context: the pill while it runs, then the summary\'s card; Restore Full Context forks before it', async ({ app, api }) => {
  await api.chat('Compact me', ['one two three', 'four five six', 'seven eight']);
  await openChat(app, 'Compact me');
  await app.getByRole('button', { name: 'More options' }).click();
  await menuItem(app, 'Compact Context').click();

  const pill = app.locator('[data-tau-part="compacting"]');
  await expect(pill).toContainText('Compacting context…');
  await expect(pill.locator('[data-tau-part="waiting"]')).toHaveCount(1);
  await expect(app.locator('.MiddleHeader')).toContainText('compacting');
  await app.getByRole('button', { name: 'More options' }).click();
  await expect(menuItem(app, 'Compacting Context…')).toHaveClass(/disabled/);
  // Closed by a click outside it (Escape would close the chat too)
  await app.locator('#portals .backdrop').click();
  await expect(app.locator('.HeaderMenuContainer .MenuItem')).toHaveCount(0);

  const card = app.locator('[data-tau-part="compaction"]');
  await expect(card).toContainText('Context compacted');
  await expect(card).toContainText(/At \d{1,2}:\d{2}/);
  await expect(card).toContainText('Try tau\'s compaction with the dev model');
  await expect(pill).toHaveCount(0);
  // Folded until clicked
  await expect(card).not.toHaveAttribute('data-tau-expanded');
  await card.click();
  await expect(card).toHaveAttribute('data-tau-expanded', 'true');

  await card.click({ button: 'right' });
  await app.locator('.tau-message-menu .MenuItem').filter({ hasText: 'Restore Full Context' }).click();
  await expect(app.locator('.Notification')).toContainText('A copy from before the summary');
  // The copy: the chat up to before the summary, no card; not created until a message is sent in it
  await expect(app.locator('.MessageList').last()).toContainText('seven eight');
  await expect(app.locator('.MessageList').last().locator('[data-tau-part="compaction"]')).toHaveCount(0);
  const before = (await api.client.request<{ dialogs: unknown[] }>('dialogs.subscribe', {})).dialogs.length;
  await expect(app.locator(`${field} >> visible=true`)).toHaveCount(1);
  await app.locator(`${field} >> visible=true`).click();
  await app.keyboard.type('what did I say first?');
  await app.keyboard.press('Enter');
  await expect(app.locator('[data-tau-row="assistant"]:not([data-tau-draft])').filter({ hasText: 'what did I say first?' }))
    .toBeVisible();
  await expect.poll(async () => (await api.client.request<{ dialogs: unknown[] }>('dialogs.subscribe', {}))
    .dialogs.length).toBe(before + 1);
  await expect(app.locator('.chat-list .fullName').getByText('Compact me', { exact: true })).toHaveCount(2);
});

test('a compaction that fails while the chat is open says so once, as a toast in words; its note stays, quiet on reopen and reload', async ({ app, api }) => {
  await api.chat('Compact fail', ['!compact-fail one two', 'three four']);
  await api.chat('Other', ['hello']);
  await openChat(app, 'Compact fail');
  await app.getByRole('button', { name: 'More options' }).click();
  await menuItem(app, 'Compact Context').click();
  const toast = app.locator('.Notification');
  await expect(toast).toContainText('The context could not be compacted: 400: prompt is too long');
  await expect(toast).not.toContainText('{');
  const note = app.locator('[data-tau-part="note"]');
  await expect(note).toHaveText('Compaction failed: 400: prompt is too long');
  // Not a message: the chat list still shows the answer, with no count
  const row = app.locator('.chat-list .ListItem').filter({ hasText: 'Compact fail' });
  await expect(row).toContainText('You said: three four');
  await expect(row.getByText('1', { exact: true })).toHaveCount(0);
  await expect(toast).toHaveCount(0, { timeout: 10_000 });
  // Away and back: the snapshot has the failure, and the chat stays quiet
  await openChat(app, 'Other');
  await openChat(app, 'Compact fail');
  await expect(note).toBeVisible();
  await app.reload();
  await openChat(app, 'Compact fail');
  await expect(note).toHaveText('Compaction failed: 400: prompt is too long');
  // The subscribe brought the failure before the note showed: a toast would be up by now
  await expect(toast).toHaveCount(0);
});
