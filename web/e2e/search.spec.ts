// Search (e86fb01, docs/search.md "In the app"): the chat list's field finds chats by title at once, then the servers'
// messages, best first, each the chat, when, and its excerpt with the words marked; a result opens its chat at the
// message, the words marked in it. A chat's own search lists its matches, newest first, and goes to each.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const answers = '[data-tau-row="assistant"]:not([data-tau-draft])';

/** How many found words tau's rows mark (the CSS Custom Highlight API's ranges) */
const marked = (app: Page) => app.evaluate(() => (CSS as any).highlights?.get('tau-search')?.size ?? 0);

test('the chat list\'s search: chats by title, then messages with their words marked; a result opens at it', async ({ app, api }) => {
  await api.chat('Quokka plans', ['nothing to see']);
  const garden = await api.chat('Garden', ['plant tulips', 'a quokka visited the garden', 'water weekly']);
  // Archived, and the page loaded again: Web A has none of its messages (it preloads the main list's), so the result
  // is the server's excerpt until the chat opens
  await api.client.request('conversation.mark', { conversationId: garden, archived: true });
  await app.reload();
  await expect(app.locator('.chat-list .fullName').getByText('Quokka plans', { exact: true })).toBeVisible();
  await app.locator('#telegram-search-input').click();
  const search = app.locator('.LeftSearch');
  await expect(search).toBeVisible();
  await app.locator('#telegram-search-input').pressSequentially('quokka');
  // Telegram's tabs (channels, apps, posts) are not tau's
  await expect(search.locator('.left-search-tab-list')).toBeHidden();
  const chats = search.locator('.search-section').filter({ hasText: 'Chats' });
  await expect(chats).toContainText('Quokka plans');
  await expect(chats).not.toContainText('Garden');
  const results = search.locator('.ChatMessage');
  const found = results.filter({ hasText: 'Garden' }).first();
  await expect(found).toContainText('quokka visited the garden');
  await expect(found.locator('.matching-text-highlight').first()).toHaveText(/quokka/i);
  // In tau's pink, not Telegram's blue
  await expect(found.locator('.matching-text-highlight').first())
    .toHaveCSS('background-color', 'rgba(235, 108, 164, 0.25)');

  await found.click();
  await expect(app.locator('.MiddleHeader')).toContainText('Garden');
  // The chat's own rows in the found entry's place, not the excerpt; its words marked
  await expect(app.locator(answers).filter({ hasText: 'You said: a quokka visited the garden' })).toBeVisible();
  await expect.poll(() => marked(app)).toBeGreaterThan(0);
  // The user's own bubble, the hit itself, marked too
  await expect(app.locator('.Message.own').filter({ hasText: 'a quokka visited the garden' })
    .locator('.matching-text-highlight')).toHaveText('quokka');
  // Closed, the marks go
  await app.locator('#LeftColumn').getByRole('button', { name: 'Return to chat list' }).click();
  await expect.poll(() => marked(app)).toBe(0);
});

test('a chat\'s own search lists its matches newest first and goes to each', async ({ app, api }) => {
  await api.chat('Own search', ['the axolotl sleeps', 'nothing here', 'one more axolotl fact', 'filler']);
  await app.locator('.chat-list .fullName').getByText('Own search', { exact: true }).click();
  await app.locator('.MiddleHeader button[aria-label*="Search"]').first().click();
  await expect(app.locator('#MiddleSearch input')).toBeFocused();
  await app.keyboard.type('axolotl');
  await app.keyboard.press('Enter');
  const results = app.locator('#MiddleSearch .MiddleSearchResult');
  await expect(results.first()).toContainText('one more axolotl fact');
  await expect(results.last()).toContainText('the axolotl sleeps');
  // No jump to a date: tau's history cannot
  await expect(app.locator('#MiddleColumn button[aria-label="Jump to Date"]')).toBeHidden();
  await results.last().click();
  await expect(app.locator('.Message.own').filter({ hasText: 'the axolotl sleeps' })
    .locator('.matching-text-highlight')).toHaveText('axolotl');
  await expect.poll(() => marked(app)).toBeGreaterThan(0);
});

test('an empty search shows the most recently active chats', async ({ app, api }) => {
  await api.chat('Older recent', ['hello']);
  await api.chat('Newest recent', ['hello']);
  await expect(app.locator('.chat-list .fullName').getByText('Newest recent', { exact: true })).toBeVisible();
  await app.locator('#telegram-search-input').click();
  const recent = app.locator('.LeftSearch .search-section').filter({ hasText: 'Recent' });
  await expect(recent.locator('.ListItem').first()).toContainText('Newest recent');
  await expect(recent.locator('.ListItem').nth(1)).toContainText('Older recent');
});
