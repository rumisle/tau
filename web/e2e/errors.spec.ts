// Model errors (a530b86; pi's retries): while the server asks the model again, the τ says when and why; an answer
// after errors says it was retried, and the failed attempts do not show; an error the run ends on is a card with
// Retry, which sends the message before it again.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';
const answers = '[data-tau-row="assistant"]:not([data-tau-draft])';

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator(field)).toBeVisible();
}

async function type(app: Page, text: string) {
  await app.locator(field).click();
  await app.keyboard.type(text);
  await app.keyboard.press('Enter');
}

test('an overloaded provider: the τ says it retries, the answer says it was retried 2 times, no failed attempt shows', async ({ app, api }) => {
  await api.chat('Overloaded', ['hello']);
  await openChat(app, 'Overloaded');
  // The dev model fails twice as an overloaded provider, then answers
  await type(app, '!overloaded 2 at last');
  await expect(app.locator('[data-tau-part="retry"]')).toContainText(/retrying( in \ds)?: overloaded/);
  const answer = app.locator(answers).filter({ hasText: 'You said: !overloaded 2 at last' });
  await expect(answer.locator('[data-tau-part="footer"]')).toContainText('worked for');
  await expect(answer.locator('[data-tau-part="footer"]')).toContainText('retried 2 times');
  await expect(app.locator('[data-tau-part="retry"]')).toHaveCount(0);
  await expect(app.locator('.MessageList').last()).not.toContainText('Overloaded');
  await expect(app.locator('[data-tau-part="error"]')).toHaveCount(0);
});

test('an error the run ends on is a card; Retry sends the message again', async ({ app, api }) => {
  await api.chat('Fatal', ['hello']);
  await openChat(app, 'Fatal');
  await type(app, '!fatal no key');
  const card = app.locator('[data-tau-part="error"]');
  await expect(card).toContainText('The model failed');
  await expect(card).toContainText('401: invalid x-api-key');
  // What it wrote before the error stays above the card
  await expect(app.locator(answers).filter({ has: card })).toContainText('Let me look');
  await card.getByRole('button', { name: 'Retry' }).click();
  await expect(app.locator('.Message.own').filter({ hasText: '!fatal no key' })).toHaveCount(2);
  await expect(card).toHaveCount(2);
});
