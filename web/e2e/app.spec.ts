// The proof of concept's client, tested: signing in, the chat list, a transcript drawn as tau's rows, an answer that
// comes while the chat is open, the page for plain HTTP, and the look's numbers from ios/Tau/Chat/ChatMessageItem.swift.
import type { Page } from '@playwright/test';

import { expect, SMOKE, test, TOKEN } from './fixtures.ts';

const row = '[data-tau-row="assistant"]';

function openChat(app: Page, title: string) {
  return app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
}

test('a #token= link signs in, and leaves the address bar', SMOKE, async ({ app, api }) => {
  await api.chat('Link sign-in', ['hello from the link test']);
  await expect(app.locator('.chat-list').getByText('Link sign-in')).toBeVisible();
  expect(new URL(app.url()).hash).toBe('');
});

test('the page is tau\'s: its title, its τ icons, its manifest', async ({ app, server }) => {
  await expect(app).toHaveTitle('tau');
  const icons = await app.locator('link[rel~="icon"]').evaluateAll((links) => links.map((link) => link.getAttribute('href')));
  expect(icons.every((href) => href!.includes('/tau/'))).toBe(true);
  const manifestHref = await app.locator('link[rel="manifest"]').getAttribute('href');
  const manifest = await (await fetch(new URL(manifestHref!, `${server.origin}/`))).json() as { name: string; icons: { src: string }[] };
  expect(manifest.name).toBe('tau');
  for (const icon of manifest.icons) {
    expect((await fetch(new URL(`tau/${icon.src}`, `${server.origin}/`))).status).toBe(200);
  }
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

test('a transcript: the user\'s bubbles, answers, thinking, a tool card', SMOKE, async ({ app, api }) => {
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

test('an answer that comes while the chat is open streams in and stays', SMOKE, async ({ app, api }) => {
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

test('a card per tool: a file written, edited as a diff, read colored by its language', async ({ app, api }) => {
  await api.chat('Tool cards', [
    '!tool write {"path":"notes.ts","content":"export const x = 1;\\nexport const y = 2;"}',
    '!tool edit {"path":"notes.ts","edits":[{"oldText":"export const x = 1;","newText":"export const x = 3;"}]}',
    '!tool read path=notes.ts',
  ]);
  await openChat(app, 'Tool cards');
  const card = (tool: string) => app.locator(`[data-tau-tool="${tool}"]`);
  await expect(card('Write')).toContainText('notes.ts  2 lines');
  await expect(card('Edit')).toContainText('+1 −1');
  await expect(card('Edit').locator('[data-tau-diff="removed"]')).toContainText('export const x = 1;');
  await expect(card('Edit').locator('[data-tau-diff="added"]')).toContainText('export const x = 3;');
  await expect(card('Read')).toContainText('notes.ts  2 lines');
  // Colored by the file's language: highlight.js's spans, as in a code block
  await expect(card('Read').locator('[class*="hljs"], [class*="token"]').first()).toBeVisible();
});

test('desktop copying: a code block\'s copy button on hover; selection across answers and Ctrl+C; cards', async ({ app, api }) => {
  await app.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await api.chat('Copy code', ['$ echo copied-$((6*7))', 'hello']);
  await openChat(app, 'Copy code');
  const clipboard = () => app.evaluate(() => navigator.clipboard.readText());
  // A click on code is a click: it copies nothing
  await app.evaluate(() => navigator.clipboard.writeText('before'));
  const block = app.locator(row).filter({ hasText: 'Ran it' }).last().locator('.CodeBlock').first();
  await block.locator('pre').click();
  await app.locator(row).locator('p code').first().click();
  expect(await clipboard()).toBe('before');
  // Hovered, the block shows its copy button
  await block.hover();
  await block.getByTitle('Copy').click();
  expect((await clipboard()).trim()).toBe('copied-42');
  // A drag from one answer into the next selects across them; Ctrl+C copies it
  const first = app.locator(row).filter({ hasText: 'Ran it' }).last().locator('p').first();
  const second = app.locator(row).filter({ hasText: 'You said: hello' }).last().locator('p').first();
  const from = (await first.boundingBox())!;
  const to = (await second.boundingBox())!;
  await app.mouse.move(from.x + 1, from.y + from.height / 2);
  await app.mouse.down();
  await app.mouse.move(to.x + to.width - 2, to.y + to.height / 2, { steps: 8 });
  await app.mouse.up();
  await app.keyboard.press('ControlOrMeta+C');
  const copied = await clipboard();
  expect(copied).toContain('Ran it');
  expect(copied).toContain('copied-42');
  expect(copied).toContain('You said: hello');
  // A tool card opens on a click, but not on a drag that selects its text
  await app.evaluate(() => window.getSelection()?.removeAllRanges());
  const card = app.locator('[data-tau-part="tool"]').first();
  const box = (await card.locator('pre').boundingBox())!;
  await app.mouse.move(box.x + 2, box.y + 4);
  await app.mouse.down();
  await app.mouse.move(box.x + box.width / 2, box.y + box.height - 4, { steps: 5 });
  await app.mouse.up();
  expect(await app.evaluate(() => window.getSelection()?.toString())).toContain('echo copied');
  await expect(card).not.toHaveAttribute('data-tau-expanded');
  // A click on it (which ends the selection) opens it
  await card.locator('pre').click();
  await expect(card).toHaveAttribute('data-tau-expanded');
});

test('a chat that comes while the app syncs leaves no syncing spinner, and avatars have their colors', async ({ app, api }) => {
  // At once, as the page loads: Web A's sync had nothing left to load and waited 30 s for itself
  await api.chat('While syncing', ['hello']);
  const row = app.locator('.chat-list .ListItem').filter({ hasText: 'While syncing' });
  await expect(row).toBeVisible();
  await expect(app.locator('#LeftMainHeader .SearchInput .Loading')).toHaveCount(0);
  // Telegram's peer colors, which the sync loads: not the black of none
  await expect(row.locator('.Avatar .inner')).toHaveCSS('background-image', /linear-gradient/);
  await expect(row.locator('.Avatar .inner')).not.toHaveCSS('background-image', /rgb\(0, 0, 0\)\)$/);
});
