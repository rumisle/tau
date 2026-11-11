// Markdown as Web A's rich-message blocks, through the composer's own parser (tiptap's MarkdownManager with the
// editor's schema) and converter (`buildRichMessageFromTiptapJson`)
import { getSchema, type JSONContent } from '@tiptap/core';
import { MarkdownManager } from '@tiptap/markdown';

import type { ApiPageBlock } from '../../api/types';

import { buildBotApiHtmlSerializer, extendBotApiMarkdownHtml } from '../../util/tiptap/botApiHtml';
import { TABLE_CELL_HIGHLIGHT_ATTR, TABLE_WRAPPER_NODE_NAME } from '../../util/tiptap/constants';
import { __buildRichEditorSchemaExtensions } from '../../components/middle/composer/helpers/richEditor';
import { buildRichMessageFromTiptapJson } from '../../components/ui/textInput/richText';

const SCHEMA_EXTENSIONS = __buildRichEditorSchemaExtensions();
const SCHEMA = getSchema(SCHEMA_EXTENSIONS);
const MARKDOWN = new MarkdownManager({
  extensions: extendBotApiMarkdownHtml(SCHEMA_EXTENSIONS, SCHEMA, buildBotApiHtmlSerializer(SCHEMA)),
});

export function buildMarkdownBlocks(markdown: string): ApiPageBlock[] {
  try {
    return buildRichMessageFromTiptapJson(wrapTables(MARKDOWN.parse(markdown))).blocks;
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
