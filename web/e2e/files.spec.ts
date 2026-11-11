// A user's photos and files (docs/files.md, docs/media.md): shown from the entry as Telegram shows media, an album for
// several, loaded from the server's files with the token.
import { readFile } from 'node:fs/promises';
import { deflateSync } from 'node:zlib';

import type { Page } from '@playwright/test';

import { expect, test } from './fixtures.ts';

/** A PNG of one color, `width` by `height` */
function png(width: number, height: number, rgb: [number, number, number]) {
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (bytes: Buffer) => {
    let c = 0xffffffff;
    for (const byte of bytes) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type: string, data: Buffer) => {
    const body = Buffer.concat([Buffer.from(type), data]);
    const out = Buffer.alloc(body.length + 8);
    out.writeUInt32BE(data.length, 0);
    body.copy(out, 4);
    out.writeUInt32BE(crc(body), body.length + 4);
    return out;
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array.from({ length: width }, () => rgb).flat())]);
  const pixels = deflateSync(Buffer.concat(Array.from({ length: height }, () => row)));
  return new Uint8Array(Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header), chunk('IDAT', pixels), chunk('IEND', Buffer.alloc(0)),
  ]));
}

async function openChat(app: Page, title: string) {
  await app.locator('.chat-list .fullName').getByText(title, { exact: true }).click();
  await expect(app.locator('#editable-message-text')).toBeVisible();
}

test('two photos and a file: an album of the photos with the caption, the file as a document', async ({ app, api }) => {
  const id = await api.chat('Files', []);
  const red = await api.upload('red.png', png(40, 30, [220, 40, 40]));
  const blue = await api.upload('blue.png', png(30, 40, [40, 40, 220]));
  const notes = await api.upload('notes.txt', new TextEncoder().encode('some notes\n'));
  await api.send(id, 'look at these', {
    attachments: [{ id: red, as: 'image' }, { id: blue, as: 'image' }, { id: notes, as: 'file' }],
  });
  await openChat(app, 'Files');
  const album = app.locator('.Message.own .Album');
  await expect(album.locator('img.full-media')).toHaveCount(2);
  await expect(album.locator('img.full-media').first()).toHaveAttribute('src', /^blob:/);
  await expect(app.locator('.Message.own').filter({ hasText: 'look at these' })).toBeVisible();
  const file = app.locator('.Message.own .File').filter({ hasText: 'notes.txt' });
  await expect(file).toBeVisible();
  await expect(file).toContainText(/11(\.0)? ?B/);
  // A tap on the file saves it, as it is
  const download = app.waitForEvent('download');
  await file.locator('.file-icon-container, .file-preview').first().click();
  const saved = await download;
  expect(saved.suggestedFilename()).toBe('notes.txt');
  expect(await readFile(await saved.path(), 'utf8')).toBe('some notes\n');
  // The chat list reads it as the server's summary does
  await expect(app.locator('.chat-list .ListItem').filter({ hasText: 'Files' })).toBeVisible();
  // The media viewer opens the photo, loaded the same way
  // Once Web A's loading rings have faded out; a click on the photo lands on its container, as a user's
  await expect(app.locator('.media-loading')).toHaveCount(0);
  await album.locator('.media-inner').first().click();
  await expect(app.locator('#MediaViewer img').first()).toHaveAttribute('src', /^blob:/);
});

test('photos and a file sent from the composer: uploaded, one message each, the album once', async ({ app, api }) => {
  await api.chat('Send files', ['hello']);
  await openChat(app, 'Send files');
  // Photos: the paperclip's Photo or Video, Web A's attachment modal, a caption, Send
  await app.getByRole('button', { name: 'Add attachment' }).hover();
  // What tau sends: photos and files, nothing else of Telegram's (music, checklists, dates, articles)
  await expect(app.locator('.AttachMenu .MenuItem')).toHaveText(['Photo or Video', 'File']);
  const chooser = app.waitForEvent('filechooser');
  await app.locator('.AttachMenu .MenuItem').filter({ hasText: /Photo/ }).click();
  await (await chooser).setFiles([
    { name: 'green.png', mimeType: 'image/png', buffer: Buffer.from(png(64, 48, [40, 200, 40])) },
    { name: 'gray.png', mimeType: 'image/png', buffer: Buffer.from(png(48, 64, [128, 128, 128])) },
  ]);
  const modal = app.locator('.modal-dialog').filter({ hasText: 'Send 2 Photos' });
  await expect(modal).toBeVisible();
  await modal.getByRole('textbox').click();
  await app.keyboard.type('two photos');
  await app.keyboard.press('Enter');
  // The model got both, as images, with the caption
  const thinking = app.locator('[data-tau-part="thinking"]').last();
  await expect(thinking).toContainText('two photos');
  await expect(app.locator('[data-tau-row="assistant"]:not([data-tau-draft])').last()).toContainText('[image][image]');
  await expect(app.locator('.Message.own .Album img.full-media')).toHaveCount(2);
  await expect(app.locator('.Message.own').filter({ hasText: 'two photos' })).toHaveCount(1);
  await expect(app.locator('.Message.own').filter({ hasText: 'two photos' }).locator('.icon-message-read')).toBeVisible();

  // A file: the paperclip's File, sent as it is
  await app.getByRole('button', { name: 'Add attachment' }).hover();
  const fileChooser = app.waitForEvent('filechooser');
  await app.locator('.AttachMenu .MenuItem').filter({ hasText: 'File' }).click();
  await (await fileChooser).setFiles([{ name: 'plan.md', mimeType: 'text/markdown', buffer: Buffer.from('# Plan\n') }]);
  await expect(app.locator('.modal-dialog').filter({ hasText: 'plan.md' })).toBeVisible();
  await app.keyboard.press('Enter');
  await expect(app.locator('[data-tau-row="assistant"]:not([data-tau-draft])').last()).toContainText('[plan.md]');
  const file = app.locator('.Message.own .File').filter({ hasText: 'plan.md' });
  await expect(file).toHaveCount(1);
  await expect(file.locator('xpath=ancestor::*[contains(@class,"Message")][1]').locator('.icon-message-read'))
    .toBeVisible();
  await app.screenshot({ path: '/tmp/tau-shots/web-walk/8-sent-files.png' });
});
