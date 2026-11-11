// Subagents (41cf19a, durable's background subagents): one started in the background leaves its chat free, its card
// working; the title and the list say who works, as Telegram says who is typing ("reader working"; "working" for the
// chat's own run); its answer arrives as its card.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';
const listItem = (app: Page, title: string) => app.locator('.chat-list .ListItem')
  .filter({ has: app.locator('.fullName').getByText(title, { exact: true }) });

test('a background subagent: the chat free, who works in the title and the list, its answer as its card', async ({ app, api }) => {
  await api.chat('Background', ['hello']);
  await listItem(app, 'Background').click();
  await app.locator(field).click();
  // The dev model starts a subagent with `& name: task`
  await app.keyboard.type('& reader: $ sleep 3 && echo found the bug');
  await app.keyboard.press('Enter');
  const card = app.locator('[data-tau-part="subagent"]').filter({ hasText: 'reader' });
  await expect(card.first()).toContainText('working');
  await expect(app.locator('.MiddleHeader')).toContainText('reader working');
  await expect(listItem(app, 'Background')).toContainText('reader working');
  // Free while it works: Send sends, there is no Stop
  await expect(app.getByRole('button', { name: 'Stop', exact: true })).toHaveCount(0);

  await expect(card.filter({ hasText: 'answered' })).toContainText('found the bug', { timeout: 15_000 });
  await expect(app.locator('.MiddleHeader')).not.toContainText('working');
});

test('the chat\'s own run says working', async ({ app, api }) => {
  await api.chat('Own run', ['hello']);
  await listItem(app, 'Own run').click();
  await app.locator(field).click();
  await app.keyboard.type('$ sleep 3');
  await app.keyboard.press('Enter');
  await expect(app.locator('.MiddleHeader')).toContainText('working');
  await expect(app.locator('.MiddleHeader')).not.toContainText('typing');
});
