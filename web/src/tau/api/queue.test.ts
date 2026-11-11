import type { OutgoingMessage } from 'tau-client/outbox';
import { describe, expect, it } from 'vitest';

import { buildQueue, queuedPreview } from './queue';

let seq = 0;
const item = (requestId: string, state: OutgoingMessage['state'], extra: Partial<OutgoingMessage> = {}) => ({
  requestId,
  conversationId: 1,
  text: requestId,
  mode: 'steer',
  date: 0,
  state,
  wasSent: true,
  attempts: 0,
  showsInQueue: true,
  seq: seq++,
  ...extra,
}) as OutgoingMessage;

describe('buildQueue', () => {
  it('follows the inbox, this device\'s matched by submission, then what is on its way', () => {
    const items = [
      item('pending', { type: 'pending' }, { mode: 'followUp' }),
      item('mine', { type: 'queued', submissionId: 7 }, { submissionId: 7 }),
      item('idle', { type: 'pending' }, { showsInQueue: false }),
    ];
    const inbox = [
      { id: 6, mode: 'followUp', content: 'from the phone' },
      { id: 7, mode: 'steer', content: 'mine' },
      { id: 8, mode: 'write', entry: { kind: 'pi.reset' } },
    ];
    expect(buildQueue(inbox, items, true).map(({ id, mode, isSending }) => ({ id, mode, isSending }))).toEqual([
      { id: 's6', mode: 'followUp', isSending: false },
      { id: 'mine', mode: 'steer', isSending: false },
      { id: 'pending', mode: 'followUp', isSending: true },
    ]);
  });

  it('leaves out a queued one the current inbox no longer has, and a withdrawn one', () => {
    const items = [
      item('left', { type: 'queued', submissionId: 3 }, { submissionId: 3 }),
      item('going', { type: 'withdrawing' }, { submissionId: 4 }),
    ];
    expect(buildQueue([{ id: 4, mode: 'steer', content: 'going' }], items, true)).toEqual([]);
    // Not synced: the inbox may be stale, so the outbox's word stands
    expect(buildQueue([], items, false).map(({ id }) => id)).toEqual(['left']);
  });

  it('previews the text on one line, or the files', () => {
    const base = {
      id: 'a', mode: 'steer' as const, isSending: false, fileCount: 0,
    };
    expect(queuedPreview({ ...base, text: 'two\nlines' })).toBe('two lines');
    expect(queuedPreview({ ...base, text: '', fileCount: 2 })).toBe('2 files');
  });
});
