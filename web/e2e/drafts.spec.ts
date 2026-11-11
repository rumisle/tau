// The streamed answer (Telegram's typing draft) goes when its message lands, whatever the timing: the answer is never
// shown twice, not even for a moment (a stale draft lingered a second after the entry once, and was in a screenshot).
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const field = '#editable-message-text';
const final = '[data-tau-row="assistant"]:not([data-tau-draft])';

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator(field)).toBeVisible();
}

async function type(app: Page, text: string) {
  await app.locator(field).click();
  await app.keyboard.type(text);
  await app.keyboard.press('Enter');
}

/**
 * Watches the message list from now on, each animation frame: how long, at most, a draft showed an answer that was in
 * the chat already. The same answer: the draft's text starts a final row's that came after the watch started, and has
 * at least half of it (the next run's draft, which starts at once, is another answer)
 */
function watchOverlap(app: Page) {
  return app.evaluate(() => {
    const textsOf = (selector: string) => [...document.querySelectorAll(selector)]
      .map((row) => (row.textContent ?? '').trim()).filter(Boolean);
    const before = new Set(textsOf('[data-tau-row="assistant"]:not([data-tau-draft])'));
    const state = { overlap: 0, since: 0 };
    (window as any).tauOverlap = state;
    const tick = () => {
      const finals = textsOf('[data-tau-row="assistant"]:not([data-tau-draft])').filter((text) => !before.has(text));
      const isShownTwice = textsOf('[data-tau-draft]').some((draft) => finals
        .some((final) => final.startsWith(draft) && draft.length * 2 >= final.length));
      if (isShownTwice) {
        if (!state.since) state.since = performance.now();
        state.overlap = Math.max(state.overlap, performance.now() - state.since);
      } else {
        state.since = 0;
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

async function expectNoOverlap(app: Page) {
  await expect(app.locator('[data-tau-draft]')).toHaveCount(0);
  // A frame or two while Web A swaps them, never the second it took with the Stopped's deleting animation
  expect(await app.evaluate(() => (window as any).tauOverlap.overlap)).toBeLessThan(150);
}

test('a streamed answer: the draft goes as its message lands', async ({ app, api }) => {
  await api.chat('Draft plain', ['hello']);
  await openChat(app, 'Draft plain');
  await watchOverlap(app);
  await type(app, '!doc 2');
  await expect(app.locator(final).filter({ hasText: 'Paragraph 2.2' })).toBeVisible();
  await expectNoOverlap(app);
  await expect(app.locator(final).filter({ hasText: 'Paragraph 2.2' })).toHaveCount(1);
});

test('a run of several generations (a tool between): each draft goes with its message', async ({ app, api }) => {
  await api.chat('Draft tool', ['hello']);
  await openChat(app, 'Draft tool');
  await watchOverlap(app);
  await type(app, '$ echo draft-$((40+2))');
  await expect(app.locator('[data-tau-part="tool"]').filter({ hasText: 'draft-42' })).toBeVisible();
  await expect(app.locator(final).last().locator('[data-tau-part="footer"]')).toBeVisible();
  await expectNoOverlap(app);
});

test('two runs back to back, and a message with a file uploaded first', async ({ app, api }) => {
  const id = await api.chat('Draft quick', ['hello']);
  await openChat(app, 'Draft quick');
  await watchOverlap(app);
  await api.send(id, 'first quick', { wait: false });
  await api.send(id, 'second quick', { wait: false });
  await expect(app.locator(final).filter({ hasText: 'You said: second quick' })).toBeVisible();
  await expectNoOverlap(app);
  await expect(app.locator(final).filter({ hasText: 'You said: first quick' })).toHaveCount(1);
  await expect(app.locator(final).filter({ hasText: 'You said: second quick' })).toHaveCount(1);

  await app.getByRole('button', { name: 'Add attachment' }).hover();
  const chooser = app.waitForEvent('filechooser');
  await app.locator('.AttachMenu .MenuItem').filter({ hasText: 'File' }).click();
  await (await chooser).setFiles([{ name: 'draft.md', mimeType: 'text/markdown', buffer: Buffer.from('# Draft\n') }]);
  const modal = app.locator('.modal-dialog').filter({ hasText: 'draft.md' });
  await modal.getByRole('textbox').click();
  await app.keyboard.press('Enter');
  await expect(app.locator(final).filter({ hasText: 'You said: [draft.md]' })).toBeVisible();
  await expectNoOverlap(app);
});

test('a reload while the answer streams: once it lands, the answer once and no draft', async ({ app, api }) => {
  const id = await api.chat('Draft reload', ['hello']);
  await openChat(app, 'Draft reload');
  await api.send(id, '!doc 6', { wait: false });
  await expect(app.locator('[data-tau-draft]')).toHaveCount(1);
  await app.reload();
  await openChat(app, 'Draft reload');
  await expect(app.locator(final).filter({ hasText: 'Paragraph 6.' }).last()).toBeVisible();
  await expect(app.locator(final).last().locator('[data-tau-part="footer"]')).toBeVisible({ timeout: 20_000 });
  await expect(app.locator('[data-tau-draft]')).toHaveCount(0);
  await expect(app.locator(final).filter({ hasText: 'Section 6' })).toHaveCount(1);
});
