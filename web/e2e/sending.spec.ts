// Sending (docs/sending.md): the composer's message goes through the outbox, with Telegram's clock until the server has
// it and its checks once it is in the transcript; while the agent works, Send steers and Stop ends the run.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

// Answers, without the typing draft that streamed them
const row = '[data-tau-row="assistant"]:not([data-tau-draft])';
const field = '#editable-message-text';

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator(field)).toBeVisible();
}

async function type(app: Page, text: string) {
  await app.locator(field).click();
  await app.keyboard.type(text);
  await app.keyboard.press('Enter');
}

const own = (app: Page, text: string) => app.locator('.Message.own').filter({ hasText: text });

test('a message sent in an idle chat: the bubble at once, then two checks and the answer, once', async ({ app, api }) => {
  await api.chat('Send idle', ['hello']);
  await openChat(app, 'Send idle');
  await type(app, 'sent from the web');
  const bubble = own(app, 'sent from the web');
  await expect(bubble).toBeVisible();
  await expect(app.locator(row).filter({ hasText: 'You said: sent from the web' })).toBeVisible();
  await expect(bubble.locator('.icon-message-read')).toBeVisible();
  await expect(bubble).toHaveCount(1);
  await expect(app.locator(field)).toHaveText('');
  // In the transcript: after a reload it is the entry, once
  await app.reload();
  await openChat(app, 'Send idle');
  await expect(own(app, 'sent from the web')).toHaveCount(1);
  await expect(app.locator(row).filter({ hasText: 'You said: sent from the web' })).toHaveCount(1);
});

test('the field\'s Markdown reaches the model as written', async ({ app, api }) => {
  await api.chat('Send markdown', ['hello']);
  await openChat(app, 'Send markdown');
  await type(app, 'run `ls -la` and **bold**');
  const thinking = app.locator('[data-tau-part="thinking"]');
  await expect(thinking.filter({ hasText: 'The user said "run `ls -la` and **bold**"' }).last()).toBeVisible();
});

test('while the agent works, Send steers the run and Stop ends it', async ({ app, api }) => {
  await api.chat('Send busy', ['hello']);
  await openChat(app, 'Send busy');
  await type(app, '$ sleep 30');
  const stop = app.getByRole('button', { name: 'Stop' });
  await expect(stop).toBeVisible();
  // With text in the field, the button sends; the message waits for the run's next step
  await app.locator(field).click();
  await app.keyboard.type('a steer');
  await expect(stop).toHaveCount(0);
  await app.keyboard.press('Enter');
  await expect(own(app, 'a steer')).toBeVisible();
  await expect(stop).toBeVisible();
  await stop.click();
  await expect(stop).toHaveCount(0);
  // Queued when the run stopped: back in the field, out of the chat
  await expect(app.locator(field)).toHaveText('a steer');
  await expect(own(app, 'a steer')).toHaveCount(0);
});

test('a message waiting for the run outlives a reload: it shows again, once, and the run gets it', async ({ app, api }) => {
  await api.chat('Send reload', ['hello']);
  await openChat(app, 'Send reload');
  await type(app, '$ sleep 3');
  await expect(app.getByRole('button', { name: 'Stop' })).toBeVisible();
  await type(app, 'kept over a reload');
  await expect(own(app, 'kept over a reload').locator('.icon-check')).toBeVisible();
  await app.reload();
  await openChat(app, 'Send reload');
  await expect(own(app, 'kept over a reload')).toHaveCount(1);
  await expect(app.locator('[data-tau-part="thinking"]').filter({ hasText: 'kept over a reload' }).last())
    .toBeVisible({ timeout: 15_000 });
  await expect(own(app, 'kept over a reload')).toHaveCount(1);
  await expect(own(app, 'kept over a reload').locator('.icon-message-read')).toBeVisible();
});

test('what is typed is sent as typed: no dash for `--`, no guillemets for `<<`', async ({ app, api }) => {
  await api.chat('Send as typed', ['hello']);
  await openChat(app, 'Send as typed');
  await type(app, 'git log --oneline << EOF');
  await expect(own(app, 'git log --oneline << EOF')).toBeVisible();
});
