// The web app's icons from the iOS app's (ios/scripts/make_icon.swift): ChatWaitingNode's τ in white on pink, light at
// the top; full bleed for Apple's touch icon and the manifest's maskable one, which their systems round, a rounded
// square elsewhere; the favicon's unread variant with Telegram's dot (Web A's util/updateIcon.ts swaps the file).
// Writes web/public/tau/. Usage: node scripts/web/icons.mjs (uses web/e2e's Playwright Chromium)
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const out = join(root, 'web/public/tau');
const { chromium } = await import(join(root, 'web/e2e/node_modules/playwright/index.mjs'));

const TAU = 'M3.2 10Q3.9 6.7 7 6.6L20.6 6.6M12.6 6.6L11.9 15.2Q11.5 19.7 16.6 19.4';

/** The icon in a 1024 box, its corners rounded as iOS's (22.5%) unless full bleed, with Telegram's unread dot */
function svg({ isRounded = true, hasDot = false } = {}) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">`
    + '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
    + '<stop offset="0" stop-color="#FF8DBF"/><stop offset="1" stop-color="#EC4A8B"/></linearGradient></defs>'
    + `<rect width="1024" height="1024" rx="${isRounded ? 230 : 0}" fill="url(#bg)"/>`
    + `<path d="${TAU}" transform="translate(155 111.5) scale(30)" fill="none" stroke="#fff" stroke-width="2.4"`
    + ' stroke-linecap="round" stroke-linejoin="round"/>'
    + (hasDot ? '<circle cx="864" cy="160" r="160" fill="#F72A0F"/>' : '')
    + '</svg>';
}

writeFileSync(join(out, 'favicon.svg'), svg());
writeFileSync(join(out, 'favicon-unread.svg'), svg({ hasDot: true }));

const browser = await chromium.launch();
const page = await browser.newPage();
async function png(name, size, options) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{width:${size}px;height:${size}px;display:block}</style>${svg(options)}`);
  writeFileSync(join(out, name), await page.screenshot({ omitBackground: true }));
}
await png('favicon-16x16.png', 16);
await png('favicon-32x32.png', 32);
await png('favicon-unread-16x16.png', 16, { hasDot: true });
await png('favicon-unread-32x32.png', 32, { hasDot: true });
await png('icon-192x192.png', 192);
await png('icon-512x512.png', 512);
await png('icon-maskable-512x512.png', 512, { isRounded: false });
await png('apple-touch-icon.png', 180, { isRounded: false });
await browser.close();
