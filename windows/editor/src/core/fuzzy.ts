// 빠른 열기 · 명령 팔레트의 거르기 — macOS판 `FuzzyMatch`와 같은 점수(차례대로 맞는 글자, 이어서 맞음 · 낱말 첫 글자 · 맨 앞에 덤).
// 대소문자 · 분음부호 · 전각/반각을 무시한다.

function fold(text: string): string {
  // NFKD로 나눠 분음부호를 떼고 NFC로 다시 묶는다 — 한글은 NFKD에서 자모로 나뉘었다가 NFC에서 음절로 돌아온다.
  return text.normalize("NFKD").replace(/\p{M}/gu, "").normalize("NFC").toLowerCase();
}

const wordBreaks = new Set([" ", "/", "\\", "-", "_", ".", "›", "▸", "(", "["]);

function isWordStart(text: readonly string[], index: number): boolean {
  return index === 0 || wordBreaks.has(text[index - 1]!);
}

function nextMatch(wanted: string, haystack: readonly string[], start: number, preferWordStart: boolean): number | null {
  const first = haystack.indexOf(wanted, start);
  if (first < 0) return null;
  if (!preferWordStart || isWordStart(haystack, first)) return first;
  const limit = Math.min(haystack.length, first + 13);
  for (let position = first + 1; position < limit; position++) {
    if (haystack[position] === wanted && isWordStart(haystack, position)) return position;
  }
  return first;
}

function scoreWith(needle: readonly string[], haystack: readonly string[], preferWordStarts: boolean): number | null {
  let score = 0;
  let index = 0;
  let previous: number | null = null;
  for (const wanted of needle) {
    const found = nextMatch(wanted, haystack, index, preferWordStarts);
    if (found === null) return null;
    score += 1;
    if (previous !== null && found === previous + 1) score += 6;
    else if (previous !== null) score -= Math.min(found - previous - 1, 6);
    if (isWordStart(haystack, found)) score += 8;
    if (found === 0) score += 6;
    previous = found;
    index = found + 1;
  }
  if (haystack.length === needle.length) score += 20;
  return score;
}

/** 맞으면 점수(클수록 앞), 아니면 null. 빈 질의는 모두 0. */
export function fuzzyScore(query: string, candidate: string): number | null {
  const needle = [...fold(query)].filter((char) => !/\s/.test(char));
  if (needle.length === 0) return 0;
  const haystack = [...fold(candidate)];
  if (needle.length > haystack.length) return null;
  const plain = scoreWith(needle, haystack, false);
  const starts = scoreWith(needle, haystack, true);
  if (plain === null) return starts;
  if (starts === null) return plain;
  return Math.max(plain, starts);
}

/** 이름(`title`)에 맞는 것을 경로(`detail`)에만 맞는 것보다 앞에. 같은 점수는 원래 차례. */
export function fuzzyRank<T>(items: readonly T[], query: string, key: (item: T) => { title: string; detail?: string }): T[] {
  const scored: { offset: number; score: number; item: T }[] = [];
  items.forEach((item, offset) => {
    const keys = key(item);
    const title = fuzzyScore(query, keys.title);
    if (title !== null) {
      scored.push({ offset, score: title * 2 + 1000, item });
      return;
    }
    const detail = keys.detail === undefined ? null : fuzzyScore(query, keys.detail);
    if (detail !== null) scored.push({ offset, score: detail, item });
  });
  scored.sort((a, b) => (a.score !== b.score ? b.score - a.score : a.offset - b.offset));
  return scored.map((entry) => entry.item);
}
