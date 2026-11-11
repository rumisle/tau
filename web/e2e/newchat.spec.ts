// New Chat (docs/sending.md "Edits and drafts"): a draft until its first message, then the conversation, opened in
// the draft's place and named after its first answer.
import { expect, test } from './fixtures.ts';

test('New Chat opens a draft; its first message creates the conversation, which opens with the answer', async ({ app, api }) => {
  await api.chat('Before', ['hello']);
  await expect(app.locator('.chat-list').getByText('Before', { exact: true })).toBeVisible();
  await app.locator('.chat-list').hover();
  await app.getByRole('button', { name: 'New Message' }).click();
  await expect(app.locator('.MiddleHeader').getByText('New Chat')).toBeVisible();
  await app.locator('#editable-message-text').click();
  await app.keyboard.type('the first message');
  await app.keyboard.press('Enter');
  await expect(app.locator('[data-tau-row="assistant"]:not([data-tau-draft])')
    .filter({ hasText: 'You said: the first message' })).toBeVisible();
  await expect(app.locator('.Message.own').filter({ hasText: 'the first message' })).toHaveCount(1);
  await expect(app.locator('.MiddleHeader').getByText('New Chat')).toBeHidden();
  // In the list, once, and the draft is not (the worker's server has other tests' chats too)
  await expect(app.locator('.chat-list .ListItem').filter({ hasText: 'You said: the first message' })).toHaveCount(1);
  await expect(app.locator('.chat-list .ListItem').filter({ hasText: 'New Chat' })).toHaveCount(0);
});
