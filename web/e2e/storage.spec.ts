// Settings > Data and Storage (e5e4bd8; iOS's DataStorageController): what tau keeps in this browser (unsent messages,
// drafts) and the socket's bytes to and from each server, with Reset Statistics.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

const listItem = (app: Page, title: string) => app.locator('.chat-list .ListItem')
  .filter({ has: app.locator('.fullName').getByText(title, { exact: true }) });

async function openDataAndStorage(app: Page) {
  await app.locator('#LeftMainHeader .DropdownMenu button').first().click();
  await app.locator('.MenuItem').filter({ hasText: 'Settings' }).click();
  await app.locator('.settings-main-scroll .ListItem').filter({ hasText: 'Data and Storage' }).click();
}

test('Data and Storage: drafts and unsent messages here, the bytes of each server, Reset Statistics', async ({ app, api, server }) => {
  await api.chat('Storage', ['hello']);
  await listItem(app, 'Storage').click();
  await app.locator('#editable-message-text').click();
  await app.keyboard.type('a draft kept here');
  // Another chat: Web A saves the draft as the chat changes
  await api.chat('Other', ['hello']);
  await listItem(app, 'Other').click();
  await expect(listItem(app, 'Storage')).toContainText('Draft:');

  await openDataAndStorage(app);
  const content = app.locator('.settings-content');
  const row = (name: string) => content.locator('.ListItem').filter({ hasText: name });
  await expect(row('Drafts')).not.toContainText('Zero KB');
  await expect(row('Drafts')).toContainText('bytes');
  // Nothing waits to be sent
  await expect(row('Unsent Messages')).toContainText('Zero KB');
  // Telegram's auto-download settings are not here
  await expect(content).not.toContainText('Auto-download');

  const host = `127.0.0.1:${server.port}`;
  await expect(row(host)).toContainText(/Sent \d+(\.\d)? (bytes|KB|MB), received \d+(\.\d)? (KB|MB)/);
  await row('Reset Statistics').click();
  await expect(row(host)).toContainText('Sent Zero KB, received Zero KB');
  await expect(content).toContainText('Since ');
});

test('Chat History is what the opened chats keep here; Clear Cache drops it', async ({ app, api }) => {
  await api.chat('History', ['keep this one']);
  await listItem(app, 'History').click();
  const answer = app.locator('[data-tau-row="assistant"]').filter({ hasText: 'You said: keep this one' });
  await expect(answer).toBeVisible();
  // Kept a moment after the chat loaded
  await expect.poll(() => app.evaluate(() => new Promise<number>((done) => {
    const request = indexedDB.open('tau-cache');
    request.onsuccess = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains('chats')) return done(0);
      const count = db.transaction('chats').objectStore('chats').count();
      count.onsuccess = () => done(count.result);
    };
  }))).toBeGreaterThan(2);
  await openDataAndStorage(app);
  const content = app.locator('.settings-content');
  const row = (name: string) => content.locator('.ListItem').filter({ hasText: name });
  await expect(row('Chat History')).not.toContainText('Zero KB');
  await row('Clear Cache').click();
  await app.locator('.confirm-dialog-button').filter({ hasText: /^Clear / }).click();
  await expect(app.locator('.Notification')).toContainText('cleared');
  await expect(row('Chat History')).toContainText('Zero KB');
  await expect(row('Clear Cache')).toContainText('Zero KB');
});
