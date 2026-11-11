// Where a message sent goes (docs/web.md "Reading position"): as ChatGPT does and Web A does for a bot's streamed
// answer, the user's message goes to the top of the view and the answer grows below it; the view moves only as the
// user scrolls. Whatever the run does first (a wait with the τ, a call), for a steer, for a message from another device
// while the chat is at its end, over a reconnect. A chat opened while it works opens at its end. The web differs from
// iOS here, which stays at the bottom and follows the answer: the user's choice.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';
// At the top of the view: just under the floating header
const TOP = 40;

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator(field)).toBeVisible();
}

async function type(app: Page, text: string) {
  await app.locator(field).click();
  await app.keyboard.type(text);
  await app.keyboard.press('Enter');
}

/** A message's top, from the bottom of the chat's header */
const topOf = (app: Page, text: string) => app.evaluate((wanted) => {
  const header = document.querySelector('.MiddleHeader')!.getBoundingClientRect().bottom;
  const own = [...document.querySelectorAll('.Message.own')].filter((each) => each.textContent?.includes(wanted)).at(-1);
  return own ? Math.round(own.getBoundingClientRect().top - header) : undefined;
}, text);

const atTop = async (app: Page, text: string) => {
  await expect.poll(() => topOf(app, text)).toBeGreaterThanOrEqual(0);
  await expect.poll(() => topOf(app, text)).toBeLessThan(TOP);
};

/** A chat with a few turns, so its messages fill more than the view */
async function longChat(api: { chat(title: string, messages: string[]): Promise<number> }, title: string) {
  return api.chat(title, ['one', 'two', 'three', 'four']);
}

test('a message sent goes to the top, the τ and the answer below it, and stays there', async ({ app, api }) => {
  await longChat(api, 'Tail plain');
  await openChat(app, 'Tail plain');
  await type(app, '~2 a pause first');
  await atTop(app, 'a pause first');
  const waiting = app.locator('[data-tau-part="waiting"]');
  await expect(waiting).toHaveCount(1);
  const own = await topOf(app, 'a pause first');
  expect((await waiting.boundingBox())!.y).toBeGreaterThan(own!);
  await expect(app.locator('[data-tau-row="assistant"]:not([data-tau-draft])').filter({ hasText: 'a pause first' }))
    .toBeVisible();
  // The answer in: nothing moved
  expect(await topOf(app, 'a pause first')).toBe(own);
});

test('a call that runs first, and a steer meanwhile: each goes to the top as it is sent', async ({ app, api }) => {
  await longChat(api, 'Tail call');
  await openChat(app, 'Tail call');
  const gate = api.gate();
  await type(app, gate.command);
  await atTop(app, 'until');
  await expect(app.locator('[data-tau-part="tool"]').last()).toBeVisible();
  // The steer waits above the field until the run's next step takes it; then it is the chat's message
  await type(app, 'a steer meanwhile');
  await expect(app.locator('.tau-queue-panel')).toContainText('a steer meanwhile');
  await atTop(app, 'until');
  gate.open();
  await atTop(app, 'a steer meanwhile');
  await expect(app.getByRole('button', { name: 'Stop', exact: true })).toHaveCount(0);
  await atTop(app, 'a steer meanwhile');
});

test('a message from another device goes to the top while the chat is at its end', async ({ app, api }) => {
  const id = await longChat(api, 'Tail remote');
  await openChat(app, 'Tail remote');
  await api.send(id, '~1 from the phone', { wait: false });
  await atTop(app, 'from the phone');
});

test('sent while reading a long answer: the new message goes to the top all the same', async ({ app, api }) => {
  await longChat(api, 'Tail long');
  await openChat(app, 'Tail long');
  await type(app, '!doc 8');
  await atTop(app, '!doc 8');
  await expect(app.locator('[data-tau-row="assistant"]:not([data-tau-draft])').filter({ hasText: 'Section 8' })
    .locator('[data-tau-part="footer"]')).toHaveCount(1);
  // The answer outgrew the view, which stayed at its start
  await atTop(app, '!doc 8');
  await type(app, 'the next one');
  await atTop(app, 'the next one');
});

test('over a reconnect the message stays at the top', async ({ app, api }) => {
  await longChat(api, 'Tail reconnect');
  await openChat(app, 'Tail reconnect');
  const gate = api.gate();
  await type(app, gate.command);
  await atTop(app, 'until');
  await app.context().setOffline(true);
  await expect(app.locator('.MiddleHeader')).toContainText(/connecting|waiting for network/i);
  await app.context().setOffline(false);
  gate.open();
  await expect(app.getByRole('button', { name: 'Stop', exact: true })).toHaveCount(0);
  await atTop(app, 'until');
});

test('a chat opened while it works opens at its end, its last message at the bottom', async ({ app, api }) => {
  const id = await longChat(api, 'Tail opened');
  await api.chat('Tail elsewhere', ['hello']);
  const gate = api.gate();
  await api.send(id, gate.command, { wait: false });
  await openChat(app, 'Tail opened');
  await expect(app.locator('[data-tau-part="tool"]').last()).toBeVisible();
  // At the end, not at the top
  await expect.poll(async () => (await topOf(app, 'until'))! > TOP * 3).toBe(true);
  gate.open();
});
