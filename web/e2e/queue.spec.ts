// The queue (docs/sending.md "What the user sees"): while the agent works, messages wait in a panel above the field,
// steers or follow-ups, this device's and other devices'; its menu edits, moves, sends now or deletes one; Send's menu
// (a right-click on Send) sends as a follow-up or stops and sends.
import type { Page } from '@playwright/test';

import type { TauClient } from '../../client/src/connection.ts';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';
const panel = (app: Page) => app.locator('.tau-queue-panel');
const own = (app: Page, text: string) => app.locator('.Message.own').filter({ hasText: text });
const thinking = (app: Page, text: string) => app.locator('[data-tau-part="thinking"]')
  .filter({ hasText: `The user said "${text}"` });

/** A chat whose agent works for a while: the user's `$ sleep` in a tool call */
async function busyChat(app: Page, api: { chat: (title: string, messages: string[]) => Promise<number> }, title: string) {
  const id = await api.chat(title, ['hello']);
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await type(app, '$ sleep 30');
  await expect(app.getByRole('button', { name: 'Stop', exact: true })).toBeVisible();
  return id;
}

async function type(app: Page, text: string, options: { send?: boolean } = {}) {
  await app.locator(field).click();
  await app.keyboard.type(text);
  if (options.send !== false) await app.keyboard.press('Enter');
}

/**
 * The panel's menu, then an item of it; `of`: the queued message whose submenu has it. Then its closing waited for: a
 * menu opened while the last one closes does not open.
 */
async function queueAction(app: Page, item: string, of?: string) {
  await panel(app).locator('.EmbeddedMessage').click();
  if (of) await app.locator('.tau-queue-menu .MenuItem').filter({ hasText: of }).hover();
  // A submenu is a menu of its own, beside the panel's
  await app.locator('.MenuItem:visible').filter({ hasText: item }).click();
  await expect(app.locator('.MenuItem:visible')).toHaveCount(0);
}

async function inboxOf(client: TauClient, conversationId: number) {
  const result = await client.request('conversation.subscribe', { conversationId, limit: 1 });
  return ((result.docs['pi.inbox'] as { items?: { mode: string }[] } | undefined)?.items ?? []);
}

test('Send\'s menu sends a follow-up; the panel counts them; × and Delete withdraw them', async ({ app, api }) => {
  const id = await busyChat(app, api, 'Queue modes');
  await type(app, 'a steer');
  await expect(panel(app)).toContainText('Steer');
  await type(app, 'a follow-up', { send: false });
  await app.getByRole('button', { name: 'Send Message' }).click({ button: 'right' });
  await app.locator('.tau-send-menu .MenuItem').filter({ hasText: 'Send as Follow-up' }).click();
  await expect(panel(app)).toContainText('· 2');
  await expect.poll(async () => (await inboxOf(api.client, id)).map((each) => each.mode)).toEqual(['steer', 'followUp']);
  await expect(own(app, 'a follow-up')).toHaveCount(0);

  // Each has its actions a level down; Send as Steer moves the follow-up
  await queueAction(app, 'Send as Steer', 'a follow-up');
  await expect.poll(async () => (await inboxOf(api.client, id)).map((each) => each.mode)).toEqual(['steer', 'steer']);

  // × withdraws the first; Delete in the menu the other
  await panel(app).getByRole('button', { name: 'Delete' }).click();
  await expect(panel(app)).toContainText('a follow-up');
  await expect(panel(app)).not.toContainText('· 2');
  await queueAction(app, 'Delete');
  await expect(panel(app)).toHaveCount(0);
  await expect.poll(async () => (await inboxOf(api.client, id)).length).toBe(0);
});

test('Edit brings a queued message back to the field; Send Now stops the agent and sends it', async ({ app, api }) => {
  const id = await busyChat(app, api, 'Queue now');
  await type(app, 'to change');
  await expect(panel(app).locator('.icon-check')).toBeVisible();
  await queueAction(app, 'Edit');
  await expect(app.locator(field)).toHaveText('to change');
  await expect(panel(app)).toHaveCount(0);
  await app.locator(field).fill('');

  await type(app, 'right now');
  await expect(panel(app)).toContainText('right now');
  await queueAction(app, 'Send Now');
  await expect(panel(app)).toHaveCount(0);
  await expect(thinking(app, 'right now').last()).toBeVisible();
  await expect(own(app, 'right now')).toHaveCount(1);
  await expect.poll(async () => (await inboxOf(api.client, id)).length).toBe(0);
});

test('another device\'s queued message shows in the panel, and can be deleted from here', async ({ app, api }) => {
  const id = await busyChat(app, api, 'Queue other');
  await api.client.request('conversation.submit', {
    conversationId: id, requestId: crypto.randomUUID(), content: 'from the phone', whenBusy: 'followUp',
  });
  await expect(panel(app)).toContainText('Follow-up');
  await expect(panel(app)).toContainText('from the phone');
  await queueAction(app, 'Delete');
  await expect(panel(app)).toHaveCount(0);
  await expect.poll(async () => (await inboxOf(api.client, id)).length).toBe(0);
});

test('Stop and Send from Send\'s menu; idle, Send has no menu', async ({ app, api }) => {
  await busyChat(app, api, 'Queue stop');
  await type(app, 'instead', { send: false });
  await app.getByRole('button', { name: 'Send Message' }).click({ button: 'right' });
  await app.locator('.tau-send-menu .MenuItem').filter({ hasText: 'Stop and Send' }).click();
  await expect(thinking(app, 'instead').last()).toBeVisible();
  await expect(panel(app)).toHaveCount(0);
  await expect(app.getByRole('button', { name: 'Stop', exact: true })).toHaveCount(0);

  await type(app, 'idle', { send: false });
  await app.getByRole('button', { name: 'Send Message' }).click({ button: 'right' });
  await expect(app.locator('.CustomSendMenu')).toHaveCount(0);
});
