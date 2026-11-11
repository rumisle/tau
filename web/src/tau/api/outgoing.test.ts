import { describe, expect, it } from 'vitest';

import { ApiMessageEntityTypes } from '../../api/types';

import { toMarkdown } from './outgoing';

describe('toMarkdown', () => {
  it('turns the composer\'s entities back into the Markdown they were typed as', () => {
    expect(toMarkdown('run ls -la and bold', [
      { type: ApiMessageEntityTypes.Code, offset: 4, length: 6 },
      { type: ApiMessageEntityTypes.Bold, offset: 15, length: 4 },
    ])).toBe('run `ls -la` and **bold**');
  });

  it('nests marks, the outer around the inner, and keeps a code block\'s language', () => {
    expect(toMarkdown('a link here', [
      { type: ApiMessageEntityTypes.Italic, offset: 0, length: 11 },
      { type: ApiMessageEntityTypes.TextUrl, offset: 2, length: 4, url: 'https://example.com' },
    ])).toBe('_a [link](https://example.com) here_');
    expect(toMarkdown('echo hi', [{ type: ApiMessageEntityTypes.Pre, offset: 0, length: 7, language: 'sh' }]))
      .toBe('```sh\necho hi\n```');
  });

  it('leaves text without entities, and entities Markdown has no marks for, as they are', () => {
    expect(toMarkdown('plain *not bold*')).toBe('plain *not bold*');
    expect(toMarkdown('a spoiler', [{ type: ApiMessageEntityTypes.Spoiler, offset: 2, length: 7 }])).toBe('a spoiler');
  });
});
