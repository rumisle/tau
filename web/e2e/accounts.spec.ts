// Settings > Accounts (docs/accounts.md; iOS's Accounts tab), on the dev server's Dev Account provider, whose sign-in
// shows a device code and completes on its own: the code, the account in use with its usage, an API key put in use
// with its limits in money, the first switched back to from its right-click menu, "in use" in the accent color, the key
// signed out.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

async function openAccounts(app: Page) {
  await app.locator('#LeftMainHeader .DropdownMenu button').first().click();
  await app.locator('.MenuItem').filter({ hasText: 'Settings' }).click();
  await app.locator('.settings-main-scroll .ListItem').filter({ hasText: 'Accounts' }).click();
  await expect(app.locator('[data-tau-accounts]')).toBeVisible();
}

test('Accounts: a device code sign-in, its usage, a key, switching and signing out', async ({ app }) => {
  await openAccounts(app);
  const content = app.locator('[data-tau-accounts]');
  await content.locator('.ListItem').filter({ hasText: 'Add Account' }).click();
  const modal = app.locator('.modal-dialog');
  await modal.locator('.ListItem').filter({ hasText: 'Dev (subscription)' }).click();
  await expect(modal.locator('[data-tau-login-code]')).toHaveText('DEVC-0DE1');
  await expect(modal).toContainText('Waiting for you to sign in');
  // It signs in on its own, a few seconds later: the modal closes, the account is in use
  await expect(modal).toHaveCount(0, { timeout: 15_000 });
  const account = content.locator('.ListItem').filter({ hasText: /dev\d+@example\.com/ }).last();
  await expect(account).toContainText('Max');
  await expect(account).toContainText('42%');
  await expect(account).toContainText('71%');
  const email = (await account.locator('.title').innerText()).trim();

  // Its window: a large bar per limit
  await account.click();
  await expect(modal).toContainText('5-Hour Limit');
  await expect(modal).toContainText('Weekly Limit');
  await expect(modal).toContainText(/Resets in 2h 1\dm/);
  await expect(modal.locator('.ListItem').filter({ hasText: 'Extra Usage' })).toContainText('$4.20 of $50.00 spent');
  await modal.getByRole('button', { name: 'Close' }).click();
  await expect(modal).toHaveCount(0);

  // A key: asked as a secret, put in use
  await content.locator('.ListItem').filter({ hasText: 'Add Account' }).click();
  await modal.locator('.ListItem').filter({ hasText: 'Dev API key' }).click();
  await modal.locator('input[type="password"]').fill('sk-dev-4321');
  await app.keyboard.press('Enter');
  await expect(modal).toHaveCount(0, { timeout: 10_000 });
  const key = content.locator('.ListItem').filter({ hasText: 'Key ending 4321' });
  await expect(key).toBeVisible();
  // Its limits: titled once, in money, saying nothing of resetting, and no extra usage
  await key.click();
  await expect(modal).toContainText('Key Limit');
  await expect(modal).not.toContainText('Key Key');
  await expect(modal).toContainText('$9.63 of $12.00 spent');
  await expect(modal).toContainText('$4.77 of $103.00 left');
  await expect(modal).not.toContainText('Credits Credits');
  await expect(modal).not.toContainText('Resets');
  await expect(modal).not.toContainText('Extra Usage');
  await modal.getByRole('button', { name: 'Close' }).click();
  await expect(modal).toHaveCount(0);

  // The first, back in use from its menu
  await content.locator('.ListItem').filter({ hasText: email }).click({ button: 'right' });
  await app.locator('.MenuItem').filter({ hasText: 'Use This Account' }).click();
  // The provider has two now: the one in use says so
  const first = content.locator('.ListItem').filter({ hasText: email });
  await expect(first).toContainText('Dev Account Max, in use');
  await expect(key).not.toContainText('in use');
  // "in use" alone in the accent color, the rest as it was
  const inUse = first.locator('[data-tau-in-use]');
  await expect(inUse).toHaveText('in use');
  const [accent, rest] = await first.evaluate((row) => [
    getComputedStyle(row.querySelector('[data-tau-in-use]')!).color,
    getComputedStyle(row.querySelector('.subtitle')!).color,
  ]);
  const primary = await app.evaluate(() => {
    const probe = document.createElement('span');
    probe.style.color = 'var(--color-primary)';
    document.body.append(probe);
    const color = getComputedStyle(probe).color;
    probe.remove();
    return color;
  });
  expect(accent).toBe(primary);
  expect(rest).not.toBe(primary);

  // The key, signed out
  await key.click({ button: 'right' });
  await app.locator('.MenuItem').filter({ hasText: 'Sign Out' }).click();
  await app.locator('.confirm-dialog-button').filter({ hasText: 'Sign Out' }).click();
  await expect(key).toHaveCount(0);
});
