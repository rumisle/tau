import { describe, expect, it } from 'vitest';

import {
  globalId, localId, mapIds, originOf, slotOf,
} from './servers';

describe('servers', () => {
  it('puts the slot above bit 40; the first server\'s IDs are its own', () => {
    expect(globalId(0, 42)).toBe(42);
    expect(globalId(3, 42)).toBe(3 * 2 ** 40 + 42);
    expect(slotOf(globalId(3, 42))).toBe(3);
    expect(localId(globalId(3, 42))).toBe(42);
    expect(slotOf(42)).toBe(0);
  });

  it('maps a frame\'s conversation IDs, and nothing else', () => {
    const frame = {
      event: 'conv.commit',
      conversationId: 7,
      entries: [{ id: 100, conversationId: 7, model: [{ details: { conversationId: 9, name: 'helper' } }] }],
      dialog: { conversation: { id: 7, parent: { conversationId: 5, at: 3 } }, last: { id: 100 } },
      text: 'conversationId 7',
    };
    expect(mapIds(frame, (id) => id + 1000)).toEqual({
      event: 'conv.commit',
      conversationId: 1007,
      entries: [{ id: 100, conversationId: 1007, model: [{ details: { conversationId: 1009, name: 'helper' } }] }],
      dialog: { conversation: { id: 1007, parent: { conversationId: 1005, at: 3 } }, last: { id: 100 } },
      text: 'conversationId 7',
    });
  });

  it('takes an address as typed', () => {
    expect(originOf('mac.tailnet.ts.net')).toBe('https://mac.tailnet.ts.net');
    expect(originOf('localhost:7878/')).toBe('http://localhost:7878');
    expect(originOf('http://10.0.0.2:7878')).toBe('http://10.0.0.2:7878');
    expect(originOf('ftp://x')).toBeUndefined();
    expect(originOf('  ')).toBeUndefined();
  });
});
