// The messages waiting for the agent (docs/sending.md "What the user sees"): the panel above the field shows them, not
// the transcript, until the model has them. As iOS's `ConversationReplica.queue`.
import type { OutgoingMessage, SendMode } from 'tau-client/outbox';
import type { JsonObject } from 'tau-client/protocol';

import { readUserContent } from './attachments';

export type QueuedMessage = {
  // Stable across the switch from on its way to queued: the request ID, or `s<submissionId>` for another device's
  id: string;
  mode: SendMode;
  text: string;
  fileCount: number;
  // On its way to the server: the clock; queued: a check
  isSending: boolean;
  // The outbox's message, when this device sent it
  outgoingId?: string;
  submissionId?: number;
};

/** Whether a message on its way shows in the panel rather than as a bubble */
export function isInQueue(item: OutgoingMessage) {
  return item.showsInQueue && (item.state.type === 'pending' || item.state.type === 'queued');
}

function fromItem(item: OutgoingMessage, isSending: boolean, submissionId?: number): QueuedMessage {
  return {
    id: item.requestId,
    mode: item.mode,
    text: item.text,
    fileCount: item.uploads?.length ?? 0,
    isSending,
    outgoingId: item.requestId,
    submissionId,
  };
}

/**
 * The queue: the server's inbox in its order (`pi.inbox.items`, only steers and follow-ups), this device's messages
 * matched to them, then this device's messages still on their way to it. `isSynced`: the inbox is current, so a queued
 * message not in it has left it (its record is on the way).
 */
export function buildQueue(inbox: JsonObject[], items: OutgoingMessage[], isSynced: boolean): QueuedMessage[] {
  const result: QueuedMessage[] = [];
  const shown = new Set<string>();
  const bySubmission = new Map<number, OutgoingMessage>();
  for (const item of items) {
    if (item.submissionId !== undefined && !bySubmission.has(item.submissionId)) {
      bySubmission.set(item.submissionId, item);
    }
  }
  for (const raw of inbox) {
    const submissionId = raw.id as number | undefined;
    const mode = raw.mode as string | undefined;
    if (submissionId === undefined || (mode !== 'steer' && mode !== 'followUp')) continue;
    const item = bySubmission.get(submissionId);
    if (item) {
      shown.add(item.requestId);
      if (item.state.type !== 'withdrawing') result.push(fromItem(item, false, submissionId));
    } else {
      const { text, photos, documents } = readUserContent(raw.content, 0, 0, 0);
      result.push({
        id: `s${submissionId}`, mode, text, fileCount: photos.length + documents.length, isSending: false, submissionId,
      });
    }
  }
  for (const item of [...items].sort((a, b) => a.seq - b.seq)) {
    if (shown.has(item.requestId) || !isInQueue(item)) continue;
    if (item.state.type === 'queued') {
      if (isSynced && !item.needsRefresh) continue;
      result.push(fromItem(item, false, item.state.submissionId));
    } else {
      result.push(fromItem(item, true));
    }
  }
  return result;
}

/** One line for the panel and the menu: the text, or what it carries */
export function queuedPreview(queued: QueuedMessage) {
  const text = queued.text.replace(/\s+/g, ' ').trim();
  if (text) return text;
  return queued.fileCount > 1 ? `${queued.fileCount} files` : 'File';
}
