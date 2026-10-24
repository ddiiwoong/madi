/**
 * Document search — same observable behaviour as Mark.app 0.7.1's search.
 *
 * This is a re-implementation from OBSERVED behaviour, not a port of that
 * app's code. What was observed, by typing queries into it:
 *
 *   - plain substring matching: regex metacharacters match literally
 *   - case-insensitive with no toggle in the UI
 *   - matches do not overlap ("aa" in "aaaa" finds two)
 *   - the query is trimmed
 *   - code blocks and inline code are never highlighted
 *   - input is debounced, and the delay grows for large documents
 *   - in a very large document a single-character query is ignored
 *   - highlighting leaves the DOM alone (copying text drops the marks)
 *
 * The thresholds below are this repository's own choices, collected here so
 * they can be tuned in one place.
 */

/** Above this length the query debounce is relaxed. */
export const LARGE_DOC_CHARS = 180_000;
/** Above this length a 1-character query is ignored entirely. */
export const BAILOUT_DOC_CHARS = 250_000;
/** Debounce for an ordinary document. */
export const DEBOUNCE_MS = 80;
/** Debounce once the document is past LARGE_DOC_CHARS. */
export const DEBOUNCE_MS_LARGE = 180;
/** Shortest query accepted in a document past BAILOUT_DOC_CHARS. */
export const MIN_QUERY_FOR_HUGE_DOC = 2;

/** Mark trims the query before using it (`e.trim()`), and never anything else. */
export function normalizeQuery(raw) {
  return typeof raw === 'string' ? raw.trim() : '';
}

/** Mark's debounce choice: `e()>xv ? Mv : Sv`. */
export function debounceFor(docLength) {
  return docLength > LARGE_DOC_CHARS ? DEBOUNCE_MS_LARGE : DEBOUNCE_MS;
}

/**
 * Mark's bail-out condition, lifted out so the preview and the source pane
 * cannot drift apart: `!n || t.content.size>Cv && n.length<2`.
 */
export function shouldSearch(docLength, query) {
  if (!query) return false;
  if (docLength > BAILOUT_DOC_CHARS && query.length < MIN_QUERY_FOR_HUGE_DOC) return false;
  return true;
}

/**
 * Case-insensitive, non-overlapping substring matches.
 *
 * Deviation from Mark, deliberate: Mark lowercases with `toLocaleLowerCase()`
 * and then uses the index straight away. For a few inputs that call changes
 * the string's LENGTH (Turkish 'İ' lowercases to two code units), which slides
 * every later index and mis-places the highlight. We detect that case and fall
 * back to a case-sensitive scan rather than painting the wrong characters.
 *
 * @param {string} text
 * @param {string} rawQuery
 * @returns {{start:number,end:number}[]}
 */
export function findMatches(text, rawQuery) {
  const query = normalizeQuery(rawQuery);
  if (!text || !shouldSearch(text.length, query)) return [];

  let haystack = text.toLocaleLowerCase();
  let needle = query.toLocaleLowerCase();
  if (haystack.length !== text.length || needle.length !== query.length) {
    haystack = text;
    needle = query;
  }

  const matches = [];
  let at = haystack.indexOf(needle);
  while (at !== -1) {
    matches.push({ start: at, end: at + query.length });
    at = haystack.indexOf(needle, at + query.length);
  }
  return matches;
}

/**
 * Split `text` into alternating plain / matched segments, for rendering an
 * overlay. The source pane needs this because it wraps each hit in a `<mark>`
 * element, where the preview pane uses the Custom Highlight API instead.
 *
 * @returns {{text:string,match:boolean}[]}
 */
export function segmentByMatches(text, rawQuery) {
  const matches = findMatches(text, rawQuery);
  if (matches.length === 0) return text ? [{ text, match: false }] : [];

  const segments = [];
  let cursor = 0;
  for (const { start, end } of matches) {
    if (start > cursor) segments.push({ text: text.slice(cursor, start), match: false });
    segments.push({ text: text.slice(start, end), match: true });
    cursor = end;
  }
  if (cursor < text.length) segments.push({ text: text.slice(cursor), match: false });
  return segments;
}

/** Trailing-edge debounce whose delay is recomputed per call from the doc size. */
export function createQueryDebouncer(apply, getDocLength) {
  let timer = null;
  return {
    set(query) {
      if (timer !== null) clearTimeout(timer);
      timer = setTimeout(() => {
        timer = null;
        apply(normalizeQuery(query));
      }, debounceFor(getDocLength()));
    },
    flush(query) {
      if (timer !== null) clearTimeout(timer);
      timer = null;
      apply(normalizeQuery(query));
    },
    clear() {
      if (timer !== null) clearTimeout(timer);
      timer = null;
    },
  };
}
