import { describe, expect, it } from 'vitest';

import {
  buildMediaRows, keptUploadsOf, mediaSource, parseAttachments, readUserContent,
} from './attachments';

const ID_A = '7f3a'.padEnd(32, '0');
const ID_B = 'a81c'.padEnd(32, '1');
const BLOCK = `<attachments>
<image name="/data/tau.files/${ID_A}/IMG &amp; co.jpg" type="image/jpeg" bytes="812044" width="2000" height="1500"/>
<file name="/data/tau.files/${ID_B}/report.pdf" type="application/pdf" bytes="1204331"/>
</attachments>`;

describe('attachments', () => {
  it('reads the server\'s block, and nothing that is not exactly one', () => {
    expect(parseAttachments(BLOCK)).toEqual([
      {
        kind: 'image', path: `/data/tau.files/${ID_A}/IMG & co.jpg`, mimeType: 'image/jpeg', bytes: 812044, width: 2000,
        height: 1500,
      },
      { kind: 'file', path: `/data/tau.files/${ID_B}/report.pdf`, mimeType: 'application/pdf', bytes: 1204331 },
    ]);
    expect(parseAttachments(`${BLOCK} and more`)).toBeUndefined();
    expect(parseAttachments('<attachments>\nhello\n</attachments>')).toBeUndefined();
  });

  it('makes a message\'s photos and files media by their kept files, its own text the caption', () => {
    const content = [
      { type: 'text', text: BLOCK },
      { type: 'image', mimeType: 'image/jpeg', media: { entryId: 9, index: 0, bytes: 812044 } },
      { type: 'text', text: 'look' },
    ];
    const { text, photos, documents } = readUserContent(content, 4, 9, 100);
    expect(text).toBe('look');
    expect(photos).toEqual([{
      mediaType: 'photo', id: ID_A, date: 100, sizes: [{ type: 'x', width: 2000, height: 1500 }],
    }]);
    expect(documents).toEqual([{
      mediaType: 'document', id: ID_B, fileName: 'report.pdf', size: 1204331, mimeType: 'application/pdf',
    }]);
  });

  it('takes the entry\'s images by reference when the message is older than files', () => {
    const content = [{ type: 'image', mimeType: 'image/png', media: { entryId: 9, index: 0, width: 10, height: 20 } }];
    const { photos } = readUserContent(content, 4, 9, 100);
    expect(photos[0].id).toBe('m4.9.0');
    expect(mediaSource('m4.9.0')).toEqual({ conversationId: 4, entryId: 9, index: 0 });
    expect(mediaSource(ID_A)).toEqual({ fileId: ID_A, slot: 0 });
    // A file on a server added: its slot with it
    expect(mediaSource(`s2-${ID_A}`)).toEqual({ fileId: ID_A, slot: 2 });
    expect(mediaSource('../etc')).toBeUndefined();
  });

  it('makes an album of several: a row each, photos grouped apart from files, the caption on the first', () => {
    const { photos, documents } = readUserContent([{ type: 'text', text: BLOCK }], 4, 9, 100);
    const rows = buildMediaRows(
      { chatId: '4', date: 100, isOutgoing: true }, (row) => 9 * 32 + row, 9, 'look', [...photos, ...photos], documents,
    );
    expect(rows.map((row) => [row.id, row.groupedId, row.isInAlbum, row.content.text?.text])).toEqual([
      [288, 'tau9p', true, 'look'],
      [289, 'tau9p', true, undefined],
      [290, 'tau9d', undefined, undefined],
    ]);
  });

  it('carries a message\'s kept files again, as uploads done already (an edit)', () => {
    const content = [{ type: 'text', text: 'see these' }, { type: 'text', text: BLOCK }];
    expect(keptUploadsOf(content)).toEqual([
      {
        kind: 'photo', key: `kept-${ID_A}`, name: 'IMG & co.jpg', size: 812044, mimeType: 'image/jpeg', width: 2000,
        height: 1500, serverId: ID_A,
      },
      {
        kind: 'file', key: `kept-${ID_B}`, name: 'report.pdf', size: 1204331, mimeType: 'application/pdf',
        serverId: ID_B,
      },
    ]);
    expect(keptUploadsOf('plain text')).toEqual([]);
  });
});
