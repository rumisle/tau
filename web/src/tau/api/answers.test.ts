import type { Dialog } from 'tau-client/protocol';
import { describe, expect, it } from 'vitest';

import { AnswerWatch, plainPreview } from './answers';

const dialog = (
  id: number, last: number, { busy = false, role = 'assistant', unread = 1, owner = false } = {},
): Dialog => ({
  conversation: { id, ...(owner && { owner: { conversationId: 1, taskId: 1 } }) },
  title: `Chat ${id}`,
  last: { id: last, kind: 'message', role, text: `**answer** ${last}` },
  agent: {},
  busy,
  unreadCount: unread,
});

describe('AnswerWatch', () => {
  it('tells of a run that ended with a newer unread answer, once', () => {
    const watch = new AnswerWatch();
    expect(watch.changed([dialog(1, 5)], true)).toEqual([]);
    expect(watch.changed([dialog(1, 6, { busy: true, role: 'user' })], false)).toEqual([]);
    // A tool round: the run goes on
    expect(watch.changed([dialog(1, 7, { busy: true })], false)).toEqual([]);
    expect(watch.changed([dialog(1, 8)], false)).toEqual([{ conversationId: 1, title: 'Chat 1', text: 'answer 8' }]);
    // The same dialog again (read elsewhere, renamed): not news
    expect(watch.changed([dialog(1, 8)], false)).toEqual([]);
    expect(watch.changed([dialog(1, 8, { unread: 0 })], false)).toEqual([]);
  });

  it('keeps quiet for the baseline, a read chat, a subagent, and a run still working', () => {
    const watch = new AnswerWatch();
    expect(watch.changed([dialog(1, 5), dialog(2, 5)], true)).toEqual([]);
    watch.changed([dialog(1, 6, { busy: true }), dialog(2, 6, { busy: true })], false);
    expect(watch.changed([dialog(1, 7, { unread: 0 })], false)).toEqual([]);
    expect(watch.changed([dialog(3, 2, { owner: true })], false)).toEqual([]);
    expect(watch.changed([dialog(2, 7, { busy: true })], false)).toEqual([]);
  });

  it('tells of a chat new since the baseline', () => {
    const watch = new AnswerWatch();
    watch.changed([], true);
    expect(watch.changed([dialog(4, 2)], false)).toHaveLength(1);
  });

  it('a reconnect\'s first list is a baseline again', () => {
    const watch = new AnswerWatch();
    watch.changed([dialog(1, 5, { busy: true })], true);
    expect(watch.changed([dialog(1, 9)], true)).toEqual([]);
  });
});

describe('plainPreview', () => {
  it('drops Markdown\'s inline marks from the one-line summary', () => {
    expect(plainPreview('The **fix** is in `main.ts`, see [the docs](https://x).'))
      .toBe('The fix is in main.ts, see the docs.');
    expect(plainPreview('Ran it: ``` from the shell ```')).toBe('Ran it: from the shell');
    expect(plainPreview('```ts const a = 1; ```')).toBe('const a = 1;');
    expect(plainPreview('2 * 3 = 6, snake_case_name')).toBe('2 * 3 = 6, snake_case_name');
    expect(plainPreview('an _important_ point')).toBe('an important point');
  });
});
