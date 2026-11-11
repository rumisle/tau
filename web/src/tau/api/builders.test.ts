// Entries as Web A's messages: tau's content of each kind, the rich message beside it, and what the chat does not show
import type { Entry } from 'tau-client/protocol';
import { describe, expect, it } from 'vitest';

import type { MessageContext } from './builders';

import { buildMessage, ME_ID } from './builders';

const at = 1_700_000_000_000;
const context = (results = new Map<string, any>(), busy = false): MessageContext => ({
  results,
  runStartAt: () => at,
  subagentTask: () => 'count to three',
  isBusy: () => busy,
});
const entry = (id: number, kind: string, message: object): Entry => ({
  id, kind, conversationId: 7, model: [{ timestamp: at + 2500, ...message }],
});

describe('buildMessage', () => {
  it('makes the user\'s message an outgoing text message', () => {
    const message = buildMessage(entry(1, 'pi.user', { role: 'user', content: 'hello' }), context())!;
    expect(message).toMatchObject({
      id: 1, chatId: '7', isOutgoing: true, senderId: ME_ID, content: { text: { text: 'hello' } },
    });
    expect(message.tau).toBeUndefined();
  });

  it('makes an answer tau\'s row: thinking, Markdown, the run\'s end and its time; the preview is the answer', () => {
    const message = buildMessage(entry(2, 'pi.assistant', {
      role: 'assistant',
      stopReason: 'stop',
      content: [{ type: 'thinking', thinking: 'Hmm.' }, { type: 'text', text: '# Title\n\nSome **bold** text.' }],
    }), context())!;
    expect(message.isOutgoing).toBe(false);
    expect(message.tau!.parts.map((part) => part.type)).toEqual(['thinking', 'text']);
    const blocks = (message.tau!.parts[1] as { blocks: { type: string }[] }).blocks;
    expect(blocks.map((block) => block.type)).toEqual(['heading1', 'paragraph']);
    expect(message.tau!.runEnd).toEqual({ workedForMs: 2500 });
    // The rich message, for the chat list's preview and copy, is the answer; thinking only when there is nothing else
    expect(message.content.richMessage!.blocks.map((block) => block.type)).toEqual(['heading1', 'paragraph']);
    const thinking = buildMessage(entry(3, 'pi.assistant', {
      role: 'assistant', stopReason: 'stop', content: [{ type: 'thinking', thinking: 'Hmm.' }],
    }), context())!;
    expect(thinking.content.richMessage!.blocks[0].type).toBe('thinking');
  });

  it('makes a bash call a card with its command and, once it came, its result', () => {
    const call = entry(3, 'pi.assistant', {
      role: 'assistant',
      stopReason: 'toolUse',
      content: [{ type: 'toolCall', id: 'c1', name: 'bash', arguments: { command: 'echo hi' } }],
    });
    const running = buildMessage(call, context())!;
    expect(running.tau!.runEnd).toBeUndefined();
    expect(running.tau!.parts[0]).toMatchObject({
      type: 'tool', title: 'Bash', command: '$ echo hi', status: 'running', language: 'bash',
    });
    const results = new Map([['c1', { content: [{ type: 'text', text: 'hi\n' }], isError: false, durationMs: 1200 }]]);
    expect(buildMessage(call, context(results))!.tau!.parts[0]).toMatchObject({
      status: 'done', output: 'hi', durationMs: 1200,
    });
  });

  it('shows a subagent\'s report as its card, and leaves tool results and system entries out', () => {
    const report = buildMessage(entry(4, 'pi.user', {
      role: 'user', content: '<subagent name="helper" conversation="9" status="answered">Three.</subagent>',
    }), context())!;
    expect(report.isOutgoing).toBe(false);
    expect(report.tau!.parts[0]).toMatchObject({
      type: 'subagent', name: 'helper', state: 'answered', task: 'count to three',
    });
    expect(buildMessage(entry(5, 'pi.tool-result', { role: 'toolResult' }), context())).toBeUndefined();
    expect(buildMessage({ id: 6, kind: 'pi.system', conversationId: 7 }, context())).toBeUndefined();
  });
});
