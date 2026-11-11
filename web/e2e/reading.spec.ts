// The reading position in its desktop form (0064fc3, 4a6749b, d0f860c, 825ee37, 5363d71; docs/reading-position.md):
// seen is what was on screen; a chat opens where it was left, then down to what follows if that is unseen; Mod+Up
// goes to the start of the turn above, the down button and Mod+Down back where a jump left from, then to the end.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';
const MOD = process.platform === 'darwin' ? 'Meta' : 'Control';

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator('.MiddleHeader')).toContainText(title);
  await expect(app.locator(field)).toBeVisible();
}

const list = (app: Page) => app.locator('.MessageList').last();

/** At the top of the view: just under the header */
async function expectAtTop(app: Page, text: string) {
  await expect.poll(() => topOf(app, text)).toBeGreaterThan(-5);
  await expect.poll(() => topOf(app, text)).toBeLessThan(40);
}

/** Where a user's message, or an answer's text, is: its top from the header's bottom */
const topOf = (app: Page, text: string, selector = '.Message.own') => app.evaluate(([wanted, rows]) => {
  const header = document.querySelector('.MiddleHeader')!.getBoundingClientRect().bottom;
  const found = [...document.querySelectorAll(rows)].filter((each) => each.textContent?.includes(wanted)).at(-1);
  return found ? Math.round(found.getBoundingClientRect().top - header) : undefined;
}, [text, selector] as const);

/** The list's distance from its end */
const fromEnd = (app: Page) => list(app).evaluate((element) => Math.round(
  element.scrollHeight - element.scrollTop - element.clientHeight,
));

/** Scrolls the list by hand: a wheel, which the page takes as the user's, turned a few times as a hand does */
async function scrollBy(app: Page, pixels: number) {
  const box = (await list(app).boundingBox())!;
  await app.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  const steps = Math.max(1, Math.ceil(Math.abs(pixels) / 250));
  for (let i = 0; i < steps; i++) await app.mouse.wheel(0, pixels / steps);
}

/** Settled: the list's scroll the same twice, a frame apart */
async function settled(app: Page) {
  await expect.poll(() => list(app).evaluate((element) => new Promise<boolean>((done) => {
    const before = element.scrollTop;
    requestAnimationFrame(() => requestAnimationFrame(() => done(element.scrollTop === before)));
  }))).toBe(true);
}

test('left right after sending, reopened after a long answer: the user\'s message at the top, the answer below', async ({ app, api }) => {
  const id = await api.chat('Sent and left', ['hello']);
  await api.chat('Elsewhere', ['hello']);
  await openChat(app, 'Sent and left');
  const gate = api.gate();
  await app.locator(field).click();
  await app.keyboard.type(gate.command);
  await app.keyboard.press('Enter');
  await expect(app.getByRole('button', { name: 'Stop', exact: true })).toBeVisible();
  await expect.poll(() => topOf(app, gate.command)).toBeLessThan(60);
  await openChat(app, 'Elsewhere');
  gate.open();
  await api.send(id, '!doc 6');
  await openChat(app, 'Sent and left');
  await settled(app);
  // Where it was left: the message sent near the top; the answers below it, not the end
  const top = await topOf(app, gate.command);
  expect(top).toBeGreaterThanOrEqual(0);
  expect(top).toBeLessThan(60);
  expect(await fromEnd(app)).toBeGreaterThan(200);
});

test('left half way down an answer, reopened after more came: the last lines seen near the top', async ({ app, api }) => {
  const id = await api.chat('Half read', ['hello']);
  await api.chat('Elsewhere', ['hello']);
  await openChat(app, 'Half read');
  // Sent here: at the top, the long answer grows below the view, unseen but for its start
  await app.locator(field).click();
  await app.keyboard.type('!doc 8');
  await app.keyboard.press('Enter');
  await expect(app.locator('[data-tau-row="assistant"]').filter({ hasText: 'Section 8' })).toHaveCount(1);
  await settled(app);
  // Read down a little, by hand
  await scrollBy(app, 500);
  await settled(app);
  const left = await list(app).evaluate((element) => element.scrollTop);
  const height = await list(app).evaluate((element) => element.clientHeight);
  await openChat(app, 'Elsewhere');
  await api.send(id, 'more after that');
  await openChat(app, 'Half read');
  await settled(app);
  // Moved down past what was seen, which ends near the top
  const scrollTop = await list(app).evaluate((element) => element.scrollTop);
  expect(scrollTop).toBeGreaterThan(left + height / 2);
  expect(scrollTop).toBeLessThan(left + height);
});

