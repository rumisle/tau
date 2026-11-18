// Settings > Accounts (docs/accounts.md; iOS's Accounts tab), on the dev server's Dev Account provider, whose sign-in
// shows a device code and completes on its own: the code, the account in use with its usage, an API key put in use,
// the first switched back to from its right-click menu, the key signed out.
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
  const email = (await account.locator('.title').innerText()).replace('Max', '').trim();

  // Its window: a large bar per limit
  await account.click();
  await expect(modal).toContainText('5-Hour Limit');
  await expect(modal).toContainText('Weekly Limit');
  await expect(modal).toContainText(/Resets in 2h 1\dm/);
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

  // The first, back in use from its menu
  await content.locator('.ListItem').filter({ hasText: email }).click({ button: 'right' });
  await app.locator('.MenuItem').filter({ hasText: 'Use This Account' }).click();
  await expect(content.locator('.ListItem').filter({ hasText: email }).locator('[aria-label="in use"]')).toBeVisible();
  await expect(key.locator('[aria-label="in use"]')).toHaveCount(0);

  // The key, signed out
  await key.click({ button: 'right' });
  await app.locator('.MenuItem').filter({ hasText: 'Sign Out' }).click();
  await app.locator('.confirm-dialog-button').filter({ hasText: 'Sign Out' }).click();
  await expect(key).toHaveCount(0);
});
