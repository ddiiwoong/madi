import test from 'node:test';
import assert from 'node:assert/strict';

import {
  BAILOUT_DOC_CHARS,
  DEBOUNCE_MS,
  DEBOUNCE_MS_LARGE,
  LARGE_DOC_CHARS,
  debounceFor,
  findMatches,
  normalizeQuery,
  segmentByMatches,
  shouldSearch,
} from '../src/search.js';

/* The constants are this implementation's premise; freeze them so a later edit
 * that changes behaviour cannot pass silently. */
test('search thresholds are the documented ones', () => {
  assert.equal(LARGE_DOC_CHARS, 180_000);
  assert.equal(BAILOUT_DOC_CHARS, 250_000);
  assert.equal(DEBOUNCE_MS, 80);
  assert.equal(DEBOUNCE_MS_LARGE, 180);
});

test('baseline: an ordinary query finds every occurrence', () => {
  const matches = findMatches('ab ab ab', 'ab');
  assert.deepEqual(matches, [
    { start: 0, end: 2 },
    { start: 3, end: 5 },
    { start: 6, end: 8 },
  ]);
});

test('matching ignores case in both directions', () => {
  assert.deepEqual(findMatches('Hello HELLO hello', 'hello').length, 3);
  assert.deepEqual(findMatches('hello', 'HeLLo'), [{ start: 0, end: 5 }]);
});

test('query is trimmed, exactly as Mark does', () => {
  assert.equal(normalizeQuery('  find  '), 'find');
  assert.deepEqual(findMatches('find me', '  find  '), [{ start: 0, end: 4 }]);
});

test('matches do not overlap', () => {
  // 'aaaa' holds two non-overlapping 'aa', not three overlapping ones.
  assert.deepEqual(findMatches('aaaa', 'aa'), [
    { start: 0, end: 2 },
    { start: 2, end: 4 },
  ]);
});

test('an empty or whitespace-only query matches nothing', () => {
  assert.deepEqual(findMatches('anything', ''), []);
  assert.deepEqual(findMatches('anything', '   '), []);
});

test('substring search is literal — regex metacharacters are not special', () => {
  assert.deepEqual(findMatches('a.c abc', '.'), [{ start: 1, end: 2 }]);
  assert.deepEqual(findMatches('cost is $5', '$5'), [{ start: 8, end: 10 }]);
  assert.deepEqual(findMatches('abc', 'a.c'), []);
});

test('huge documents ignore a one-character query but accept two', () => {
  const huge = BAILOUT_DOC_CHARS + 1;
  assert.equal(shouldSearch(huge, 'a'), false);
  assert.equal(shouldSearch(huge, 'ab'), true);
  // At the threshold itself the guard does not apply (Mark uses a strict >).
  assert.equal(shouldSearch(BAILOUT_DOC_CHARS, 'a'), true);
});

test('debounce relaxes only above the large-document threshold', () => {
  assert.equal(debounceFor(0), DEBOUNCE_MS);
  assert.equal(debounceFor(LARGE_DOC_CHARS), DEBOUNCE_MS);
  assert.equal(debounceFor(LARGE_DOC_CHARS + 1), DEBOUNCE_MS_LARGE);
});

test('segments reassemble into the original text', () => {
  const text = 'one two one two';
  const segments = segmentByMatches(text, 'one');
  assert.equal(segments.map((s) => s.text).join(''), text);
  assert.deepEqual(segments.filter((s) => s.match).map((s) => s.text), ['one', 'one']);
});

test('segmenting an unmatched query yields the whole text once', () => {
  const segments = segmentByMatches('hello', 'zzz');
  assert.deepEqual(segments, [{ text: 'hello', match: false }]);
});

test('a locale-lowercasing input that changes length still highlights the right span', () => {
  // 'İ'.toLocaleLowerCase() is two code units, which would slide every later
  // index. The fallback keeps the reported span on the real characters.
  const text = 'İstanbul ok';
  for (const { start, end } of findMatches(text, 'ok')) {
    assert.equal(text.slice(start, end).toLocaleLowerCase(), 'ok');
  }
});

test('the mutation guard fires: a broken advance would overlap', () => {
  // Proof the non-overlap assertion above is not vacuous — an advance of 1
  // instead of query.length produces three matches for 'aaaa'/'aa'.
  const overlapping = [];
  const haystack = 'aaaa';
  let at = haystack.indexOf('aa');
  while (at !== -1) {
    overlapping.push(at);
    at = haystack.indexOf('aa', at + 1);
  }
  assert.equal(overlapping.length, 3);
  assert.equal(findMatches('aaaa', 'aa').length, 2);
});