test('scrolled back and left, reopened after more came: exactly where it was, with the down button', async ({ app, api }) => {
  const id = await api.chat('Scrolled back', ['one', 'two', '!doc 4', 'three']);
  await api.chat('Elsewhere', ['hello']);
  await openChat(app, 'Scrolled back');
  await settled(app);
  await list(app).evaluate((element) => element.scrollTo({ top: element.scrollHeight }));
  await settled(app);
  await scrollBy(app, -900);
  await settled(app);
  const before = await topOf(app, 'You said: two', '[data-tau-row="assistant"]');
  await openChat(app, 'Elsewhere');
  await api.send(id, 'four');
  await openChat(app, 'Scrolled back');
  await settled(app);
  const after = await topOf(app, 'You said: two', '[data-tau-row="assistant"]');
  expect(Math.abs(after! - before!)).toBeLessThanOrEqual(2);
  await expect(app.getByRole('button', { name: 'Go to bottom' })).toBeVisible();
});

test('Mod+Up goes up turn by turn; the down button comes back point by point, then to the end', async ({ app, api }) => {
  await api.chat('Turns', ['first question', '!doc 8 one', 'second question', '!doc 8 two']);
  await openChat(app, 'Turns');
  await list(app).evaluate((element) => element.scrollTo({ top: element.scrollHeight }));
  await settled(app);
  await app.locator(field).click();
  // The last turn's start (its answer outgrew the screen): its message at the top
  await app.keyboard.press(`${MOD}+ArrowUp`);
  await settled(app);
  await expectAtTop(app, '!doc 8 two');
  // Up again: the turn before it
  await app.keyboard.press(`${MOD}+ArrowUp`);
  await settled(app);
  await expectAtTop(app, 'second question');
  await app.keyboard.press(`${MOD}+ArrowUp`);
  await settled(app);
  await expectAtTop(app, '!doc 8 one');
  const atDoc = await list(app).evaluate((element) => element.scrollTop);
  // Down: back where the last jump left from, then the one before, then the end
  await app.getByRole('button', { name: 'Go to bottom' }).click();
  // The point the last jump left from: the second question at the top again
  await expectAtTop(app, 'second question');
  expect(await list(app).evaluate((element) => element.scrollTop)).toBeGreaterThan(atDoc);
  // Down again, each time further, until none is left: the end
  const scrollTop = () => list(app).evaluate((element) => element.scrollTop);
  for (let i = 0; i < 3; i++) {
    await settled(app);
    if (await fromEnd(app) < 10) break;
    const before = await scrollTop();
    await app.keyboard.press(`${MOD}+ArrowDown`);
    await expect.poll(scrollTop).toBeGreaterThan(before);
  }
  await expect.poll(() => fromEnd(app)).toBeLessThan(10);
});

test('an answer that lands below the view is unread in the list until it is on screen', async ({ app, api }) => {
  const id = await api.chat('Below', ['hello', '!doc 4', 'again']);
  await openChat(app, 'Below');
  await expect(app.locator('[data-tau-row="assistant"]').filter({ hasText: 'You said: again' })).toBeVisible();
  await settled(app);
  await scrollBy(app, -5000);
  await settled(app);
  await expect.poll(() => list(app).evaluate((element) => element.scrollTop)).toBeLessThan(5);
  // Web A knows it is away from the end (else a message from elsewhere would take it there, as at the end)
  await expect(app.getByRole('button', { name: 'Go to bottom' })).toBeVisible();
  await api.send(id, 'landing below');
  const row = app.locator('.chat-list .ListItem').filter({ hasText: 'Below' });
  await expect(row.getByText('1', { exact: true }).filter({ visible: true })).toHaveCount(1);
  await list(app).evaluate((element) => element.scrollTo({ top: element.scrollHeight }));
  await expect(row.getByText('1', { exact: true }).filter({ visible: true })).toHaveCount(0);
});
