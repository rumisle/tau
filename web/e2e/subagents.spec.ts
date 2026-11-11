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
  const gate = api.gate();
  await app.keyboard.type(`& reader: ${gate.command}; echo found the bug`);
  await app.keyboard.press('Enter');
  const card = app.locator('[data-tau-part="subagent"]').filter({ hasText: 'reader' });
  await expect(card.first()).toContainText('working');
  await expect(app.locator('.MiddleHeader')).toContainText('reader working');
  await expect(listItem(app, 'Background')).toContainText('reader working');
  // Free while it works: Send sends, there is no Stop
  await expect(app.getByRole('button', { name: 'Stop', exact: true })).toHaveCount(0);
  gate.open();

  await expect(card.filter({ hasText: 'answered' })).toContainText('found the bug');
  await expect(app.locator('.MiddleHeader')).not.toContainText('working');
});

test('the chat\'s own run says working', async ({ app, api }) => {
  await api.chat('Own run', ['hello']);
  await listItem(app, 'Own run').click();
  await app.locator(field).click();
  const gate = api.gate();
  await app.keyboard.type(gate.command);
  await app.keyboard.press('Enter');
  await expect(app.locator('.MiddleHeader')).toContainText('working');
  await expect(app.locator('.MiddleHeader')).not.toContainText('typing');
  gate.open();
});

test('a spawn on another model, effort or a fork says so under its task while it works', async ({ app, api }) => {
  await api.chat('Spawn options', ['hello']);
  await listItem(app, 'Spawn options').click();
  await app.locator(field).click();
  const gate = api.gate();
  await app.keyboard.type(`& scout fork model=dev/echo thinking=high: ${gate.command}`);
  await app.keyboard.press('Enter');
  const card = app.locator('[data-tau-part="subagent"]').filter({ hasText: 'scout' }).first();
  await expect(card).toContainText('working');
  await expect(card).toContainText('echo, thinking high, forked from this chat');
  gate.open();
});
