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
