// Notifications (6d5df3a, docs/notifications.md; iOS: Telegram's in-app banners): an answer becomes a system
// notification once its run ends, for a chat not on screen, or any while the window is in the background; a click
// opens the chat. What came before the page loaded does not notify. The page tells the server whether the user looks
// at it (`client.presence`), so the phone gets a push only while no app is in the foreground.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

type Shown = { title: string; body?: string; tag?: string };

const listItem = (app: Page, title: string) => app.locator('.chat-list .ListItem')
  .filter({ has: app.locator('.fullName').getByText(title, { exact: true }) });

/** The browser's Notification as a recorder, permission granted; `__away` makes the window lose focus */
async function spyNotifications(app: Page) {
  await app.context().addInitScript(() => {
    const shown: (Shown & { onclick?: () => void })[] = [];
    Object.assign(window, { __shown: shown });
    class Recorded {
      static permission = 'granted';
      static requestPermission = () => Promise.resolve('granted');
      onclick?: () => void;
      onshow?: () => void;
      constructor(title: string, options: NotificationOptions = {}) {
        const record = { title, body: options.body, tag: options.tag, click: () => this.onclick?.() };
        shown.push(record);
      }
      close() {}
    }
    Object.assign(window, { Notification: Recorded });
    const hasFocus = document.hasFocus.bind(document);
    document.hasFocus = () => !(window as unknown as { __away?: boolean }).__away && hasFocus();
  });
  await app.reload();
}

const shown = (app: Page) => app.evaluate(() => (window as unknown as { __shown: Shown[] }).__shown
  .map(({ title, body, tag }) => ({ title, body, tag })));

async function goAway(app: Page) {
  await app.evaluate(() => {
    (window as unknown as { __away: boolean }).__away = true;
    window.dispatchEvent(new Event('blur'));
  });
}

test('an answer in another chat notifies once its run ends; a click opens the chat', async ({ app, api }) => {
  await api.chat('Open here', ['hello']);
  const other = await api.chat('Elsewhere', ['hello']);
  await spyNotifications(app);
  await listItem(app, 'Open here').click();
  await expect(app.locator('.MiddleHeader')).toContainText('Open here');
  // A tool round, then the answer: one notification, for the answer
  await api.send(other, '$ echo from the shell');
  await expect.poll(() => shown(app)).toHaveLength(1);
  const [notification] = await shown(app);
  expect(notification.title).toBe('Elsewhere');
  expect(notification.body).toBe('Ran it: from the shell');
  await app.evaluate(() => (window as unknown as { __shown: { click(): void }[] }).__shown[0].click());
  await expect(app.locator('.MiddleHeader')).toContainText('Elsewhere');
});

test('the open chat notifies only while the window is in the background', async ({ app, api }) => {
  const id = await api.chat('Looking', ['hello']);
  await spyNotifications(app);
  await listItem(app, 'Looking').click();
  await api.send(id, 'while looking');
  await expect(app.locator('.MessageList').getByText('You said: while looking')).toBeVisible();
  await expect.poll(async () => (await api.client.request<{ dialogs: { title?: string; unreadCount: number }[] }>(
    'dialogs.subscribe', {})).dialogs.find((dialog) => dialog.title === 'Looking')?.unreadCount).toBe(0);
  // Read by looking at it: no badge, no notification
  expect(await shown(app)).toEqual([]);
  await goAway(app);
  await api.send(id, 'while away');
  await expect.poll(() => shown(app)).toEqual([expect.objectContaining({ title: 'Looking' })]);
});

test('what came before the page loaded does not notify', async ({ app, api }) => {
  await api.chat('Before notifying', ['hello']);
  await spyNotifications(app);
  await expect(listItem(app, 'Before notifying')).toBeVisible();
  const later = await api.chat('After', ['hello']);
  // A chat new since the page loaded tells of its answer; the one before stays quiet
  await expect.poll(() => shown(app)).toEqual([expect.objectContaining({ title: 'After' })]);
  void later;
});

test('the page tells the server whether the user looks at it', async ({ app }) => {
  const presence: boolean[] = [];
  app.on('websocket', (socket) => socket.on('framesent', ({ payload }) => {
    const match = /"client\.presence".*"active":(true|false)/.exec(String(payload));
    if (match) presence.push(match[1] === 'true');
  }));
  await app.reload();
  await expect.poll(() => presence).toEqual([true]);
  await app.evaluate(() => {
    document.hasFocus = () => false;
    window.dispatchEvent(new Event('blur'));
  });
  await expect.poll(() => presence).toEqual([true, false]);
});

test('Settings > Notifications: answers and their sound, nothing of Telegram\'s chat kinds', async ({ app }) => {
  await app.locator('#LeftMainHeader .DropdownMenu button').first().click();
  await app.locator('.MenuItem').filter({ hasText: 'Settings' }).click();
  await app.locator('.settings-main-scroll .ListItem').filter({ hasText: 'Notifications' }).first().click();
  await expect(app.locator('.settings-content').getByText('Answers', { exact: true })).toBeVisible();
  await expect(app.locator('.settings-content')).toContainText('Sound');
  await expect(app.locator('.settings-content')).not.toContainText('Offline');
  await expect(app.locator('.settings-content')).not.toContainText('Groups');
});
