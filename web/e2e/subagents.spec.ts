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

test('the chat\'s own run says working, and for how long in the title', async ({ app, api }) => {
  await api.chat('Own run', ['hello']);
  await listItem(app, 'Own run').click();
  await app.locator(field).click();
  const gate = api.gate();
  await app.keyboard.type(gate.command);
  await app.keyboard.press('Enter');
  await expect(app.locator('.MiddleHeader')).toContainText('working');
  await expect(app.locator('.MiddleHeader')).not.toContainText('typing');
  // The title counts the run from its first second, the chat list does not
  await expect(app.locator('.MiddleHeader')).toContainText(/working for [1-9]s/);
  await expect(listItem(app, 'Own run')).not.toContainText('working for');
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

test('the ⋯ menu lists the chat\'s subagents, what each does and for how long; a row or a card opens its conversation', async ({ app, api }) => {
  await api.chat('Subagent list', ['hello']);
  await listItem(app, 'Subagent list').click();
  await app.locator(field).click();
  await app.keyboard.type('& done-one: echo finished');
  await app.keyboard.press('Enter');
  await expect(app.locator('[data-tau-part="subagent"]').filter({ hasText: 'answered' })).toBeVisible();
  const gate = api.gate();
  await app.keyboard.type(`& busy-one: ${gate.command}`);
  await app.keyboard.press('Enter');
  await expect(app.locator('.MiddleHeader')).toContainText('busy-one working');

  await app.getByRole('button', { name: 'More options' }).click();
  const item = app.locator('.HeaderMenuContainer .MenuItem').filter({ hasText: 'Subagents' });
  await expect(item).toContainText('1 working, 2 in all');
  await item.hover();
  const rows = app.locator('.tau-subagent-row');
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0)).toContainText('done-one');
  // Its run took milliseconds (the dev model answers at once): not 0.0s
  await expect(rows.nth(0)).toContainText(/worked (under 0.1s|[\d.]+s), echo finished/);
  await expect(rows.nth(0)).not.toContainText('0.0s');
  await expect(rows.nth(1)).toContainText(/busy-one.*working( for \d+s)?, \$ until/);
  // Its time keeps going while the list is open
  await expect(rows.nth(1)).toContainText(/working for [2-9]s/);
  await rows.nth(1).click();
  // Its own conversation, working, not in the chat list
  await expect(app.locator('.MiddleHeader')).toContainText('busy-one');
  await expect(app.locator('.MiddleHeader')).toContainText('working');
  await expect(listItem(app, 'busy-one: $ until')).toHaveCount(0);
  gate.open();

  await listItem(app, 'Subagent list').click();
  await app.locator('[data-tau-part="subagent"]').filter({ hasText: 'done-one' }).first().click();
  await expect(app.locator('.MiddleHeader')).toContainText('done-one');
  await expect(app.locator('.MessageList').last()).toContainText('finished');
});
