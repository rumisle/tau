import { describe, expect, it } from 'vitest';

import {
  addUsage, countSocket, formatBytes, networkUsage, resetNetworkUsage,
} from './usage';

describe('network usage', () => {
  it('counts a socket\'s frames for its server, as UTF-8, until reset', () => {
    resetNetworkUsage();
    const socket = new EventTarget() as unknown as WebSocket;
    const sent: unknown[] = [];
    socket.send = (data) => sent.push(data);
    countSocket(socket, 'https://a.example');
    socket.send('{"é":1}');
    socket.dispatchEvent(new MessageEvent('message', { data: 'hello' }));
    addUsage('https://b.example', 3, 4);
    expect(sent).toEqual(['{"é":1}']);
    expect(networkUsage().byOrigin).toEqual({
      'https://a.example': { sent: 8, received: 5 },
      'https://b.example': { sent: 3, received: 4 },
    });
    const { since } = networkUsage();
    resetNetworkUsage();
    expect(networkUsage().byOrigin).toEqual({});
    expect(networkUsage().since).toBeGreaterThanOrEqual(since);
  });

  it('says bytes as iOS does', () => {
    expect([0, 1, 512, 12_345, 1_400_000, 2_500_000_000].map(formatBytes))
      .toEqual(['Zero KB', '1 byte', '512 bytes', '12 KB', '1.4 MB', '2.5 GB']);
  });
});
