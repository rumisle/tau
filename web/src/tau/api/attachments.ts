// A user message's photos and files as Web A's media (docs/files.md, docs/media.md): the attachments block names each
// kept file by path, whose directory is its ID; photos of messages older than files are the entry's image references.
// Several are an album, as Telegram sends them: a message each, grouped.
import type { Upload } from 'tau-client/outbox';

import type { ApiDocument, ApiMessage, ApiPhoto } from '../../api/types';

import { slotOf } from './servers';

// server/src/attachments.ts's format
const OPEN = '<attachments>\n';
const CLOSE = '\n</attachments>';
const LINE = /^<(image|file) name="([^"]*)" type="([^"]*)" bytes="(\d+)"(?: width="(\d+)" height="(\d+)")?\/>$/;
const FILE_ID = /^[0-9a-f]{32}$/;
// A photo's media ID when it is no kept file: the entry's image, fetched with media.get
const REFERENCE = /^m(\d+)\.(\d+)\.(\d+)$/;

export type AttachmentLine = {
  kind: 'image' | 'file';
  path: string;
  mimeType: string;
  bytes: number;
  width?: number;
  height?: number;
};

export type MediaSource = { fileId: string; slot: number } | { conversationId: number; entryId: number; index: number };
// A kept file's media ID on a server added (src/tau/api/servers.ts): its slot before the file's ID
const SLOT_FILE_ID = /^s(\d+)-([0-9a-f]{32})$/;

/** A kept file's media ID: the file's ID, after its server's slot when that is not the first server */
export function mediaIdOf(fileId: string, slot: number) {
  return slot === 0 ? fileId : `s${slot}-${fileId}`;
}

/** The files a block names, when it is exactly such a block; undefined for any other text */
export function parseAttachments(text: string): AttachmentLine[] | undefined {
  if (!text.startsWith(OPEN) || !text.endsWith(CLOSE)) return undefined;
  const lines: AttachmentLine[] = [];
  for (const line of text.slice(OPEN.length, text.length - CLOSE.length).split('\n')) {
    const match = LINE.exec(line);
    if (!match) return undefined;
    const [, kind, path, type, bytes, width, height] = match;
    lines.push({
      kind: kind as AttachmentLine['kind'],
      path: unescape(path),
      mimeType: unescape(type),
      bytes: Number(bytes),
      ...(width !== undefined && { width: Number(width), height: Number(height) }),
    });
  }
  return lines.length ? lines : undefined;
}

/** A user message's own text and its media, in order */
export function readUserContent(content: unknown, conversationId: number, entryId: number, date: number) {
  if (typeof content === 'string') return { text: content, photos: [], documents: [] };
  const parts = Array.isArray(content) ? content : [];
  const texts: string[] = [];
  let lines: AttachmentLine[] | undefined;
  for (const part of parts) {
    if (part.type !== 'text') continue;
    const parsed = !lines ? parseAttachments(part.text) : undefined;
    if (parsed) lines = parsed;
    else texts.push(part.text);
  }
  const photos: ApiPhoto[] = [];
  const documents: ApiDocument[] = [];
  if (lines) {
    for (const line of lines) {
      const fileId = fileIdFromPath(line.path);
      if (!fileId) continue;
      const id = mediaIdOf(fileId, slotOf(conversationId));
      if (line.kind === 'image') {
        photos.push(buildPhoto(id, date, line.width, line.height));
      } else {
        documents.push({
          mediaType: 'document',
          id,
          fileName: line.path.split('/').at(-1) ?? 'file',
          size: line.bytes,
          mimeType: line.mimeType,
        });
      }
    }
  } else {
    // Older than files: the entry's own images, by reference
    parts.filter((part) => part.type === 'image').forEach((part, index) => {
      photos.push(buildPhoto(`m${conversationId}.${entryId}.${index}`, date, part.media?.width, part.media?.height));
    });
  }
  return { text: texts.join('\n'), photos, documents };
}

/** A user message's kept files as uploads done already, for a message that carries them again (an edit) */
export function keptUploadsOf(content: unknown): Upload[] {
  const parts = Array.isArray(content) ? content : [];
  const lines = parts.filter((part) => part.type === 'text').map((part) => parseAttachments(part.text))
    .find(Boolean) ?? [];
  return lines.flatMap((line) => {
    const id = fileIdFromPath(line.path);
    if (!id) return [];
    return [{
      kind: line.kind === 'image' ? 'photo' as const : 'file' as const,
      key: `kept-${id}`,
      name: line.path.split('/').at(-1) ?? 'file',
      size: line.bytes,
      mimeType: line.mimeType,
      ...(line.width !== undefined && { width: line.width, height: line.height }),
      serverId: id,
    }];
  });
}

function buildPhoto(id: string, date: number, width = 1000, height = 750): ApiPhoto {
  return {
    mediaType: 'photo', id, date, sizes: [{ type: 'x', width, height }],
  };
}

/** The rows of a user message with media: one with the caption, or an album of photos, then one of files */
export function buildMediaRows(
  base: Omit<ApiMessage, 'content' | 'id'>, ids: (row: number) => number, entryId: number,
  text: string, photos: ApiPhoto[], documents: ApiDocument[],
): ApiMessage[] {
  const media = [...photos.map((photo) => ({ photo })), ...documents.map((document) => ({ document }))];
  if (media.length === 1) {
    return [{ ...base, id: ids(0), content: { ...media[0], ...(text && { text: { text } }) } }];
  }
  return media.map((each, row) => ({
    ...base,
    id: ids(row),
    // Telegram groups photos with photos and files with files
    groupedId: `tau${entryId}${'photo' in each ? 'p' : 'd'}`,
    isInAlbum: 'photo' in each ? true : undefined,
    content: { ...each, ...(row === 0 && text && { text: { text } }) },
  }));
}

/** Where a media ID's bytes are: a kept file, or an entry's image */
export function mediaSource(id: string): MediaSource | undefined {
  if (FILE_ID.test(id)) return { fileId: id, slot: 0 };
  const onSlot = SLOT_FILE_ID.exec(id);
  if (onSlot) return { fileId: onSlot[2], slot: Number(onSlot[1]) };
  const match = REFERENCE.exec(id);
  if (!match) return undefined;
  return { conversationId: Number(match[1]), entryId: Number(match[2]), index: Number(match[3]) };
}

function fileIdFromPath(path: string) {
  const id = path.split('/').at(-2) ?? '';
  return FILE_ID.test(id) ? id : undefined;
}

function unescape(text: string) {
  return text.replace(/&#10;/g, '\n').replace(/&gt;/g, '>').replace(/&lt;/g, '<').replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&');
}
