/**
 * Preview highlighting.
 *
 * Mark paints matches with ProseMirror inline Decorations, which never touch
 * the DOM the editor owns. The equivalent for a plain rendered preview is the
 * CSS Custom Highlight API: Ranges registered under a highlight name, styled
 * with `::highlight(search)`. Nothing in the document is mutated, so a
 * re-render cannot fight the highlighter.
 *
 * Mark.app never highlights inside code — neither code blocks nor inline code.
 * `CODE_TAGS` is that same rule expressed for HTML.
 */
import { findMatches, normalizeQuery, shouldSearch } from './search.js';

export const HIGHLIGHT_NAME = 'search';
const CODE_TAGS = new Set(['CODE', 'PRE', 'KBD', 'SAMP']);

export function supportsHighlightApi() {
  return typeof CSS !== 'undefined' && !!CSS.highlights && typeof Highlight === 'function';
}

function insideCode(node, root) {
  for (let el = node.parentElement; el && el !== root.parentElement; el = el.parentElement) {
    if (CODE_TAGS.has(el.tagName)) return true;
  }
  return false;
}

function collectTextNodes(root) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue) return NodeFilter.FILTER_REJECT;
      return insideCode(node, root) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
    },
  });
  const nodes = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) nodes.push(n);
  return nodes;
}

/**
 * Highlight every occurrence of `rawQuery` inside `root`.
 *
 * @returns {number} match count, or -1 when the browser has no Highlight API.
 */
export function highlightPreview(root, rawQuery) {
  if (!supportsHighlightApi()) return -1;
  CSS.highlights.delete(HIGHLIGHT_NAME);

  const query = normalizeQuery(rawQuery);
  const docLength = root.textContent ? root.textContent.length : 0;
  if (!shouldSearch(docLength, query)) return 0;

  const ranges = [];
  for (const node of collectTextNodes(root)) {
    for (const { start, end } of findMatches(node.nodeValue, query)) {
      const range = document.createRange();
      range.setStart(node, start);
      range.setEnd(node, end);
      ranges.push(range);
    }
  }

  if (ranges.length > 0) CSS.highlights.set(HIGHLIGHT_NAME, new Highlight(...ranges));
  return ranges.length;
}

export function clearPreviewHighlight() {
  if (supportsHighlightApi()) CSS.highlights.delete(HIGHLIGHT_NAME);
}

/** Scroll the n-th match into view. Mark has no such navigation; see README. */
export function scrollToMatch(root, rawQuery, index) {
  const query = normalizeQuery(rawQuery);
  if (!query) return false;
  let seen = 0;
  for (const node of collectTextNodes(root)) {
    const matches = findMatches(node.nodeValue, query);
    if (seen + matches.length <= index) {
      seen += matches.length;
      continue;
    }
    const { start, end } = matches[index - seen];
    const range = document.createRange();
    range.setStart(node, start);
    range.setEnd(node, end);
    const rect = range.getBoundingClientRect();
    const host = root.parentElement || root;
    host.scrollTop += rect.top - host.getBoundingClientRect().top - host.clientHeight / 2;
    return true;
  }
  return false;
}
