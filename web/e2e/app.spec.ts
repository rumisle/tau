// The proof of concept's client, tested: signing in, the chat list, a transcript drawn as tau's rows, an answer that
// comes while the chat is open, the page for plain HTTP, and the look's numbers from ios/Tau/Chat/ChatMessageItem.swift.
import type { Page } from '@playwright/test';

import { expect, test, TOKEN } from './fixtures.ts';

const row = '[data-tau-row="assistant"]';

function openChat(app: Page, title: string) {
  return app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
}

test('a #token= link signs in, and leaves the address bar', async ({ app, api }) => {
  await api.chat('Link sign-in', ['hello from the link test']);
  await expect(app.locator('.chat-list').getByText('Link sign-in')).toBeVisible();
  expect(new URL(app.url()).hash).toBe('');
});

test('without a token the connect screen asks; a wrong one is refused, the right one opens the list', async ({ page, server, api }) => {
  await api.chat('Connect screen', ['hi']);
  await page.goto(server.origin);
  const screen = page.locator('[data-tau-connect]');
  await expect(screen).toHaveAttribute('data-tau-connect', 'needsToken');
  await page.locator('#tau-token').fill('not-the-token-at-all');
  await page.getByRole('button', { name: 'Connect' }).click();
  await expect(screen).toHaveAttribute('data-tau-connect', 'wrongToken');
  await expect(page.getByText('The server did not take this token.')).toBeVisible();
  await page.locator('#tau-token').fill(TOKEN);
  await page.getByRole('button', { name: 'Connect' }).click();
  await expect(page.locator('.chat-list').getByText('Connect screen')).toBeVisible();
  // Kept: a reload signs in by itself
  await page.reload();
  await expect(page.locator('.chat-list').getByText('Connect screen')).toBeVisible();
});

test('a transcript: the user\'s bubbles, answers as tau\'s rows, thinking, a tool card with its output', async ({ app, api }) => {
  await api.chat('Transcript', ['hello transcript', '$ echo e2e-$((6*7))']);
  await openChat(app, 'Transcript');
  await expect(app.locator('.Message.own').getByText('hello transcript')).toBeVisible();
  const answer = app.locator(row).filter({ hasText: 'You said: hello transcript' });
  await expect(answer).toBeVisible();
  await expect(answer.locator('[data-tau-part="thinking"]')).toContainText('The user said');
  const card = app.locator('[data-tau-part="tool"]');
  await expect(card).toContainText('Bash');
  await expect(card).toContainText('e2e-42');
  await expect(card).toHaveAttribute('data-tau-status', 'done');
  await expect(app.locator(row).last().locator('[data-tau-part="footer"]')).toBeVisible();
});

test('an answer that comes while the chat is open streams in and stays', async ({ app, api }) => {
  const id = await api.chat('Live', ['first']);
  await openChat(app, 'Live');
  await expect(app.locator(row).filter({ hasText: 'You said: first' })).toBeVisible();
  await api.send(id, '!doc 2', { wait: false });
  // While it streams, a typing draft; then the answer in its place, once
  await expect(app.locator(row).filter({ hasText: 'Section 1' }).first()).toBeVisible();
  const answer = app.locator(row).filter({ hasText: 'Paragraph 2.2' });
  await expect(answer.locator('[data-tau-part="footer"]')).toBeVisible();
  await expect(app.locator('[data-tau-draft]')).toHaveCount(0);
  await expect(answer).toHaveCount(1);
});

test('plain HTTP away from localhost gets the page that says how to set up HTTPS', async ({ page, server }) => {
  await page.goto(`http://tau-e2e.test:${server.port}/`);
  await expect(page.getByRole('heading', { name: 'tau needs HTTPS here' })).toBeVisible();
  await expect(page.locator('pre')).toHaveText(`tailscale serve --bg ${server.port}`);
});

test('the look: answers at 17 px with iOS\'s line height, thinking at 15, cards with a 14 px radius', async ({ app, api }) => {
  await api.chat('Look', ['look', '$ echo look']);
  await openChat(app, 'Look');
  const text = app.locator(`${row} [data-tau-part="text"] p`).last();
  await expect(text).toBeVisible();
  const style = await text.evaluate((node) => {
    const computed = getComputedStyle(node);
    return { size: computed.fontSize, lineHeight: parseFloat(computed.lineHeight) };
  });
  expect(style.size).toBe('17px');
  expect(style.lineHeight).toBeCloseTo(17 * 1.47, 0);
  const thinking = app.locator('[data-tau-part="thinking"]').first();
  await expect(thinking).toHaveCSS('font-size', '15px');
  await expect(app.locator('[data-tau-part="tool"]').first()).toHaveCSS('border-radius', '14px');
});
