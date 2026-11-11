// Edits (docs/sending.md "Edits and drafts"): Edit on the user's message (its right-click menu, or Up in an empty field)
// puts it in the field; sending forks the chat before it with the new text, the fork opening in the chat's place. The
// original stays as it was. Until the fork exists, its draft shows the original up to the edit and the new message.
import type { Page, WebSocketRoute } from '@playwright/test';

import type { Dialog } from '../../client/src/protocol.ts';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';
const answers = '[data-tau-row="assistant"]:not([data-tau-draft])';
const own = (app: Page, text: string | RegExp) => app.locator('.Message.own').filter({ hasText: text });
const listItems = (app: Page, title: string) => app.locator('.chat-list .ListItem')
  .filter({ has: app.locator('.fullName').getByText(title, { exact: true }) });

async function editTo(app: Page, from: string, to: string) {
  await own(app, from).click({ button: 'right' });
  await app.locator('.tau-message-menu .MenuItem').filter({ hasText: 'Edit' }).click();
  await expect(app.locator(field)).toHaveText(from);
  // Typed, as a user does (Playwright's fill makes rich content Web A sends as a new message)
  await app.locator(field).click();
  await app.keyboard.press('ControlOrMeta+A');
  await app.keyboard.type(to);
  // Web A's composer has what was typed a frame after the field shows it
  await expect(app.locator(field)).toHaveText(to);
  await app.evaluate(() => new Promise((done) => {
    requestAnimationFrame(() => requestAnimationFrame(done));
  }));
  await app.keyboard.press('Enter');
}

test('Edit forks the chat before the message; the fork opens with the answer, the original stays', async ({ app, api }) => {
  const id = await api.chat('Edit fork', ['first question', 'second question', 'third question']);
  await listItems(app, 'Edit fork').click();
  await editTo(app, 'second question', 'second question, rephrased');
  await expect(app.locator(answers).filter({ hasText: 'You said: second question, rephrased' })).toBeVisible();
  await expect(own(app, 'first question')).toBeVisible();
  await expect(own(app, 'third question')).toHaveCount(0);
  await expect(own(app, /^second question$/)).toHaveCount(0);
  // A conversation of its own, beside the original, in the list
  await expect(listItems(app, 'Edit fork')).toHaveCount(2);
  const { dialogs } = await api.client.request('dialogs.subscribe', {});
  const forks = (dialogs as Dialog[]).filter((dialog) => dialog.title === 'Edit fork' && dialog.conversation.id !== id);
  expect(forks).toHaveLength(1);

  await listItems(app, 'Edit fork').filter({ hasText: 'third question' }).click();
  await expect(own(app, 'third question')).toBeVisible();
  await expect(own(app, 'second question, rephrased')).toHaveCount(0);
});

test('Up in an empty field edits the last message', async ({ app, api }) => {
  await api.chat('Edit up', ['one', 'two']);
  await listItems(app, 'Edit up').click();
  await expect(own(app, 'two')).toBeVisible();
  await app.locator(field).click();
  await app.keyboard.press('ArrowUp');
  await expect(app.locator(field)).toHaveText('two');
  await expect(app.locator('.ComposerEmbeddedMessage')).toContainText('Edit message');
});

test('offline, the fork\'s draft shows the original up to the edit and the new message on its way', async ({ app, api }) => {
  let current: WebSocketRoute | undefined;
  let isAway = false;
  await app.routeWebSocket(/\/socket$/, (socket) => {
    if (isAway) {
      void socket.close();
      return;
    }
    current = socket;
    socket.connectToServer();
  });
  await api.chat('Edit away', ['alpha', 'beta']);
  await app.reload();
  await listItems(app, 'Edit away').click();
  await expect(own(app, 'beta')).toBeVisible();
  isAway = true;
  await current!.close();
  await expect(app.locator('.MiddleHeader')).toContainText('connecting');

  await editTo(app, 'beta', 'beta, edited');
  await expect(own(app, 'beta, edited').locator('.icon-message-pending')).toBeVisible();
  await expect(own(app, 'alpha')).toBeVisible();
  await expect(app.locator(answers).filter({ hasText: 'You said: alpha' })).toBeVisible();
  await expect(own(app, /^beta$/)).toHaveCount(0);
  // In the list, at the top with its clock, as the chat open
  const draftRow = listItems(app, 'Edit away').filter({ hasText: 'beta, edited' });
  await expect(draftRow).toHaveClass(/selected/);
  await expect(draftRow.locator('.icon-message-pending')).toBeVisible();

  isAway = false;
  await expect(app.locator(answers).filter({ hasText: 'You said: beta, edited' })).toBeVisible({ timeout: 15_000 });
  await expect(own(app, 'beta, edited')).toHaveCount(1);
  // The draft's row gave way to the fork's: the original and the fork
  await expect(listItems(app, 'Edit away')).toHaveCount(2);
  await expect(listItems(app, 'Edit away').filter({ hasText: 'You said: beta, edited' })).toHaveClass(/selected/);
});

test('editing the first message starts a new chat with the chat\'s model', async ({ app, api }) => {
  const id = await api.chat('Edit first', ['only message']);
  await api.client.request('conversation.configure', {
    conversationId: id, agent: { model: { provider: 'dev', modelId: 'parrot' } },
  });
  await listItems(app, 'Edit first').click();
  await editTo(app, 'only message', 'only message, edited');
  await expect(app.locator(answers).filter({ hasText: 'You said: only message, edited' })).toContainText('dev/parrot');
});
