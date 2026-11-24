import { describe, expect, it } from 'vitest';

import { windowTitle } from './accounts';

describe('window titles', () => {
  it("are the server's where it names them", () => {
    expect(windowTitle({ id: 'key_limit', label: 'Key', title: 'Key Limit', usedPercent: 80 })).toBe('Key Limit');
    expect(windowTitle({ id: 'credits', label: 'Credits', title: 'Credits', usedPercent: 95 })).toBe('Credits');
  });

  it("are made as the server makes them for an older one, the name said once", () => {
    expect(windowTitle({ id: '5h', label: '5h', usedPercent: 1, seconds: 18_000 })).toBe('5-Hour Limit');
    expect(windowTitle({ id: 'week-opus', label: 'Opus', usedPercent: 1, seconds: 604_800 })).toBe('Opus Weekly Limit');
    expect(windowTitle({ id: 'month', label: 'Month', usedPercent: 1, seconds: 2_592_000 })).toBe('Monthly Limit');
    expect(windowTitle({ id: 'vibe', label: 'Vibe', usedPercent: 1, seconds: 2_592_000 })).toBe('Vibe Monthly Limit');
    expect(windowTitle({ id: 'key_limit', label: 'Key', usedPercent: 80 })).toBe('Key');
  });
});
