// What the composer sends, as tau takes it: the text as the user wrote it, in Markdown, and the bubble shown for it until
// its entry comes (docs/sending.md "What the user sees").
import type { OutgoingMessage } from 'tau-client/outbox';

import type { ApiMessage, ApiMessageEntity } from '../../api/types';
import { ApiMessageEntityTypes } from '../../api/types';

import { buildChatId, ME_ID } from './builders';

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

/** The bubble for a message on its way: the clock while it goes, a check once queued, the red badge when refused */
export function buildOutgoingMessage(item: OutgoingMessage, chatId: string, localId: number): ApiMessage {
  return {
    id: localId,
    chatId,
    date: Math.floor(item.date / 1000),
    isOutgoing: true,
    senderId: ME_ID,
    content: { text: { text: item.text } },
    sendingState: item.state.type === 'failed' ? 'messageSendingStateFailed'
      : item.state.type === 'queued' ? undefined : 'messageSendingStatePending',
  };
}

export function outgoingChatId(item: OutgoingMessage) {
  return item.conversationId === undefined ? undefined : buildChatId(item.conversationId);
}
