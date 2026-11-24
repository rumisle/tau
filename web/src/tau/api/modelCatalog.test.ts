import { describe, expect, it, vi } from 'vitest';

const request = vi.hoisted(() => vi.fn());
vi.mock('./session', () => ({
  clientOf: () => ({ request }),
  onConversationChange: () => undefined,
  dialogs: new Map(),
  docsOf: () => undefined,
  draftState: () => undefined,
  entriesOf: () => [],
  getOutbox: () => undefined,
  isDraftChat: () => false,
  setDraftAgent: () => undefined,
  slotOfChat: () => 0,
}));

import { cachedModels, loadModels } from './agent';

const first = [{ provider: 'test', id: 'old', name: 'Old', thinkingLevels: ['off'] }];
const updated = [...first, { provider: 'test', id: 'new', name: 'New', thinkingLevels: ['off'] }];

describe('model catalog requests', () => {
  it('uses a cached list normally, but picker opening reloads the local list without a query', async () => {
    request.mockResolvedValueOnce({ models: first });
    expect(await loadModels(10)).toEqual(first);
    expect(request).toHaveBeenLastCalledWith('models.list', {});
    const calls = request.mock.calls.length;
    expect(await loadModels(10)).toEqual(first);
    expect(request).toHaveBeenCalledTimes(calls);
    request.mockResolvedValueOnce({ models: updated });
    expect(await loadModels(10, undefined, true)).toEqual(updated);
    expect(request).toHaveBeenLastCalledWith('models.list', {});
    expect(cachedModels(10)).toEqual(updated);
  });

  it('a search bypasses the client cache and sends its query, coalescing identical requests', async () => {
    request.mockResolvedValueOnce({ models: updated });
    const a = loadModels(20, 'new');
    const b = loadModels(20, 'new');
    expect(a).toBe(b);
    expect(await a).toEqual(updated);
    expect(request).toHaveBeenLastCalledWith('models.list', { query: 'new' });
  });

  it('a failed refresh leaves the cached list usable', async () => {
    request.mockResolvedValueOnce({ models: first });
    await loadModels(30);
    request.mockRejectedValueOnce(new Error('offline'));
    expect(await loadModels(30, 'new')).toBeUndefined();
    expect(cachedModels(30)).toEqual(first);
  });
});
