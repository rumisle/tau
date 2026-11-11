// Settings > Usage (dd77100; iOS's UsageController): the span, the overview, the days by model with a metric to
// switch, the models and the costliest chats, which open on a click. The dev model is free, so tokens come first.
import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

async function openUsage(app: Page) {
  await app.locator('#LeftMainHeader .DropdownMenu button').first().click();
  await app.locator('.MenuItem').filter({ hasText: 'Settings' }).click();
  await app.locator('.settings-main-scroll .ListItem').filter({ hasText: 'Usage' }).click();
  await expect(app.locator('[data-tau-usage="ready"]')).toBeVisible();
}

test('Usage: the span, the overview, the days by model, the models and the chats that cost most', async ({ app, api }) => {
  await api.chat('Usage one', ['hello', 'again']);
  await api.chat('Usage two', ['hello']);
  await openUsage(app);
  const content = app.locator('[data-tau-usage="ready"]');
  // At least what this test's chats answered
  const answers = content.locator('[data-tau-usage-cell="Answers"]');
  await expect.poll(async () => Number((await answers.innerText()).split('\n')[0])).toBeGreaterThanOrEqual(3);
  // Free: tokens first, cost a click away
  const chart = content.locator('[data-tau-usage-chart]');
  await expect(chart).toContainText(/ in 30 days/);
  await chart.getByRole('button', { name: 'Cost' }).click();
  await expect(chart).toContainText('$0 in 30 days');
  await content.getByRole('tab', { name: '7 Days' }).click();
  await expect(chart).toContainText('$0 in 7 days');
  await expect(content.locator('.ListItem').filter({ hasText: 'echo' })).toContainText(/tokens, \d+ answers/);
  await expect(content).toContainText(/Input \d.*, output .*, cache read .*, cache write .*\./);
  // A chat of the costliest opens on a click
  const chat = content.locator('.tau-usage-chat').first();
  const title = (await chat.locator('.title').innerText()).trim();
  await chat.click();
  await expect(app.locator('.MiddleHeader')).toContainText(title);
});
