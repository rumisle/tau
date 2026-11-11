// Markdown as Web A's rich-message blocks, through the composer's own parser (tiptap's MarkdownManager with the
// editor's schema) and converter (`buildRichMessageFromTiptapJson`)
import { getSchema, type JSONContent } from '@tiptap/core';
import { MarkdownManager } from '@tiptap/markdown';

import type { ApiPageBlock } from '../../api/types';

import { buildBotApiHtmlSerializer, extendBotApiMarkdownHtml } from '../../util/tiptap/botApiHtml';
import { TABLE_CELL_HIGHLIGHT_ATTR, TABLE_WRAPPER_NODE_NAME } from '../../util/tiptap/constants';
import { __buildRichEditorSchemaExtensions } from '../../components/middle/composer/helpers/richEditor';
import { buildRichMessageFromTiptapJson } from '../../components/ui/textInput/richText';

// The editor's list item attributes for a checkbox (richText.ts)
const CHECKBOX_ATTR = 'checkbox';
const CHECKED_ATTR = 'checked';
const SCHEMA_EXTENSIONS = __buildRichEditorSchemaExtensions();
const SCHEMA = getSchema(SCHEMA_EXTENSIONS);
const MARKDOWN = new MarkdownManager({
  extensions: extendBotApiMarkdownHtml(SCHEMA_EXTENSIONS, SCHEMA, buildBotApiHtmlSerializer(SCHEMA)),
});

export function buildMarkdownBlocks(markdown: string): ApiPageBlock[] {
  try {
    return buildRichMessageFromTiptapJson(markTasks(wrapTables(MARKDOWN.parse(markTaskLines(markdown))))).blocks;
  } catch {
    return [buildParagraph(markdown)];
  }
}

export function buildParagraph(text: string): ApiPageBlock {
  return { type: 'paragraph', text: { type: 'plain', text } };
}

// Markdown's tables come bare, with header cells; the editor's have a wrapper and highlighted cells
function wrapTables(node: JSONContent): JSONContent {
  const content = node.content?.map(wrapTables);
  if (node.type === 'tableHeader') {
    return { ...node, type: 'tableCell', attrs: { ...node.attrs, [TABLE_CELL_HIGHLIGHT_ATTR]: true }, content };
  }
  if (node.type === 'table') return { type: TABLE_WRAPPER_NODE_NAME, content: [{ ...node, content }] };
  return { ...node, content };
}

// Task list items (`- [x] done`): the parser reads them as items with bare text, which the converter drops, and loses
// the box; marked with a character of their own first, they parse as plain items and become the editor's checkboxes
const CHECKED = '\uE000';
const UNCHECKED = '\uE001';
const TASK_LINE = /^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]\s+/;
const FENCE = /^\s*(```|~~~)/;

function markTaskLines(markdown: string) {
  let isInFence = false;
  return markdown.split('\n').map((line) => {
    if (FENCE.test(line)) isInFence = !isInFence;
    if (isInFence) return line;
    return line.replace(TASK_LINE, (_, bullet: string, mark: string) => (
      `${bullet}${mark === ' ' ? UNCHECKED : CHECKED}`
    ));
  }).join('\n');
}

function markTasks(node: JSONContent): JSONContent {
  const content = node.content?.map(markTasks);
  if (node.type !== 'listItem') return { ...node, content };
  const first = firstText(content);
  const mark = first?.text?.[0];
  if (mark !== CHECKED && mark !== UNCHECKED) return { ...node, content };
  first!.text = first!.text!.slice(1);
  return {
    ...node,
    attrs: { ...node.attrs, [CHECKBOX_ATTR]: true, [CHECKED_ATTR]: mark === CHECKED },
    content,
  };
}

function firstText(content?: JSONContent[]): JSONContent | undefined {
  for (const child of content ?? []) {
    if (child.type === 'text') return child;
    const found = firstText(child.content);
    if (found) return found;
  }
  return undefined;
}
