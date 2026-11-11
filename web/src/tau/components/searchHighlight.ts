// Found words marked in tau's rows (docs/search.md "In the app"; iOS marks them as Telegram's LinkHighlightingNode does):
// the CSS Custom Highlight API over the row's text as it is drawn, so nothing in the row's DOM changes. A query's words
// match at the start of a word, the last one as a prefix, without case, as the server's search reads them.
import { useEffect } from '../../lib/teact/teact';

const NAME = 'tau-search';

/** A query's words: quotes and `-word` (left out) aside, lowercased */
export function queryWords(query: string) {
  return query.replace(/"/g, ' ').split(/\s+/)
    .filter((word) => word && !word.startsWith('-'))
    .map((word) => word.toLowerCase().replace(/[^\p{L}\p{N}_]/gu, ''))
    .filter(Boolean);
}

/** Where a text has the words: [start, end) of each word that starts with one of them */
export function findWords(text: string, words: string[]) {
  const found: [number, number][] = [];
  const pattern = /[\p{L}\p{N}_]+/gu;
  const lowered = text.toLowerCase();
  for (const match of lowered.matchAll(pattern)) {
    const word = words.find((each) => match[0].startsWith(each));
    if (word) found.push([match.index, match.index + word.length]);
  }
  return found;
}

function registry() {
  const highlights = (CSS as unknown as { highlights?: Map<string, Set<Range>> }).highlights;
  if (!highlights || typeof Highlight === 'undefined') return undefined;
  if (!highlights.has(NAME)) highlights.set(NAME, new Highlight() as unknown as Set<Range>);
  return highlights.get(NAME)!;
}

/** Marks the query's words in an element's text while it shows, again when its content changes */
export function useSearchHighlight(ref: { current?: HTMLElement }, query: string | undefined, content: unknown) {
  useEffect(() => {
    const element = ref.current;
    const highlight = registry();
    const words = query ? queryWords(query) : [];
    if (!element || !highlight || !words.length) return undefined;
    const ranges: Range[] = [];
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      for (const [start, end] of findWords(node.textContent ?? '', words)) {
        const range = new Range();
        range.setStart(node, start);
        range.setEnd(node, end);
        ranges.push(range);
      }
    }
    for (const range of ranges) highlight.add(range);
    return () => {
      for (const range of ranges) highlight.delete(range);
    };
  }, [ref, query, content]);
}
