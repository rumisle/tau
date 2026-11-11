import { describe, expect, it } from 'vitest';

import { orderModels } from './ModelPicker';

const model = (provider: string, id: string, name: string) => ({
  provider, id, name, thinkingLevels: ['off'],
});

describe('orderModels', () => {
  const models = [
    model('b', 'x', 'Bravo'), model('a', 'y', 'Zulu'), model('a', 'z', 'Alpha'), model('c', 'w', 'Charlie'),
  ];

  it('puts the recent ones first, newest first, then the rest by provider and name', () => {
    expect(orderModels(models, ['c/w', 'b/x'], '').map((each) => each.name))
      .toEqual(['Charlie', 'Bravo', 'Alpha', 'Zulu']);
  });

  it('keeps what the search matches by name, ID or provider', () => {
    expect(orderModels(models, [], 'alp').map((each) => each.name)).toEqual(['Alpha']);
    expect(orderModels(models, [], 'Y').map((each) => each.name)).toEqual(['Zulu']);
    expect(orderModels(models, [], 'b').map((each) => each.name)).toEqual(['Bravo']);
  });
});
