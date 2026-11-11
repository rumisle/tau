import { describe, expect, it } from 'vitest';

import { buildMarkdownBlocks } from './markdown';

describe('buildMarkdownBlocks', () => {
  it('makes task lists checkboxes, checked or not, and leaves the same text in code alone', () => {
    expect(buildMarkdownBlocks('- [x] done\n- [ ] open\n- plain')).toEqual([{
      type: 'list',
      items: [
        {
          type: 'text', text: { type: 'plain', text: 'done' }, isCheckbox: true, isChecked: true,
        },
        { type: 'text', text: { type: 'plain', text: 'open' }, isCheckbox: true },
        { type: 'text', text: { type: 'plain', text: 'plain' } },
      ],
    }]);
    expect(buildMarkdownBlocks('```\n- [x] keep\n```')).toEqual([
      { type: 'preformatted', text: { type: 'plain', text: '- [x] keep' }, language: '' },
    ]);
  });
});
