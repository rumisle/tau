import { describe, expect, it } from 'vitest';

import { draftBytes } from './drafts';

describe('draftBytes', () => {
  it('counts the drafts of every server, and none for a server whose drafts are all gone', () => {
    localStorage.clear();
    localStorage.setItem('tau-drafts:https://a.example', '{}');
    localStorage.setItem('other', 'not a draft');
    expect(draftBytes()).toBe(0);
    localStorage.setItem('tau-drafts:https://b.example', '{"7":"é"}');
    expect(draftBytes()).toBe(10);
  });
});
