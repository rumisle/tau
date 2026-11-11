import { describe, expect, it } from 'vitest';

import { findWords, queryWords } from './searchHighlight';

describe('search highlight', () => {
  it('reads a query as the server does: words, a phrase\'s words, no -word', () => {
    expect(queryWords('Zebra "paint crossing" -garden')).toEqual(['zebra', 'paint', 'crossing']);
  });

  it('finds words that start with the query\'s, without case', () => {
    expect(findWords('The Zebra crossing; zebras, azebra', ['zebra'])).toEqual([[4, 9], [20, 25]]);
    expect(findWords('café Café', ['caf'])).toEqual([[0, 3], [5, 8]]);
  });
});
