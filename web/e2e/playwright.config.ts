// The web app's end-to-end tests (docs/web.md "Tests, fast"): the built app (scripts/web/build.sh), each worker with a
// dev tau server of its own (fixtures.ts), headless Chromium.
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.ts',
  fullyParallel: true,
  workers: Number(process.env.TAU_E2E_WORKERS ?? 12),
  timeout: 30_000,
  expect: { timeout: 10_000 },
  reporter: process.env.CI ? 'line' : [['list']],
  outputDir: '/tmp/tau-web-e2e',
  use: {
    browserName: 'chromium',
    headless: true,
    viewport: { width: 1280, height: 800 },
    // The insecure-origin test reaches the server by a name that is not localhost
    launchOptions: { args: ['--host-resolver-rules=MAP tau-e2e.test 127.0.0.1'] },
  },
});
