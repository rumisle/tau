// The chat's ⋯ menu (ios/Tau/Chat/ChatController.swift openChatMenu): the model (its picker, searchable) and thinking
// level, shown at once and answering the next message (Compact Context: compaction.spec.ts).
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const row = '[data-tau-row="assistant"]:not([data-tau-draft])';
const field = '#editable-message-text';

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator(field)).toBeVisible();
}

async function send(app: Page, text: string) {
  await app.locator(field).click();
  await app.keyboard.type(text);
  await app.keyboard.press('Enter');
}

/** The model picker, from the ⋯ menu's Model submenu */
async function openPicker(app: Page) {
  await app.getByRole('button', { name: 'More options' }).click();
  await app.locator('.HeaderMenuContainer .MenuItem').filter({ hasText: 'Model' }).hover();
  await app.locator('.MenuItem').filter({ hasText: 'All Models…' }).click();
}

async function pick(app: Page, item: string, choice: RegExp | string) {
  await app.getByRole('button', { name: 'More options' }).click();
  await app.locator('.HeaderMenuContainer .MenuItem').filter({ hasText: item }).hover();
  await app.locator('.MenuItem').filter({ hasText: choice }).click();
}

test('the menu picks the thinking level and the model; the next answer comes from them', async ({ app, api }) => {
  await api.chat('Menu agent', ['hello']);
  await openChat(app, 'Menu agent');
  await app.getByRole('button', { name: 'More options' }).click();
  const menu = app.locator('.HeaderMenuContainer');
  await expect(menu.locator('.MenuItem').filter({ hasText: 'Model' })).toContainText('Dev echo');
  await expect(menu.locator('.MenuItem').filter({ hasText: 'Thinking' })).toContainText('Off');
  // Usage: how full the context is and the spend; the numbers a level down
  const usage = menu.locator('.MenuItem').filter({ hasText: 'Usage' });
  await expect(usage).toContainText(/\d+%, \$[\d.]+/);
  await usage.hover();
  await expect(app.locator('.tau-usage-row').filter({ hasText: 'Tokens' })).toContainText(/ in, .* out/);
  await app.keyboard.press('Escape');

  await pick(app, 'Thinking', /^High$/);
  await expect(app.locator('.Notification').filter({ hasText: 'Thinking set to High' })).toBeVisible();
  // The model picker: a search, Enter takes the first match
  await openPicker(app);
  const picker = app.locator('.tau-model-picker');
  await expect(picker.getByText('Dev echo')).toBeVisible();
  await picker.getByRole('textbox').fill('parrot');
  await expect(picker.locator('.ItemPickerItem')).toHaveCount(1);
  await app.keyboard.press('Enter');
  await expect(picker).toHaveCount(0);
  await expect(app.locator('.Notification').filter({ hasText: 'Model changed to Dev parrot' })).toBeVisible();
  await expect(app.locator('.Notification strong, .Notification b').filter({ hasText: 'Dev parrot' })).toBeVisible();
  await send(app, 'which model');
  await expect(app.locator(row).filter({ hasText: 'which model' }).last()).toContainText('dev/parrot, thinking high');

  // The menu says so, after the server has it too
  await app.getByRole('button', { name: 'More options' }).click();
  await expect(menu.locator('.MenuItem').filter({ hasText: 'Model' })).toContainText('Dev parrot');
  await expect(menu.locator('.MenuItem').filter({ hasText: 'Thinking' })).toContainText('High');
});

test('the model picker lists the recent models first; the Model submenu has them a click away', async ({ app, api }) => {
  await api.chat('Picker recent', ['hello']);
  await app.locator('.chat-list .fullName').getByText('Picker recent', { exact: true }).click();
  const picker = app.locator('.tau-model-picker');
  for (const name of ['Dev echo', 'Dev parrot']) {
    await openPicker(app);
    await picker.locator('.ItemPickerItem').filter({ hasText: name }).click();
    await expect(picker).toHaveCount(0);
  }
  await openPicker(app);
  await expect(picker.locator('.ItemPickerItem').nth(0)).toContainText('Dev parrot');
  await expect(picker.locator('.ItemPickerItem').nth(1)).toContainText('Dev echo');
  await picker.locator('.ItemPickerItem').first().click();
  await expect(picker).toHaveCount(0);

  // The submenu: the chat's model checked, then the recent ones, then all of them in the picker
  await app.getByRole('button', { name: 'More options' }).click();
  await app.locator('.HeaderMenuContainer .MenuItem').filter({ hasText: 'Model' }).hover();
  await expect(app.locator('.MenuItem').filter({ hasText: /^Dev parrot$/ }).locator('.icon-check')).toHaveCount(1);
  await app.locator('.MenuItem').filter({ hasText: /^Dev echo$/ }).click();
  await expect(app.locator('.Notification').filter({ hasText: 'Model changed to Dev echo' })).toBeVisible();
});
