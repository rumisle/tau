// What the composer sends, as tau takes it: the text as the user wrote it, in Markdown, and the bubble shown for it until
// its entry comes (docs/sending.md "What the user sees").
import type { OutgoingMessage, Upload } from 'tau-client/outbox';

import type {
  ApiAttachment, ApiDocument, ApiMessage, ApiMessageEntity, ApiPhoto,
} from '../../api/types';
import { ApiMessageEntityTypes } from '../../api/types';

import { buildMediaRows } from './attachments';
import { buildChatId, ME_ID } from './builders';

// Photos are sent at most this many pixels on the long side, as JPEG at 0.8 (docs/media.md "In the app")
const MAX_PHOTO_SIDE = 2000;
const PHOTO_QUALITY = 0.8;

// Web A's composer turns Markdown into entities as it parses the field; the model reads Markdown, so they go back
const MARKS: Partial<Record<ApiMessageEntityTypes, (entity: ApiMessageEntity) => [string, string]>> = {
  [ApiMessageEntityTypes.Bold]: () => ['**', '**'],
  [ApiMessageEntityTypes.Italic]: () => ['_', '_'],
  [ApiMessageEntityTypes.Strike]: () => ['~~', '~~'],
  [ApiMessageEntityTypes.Code]: () => ['`', '`'],
  [ApiMessageEntityTypes.Pre]: (entity) => [
    `\`\`\`${(entity as { language?: string }).language ?? ''}\n`, '\n```',
  ],
  [ApiMessageEntityTypes.TextUrl]: (entity) => ['[', `](${(entity as { url: string }).url})`],
};

/** A formatted text as Markdown: each entity Markdown has becomes its marks again, the others their text */
export function toMarkdown(text: string, entities: ApiMessageEntity[] = []) {
  type Mark = { at: number; isClose: boolean; length: number; index: number; mark: string };
  const marks: Mark[] = [];
  entities.forEach((entity, index) => {
    const pair = MARKS[entity.type]?.(entity);
    if (!pair) return;
    marks.push({
      at: entity.offset, isClose: false, length: entity.length, index, mark: pair[0],
    });
    marks.push({
      at: entity.offset + entity.length, isClose: true, length: entity.length, index, mark: pair[1],
    });
  });
  // At one place: what closes before what opens; the inner closes first and the outer opens first
  marks.sort((a, b) => a.at - b.at
    || Number(b.isClose) - Number(a.isClose)
    || (a.isClose ? a.length - b.length || b.index - a.index : b.length - a.length || a.index - b.index));
  let result = '';
  let at = 0;
  for (const mark of marks) {
    result += text.slice(at, mark.at) + mark.mark;
    at = mark.at;
  }
  return result + text.slice(at);
}

/**
 * The bubbles for a message on its way: the clock while it goes, a check once queued, the red badge when refused. One
 * for text, its photos and files as an album when it has several, from the bytes this device has (`blobUrls` by key).
 */
export function buildOutgoingRows(
  item: OutgoingMessage, chatId: string, localIds: number[], blobUrls: Map<string, string>,
): ApiMessage[] {
  const base = {
    chatId,
    date: Math.floor(item.date / 1000),
    isOutgoing: true,
    senderId: ME_ID,
    sendingState: item.state.type === 'failed' ? 'messageSendingStateFailed' as const
      : item.state.type === 'queued' ? undefined : 'messageSendingStatePending' as const,
  };
  const uploads = item.uploads ?? [];
  if (!uploads.length) return [{ ...base, id: localIds[0], content: { text: { text: item.text } } }];
  const photos: ApiPhoto[] = [];
  const documents: ApiDocument[] = [];
  for (const upload of uploads) {
    if (upload.kind === 'photo') {
      photos.push({
        mediaType: 'photo',
        id: `local-${upload.key}`,
        date: base.date,
        sizes: [{ type: 'x', width: upload.width ?? 1000, height: upload.height ?? 750 }],
        blobUrl: blobUrls.get(upload.key),
      });
    } else {
      documents.push({
        mediaType: 'document',
        id: `local-${upload.key}`,
        fileName: upload.name,
        size: upload.size,
        mimeType: upload.mimeType,
      });
    }
  }
  return buildMediaRows(base, (row) => localIds[row], 0, item.text, photos, documents);
}

/** How many bubbles a message on its way takes */
export function outgoingRowCount(item: OutgoingMessage) {
  return Math.max(1, item.uploads?.length ?? 0);
}

/**
 * The composer's attachments as uploads, each with its bytes: a photo at most 2000 pixels as JPEG (a GIF as it is),
 * anything else, or what is sent as a file, as it is
 */
export async function prepareUploads(attachments: ApiAttachment[], keyPrefix: string) {
  return Promise.all(attachments.map(async (attachment, index) => {
    const original = attachment.blob ?? await (await fetch(attachment.blobUrl)).blob();
    const key = `${keyPrefix}-${index}`;
    const isPhoto = Boolean(attachment.quick) && !attachment.shouldSendAsFile
      && /^image\/(jpeg|png|gif|webp)$/.test(attachment.mimeType);
    if (isPhoto && attachment.mimeType !== 'image/gif') {
      const encoded = await encodePhoto(original).catch(() => undefined);
      if (encoded) {
        const upload: Upload = {
          kind: 'photo',
          key,
          name: attachment.filename.replace(/\.[^.]*$/, '') + '.jpg',
          size: encoded.blob.size,
          mimeType: 'image/jpeg',
          width: encoded.width,
          height: encoded.height,
        };
        return { upload, blob: encoded.blob };
      }
    }
    const upload: Upload = {
      kind: isPhoto ? 'photo' : 'file',
      key,
      name: attachment.filename,
      size: original.size,
      mimeType: attachment.mimeType || 'application/octet-stream',
      ...(isPhoto && attachment.quick && { width: attachment.quick.width, height: attachment.quick.height }),
    };
    return { upload, blob: original };
  }));
}

async function encodePhoto(blob: Blob) {
  const bitmap = await createImageBitmap(blob);
  const scale = Math.min(1, MAX_PHOTO_SIDE / Math.max(bitmap.width, bitmap.height));
  const width = Math.max(1, Math.round(bitmap.width * scale));
  const height = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = new OffscreenCanvas(width, height);
  canvas.getContext('2d')!.drawImage(bitmap, 0, 0, width, height);
  bitmap.close();
  return { blob: await canvas.convertToBlob({ type: 'image/jpeg', quality: PHOTO_QUALITY }), width, height };
}

export function outgoingChatId(item: OutgoingMessage) {
  return item.conversationId === undefined ? undefined : buildChatId(item.conversationId);
}
