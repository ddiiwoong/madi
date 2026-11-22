// 바깥에서 바뀐 글을 들이는 가장 작은 바꿔 끼우기 — macOS판 `TextSplice`와 같은 규칙.

import type { LineSeparator } from "./lines.ts";

export interface Splice {
  from: number;
  to: number;
  insert: string;
}

const isHigh = (code: number) => code >= 0xd800 && code <= 0xdbff;
const isLow = (code: number) => code >= 0xdc00 && code <= 0xdfff;

/**
 * 앞뒤가 같은 부분은 두고 다른 가운데만. 같으면 null.
 * 이모지(UTF-16 둘)의 가운데를 자르지 않고, `\r\n`의 가운데에서 끊지 않는다 — 끊으면 CodeMirror가 그 줄 끝을 줄 끝으로 다시 읽지 못한다.
 */
export function spliceBetween(old: string, next: string): Splice | null {
  if (old === next) return null;
  const limit = Math.min(old.length, next.length);
  let prefix = 0;
  while (prefix < limit && old.charCodeAt(prefix) === next.charCodeAt(prefix)) prefix++;
  if (prefix > 0) {
    const before = old.charCodeAt(prefix - 1);
    const splitsCrlf = before === 13 && (old.charCodeAt(prefix) === 10 || next.charCodeAt(prefix) === 10);
    if (isHigh(before) || splitsCrlf) prefix--;
  }
  let suffix = 0;
  while (
    suffix < limit - prefix
    && old.charCodeAt(old.length - 1 - suffix) === next.charCodeAt(next.length - 1 - suffix)
  ) suffix++;
  if (suffix > 0) {
    const atOld = old.length - suffix;
    const atNext = next.length - suffix;
    const first = old.charCodeAt(atOld);
    const splitsCrlf = first === 10 && (old.charCodeAt(atOld - 1) === 13 || next.charCodeAt(atNext - 1) === 13);
    if (isLow(first) || splitsCrlf) suffix--;
  }
  return { from: prefix, to: old.length - suffix, insert: next.slice(prefix, next.length - suffix) };
}

/**
 * 편집기의 자리로 옮긴 바꿔 끼우기. `old`는 편집기의 글(`state.sliceDoc()`), `next`는 디스크의 글.
 *
 * CodeMirror는 줄 끝을 하나의 자리로 센다 — 줄 끝이 `\r\n`인 문서에서는 글자 수로 센 자리와 어긋난다(줄마다 하나씩). 그래서 앞에
 * 있는 `\r\n`의 수만큼 뺀다. 줄 끝이 `\n` · `\r`이면 같다. 넣는 글은 디스크의 것 그대로다 — CodeMirror가 그 안의 `\r\n`을 줄 끝으로 읽는다.
 */
export function docSplice(old: string, next: string, separator: LineSeparator): Splice | null {
  const raw = spliceBetween(old, next);
  if (!raw || separator !== "\r\n") return raw;
  const position = (index: number) => {
    let pairs = 0;
    for (let at = old.indexOf("\r\n"); at !== -1 && at < index; at = old.indexOf("\r\n", at + 2)) pairs++;
    return index - pairs;
  };
  return { from: position(raw.from), to: position(raw.to), insert: raw.insert };
}

/**
 * 끝에 붙은 글을 넣는 자리. 문서가 `\r`로 끝나고 붙은 글이 `\n`으로 시작하면(쓰는 쪽이 `\r\n`을 둘로 나눠 씀) 그 `\r`까지 바꿔
 * 넣는다 — CodeMirror는 넣는 글 안의 줄 끝만 줄 끝으로 읽는다.
 */
export function appendSplice(length: number, lastChar: string, text: string, separator: LineSeparator): Splice {
  if (separator === "\r\n" && lastChar === "\r" && text.startsWith("\n")) {
    return { from: length - 1, to: length, insert: "\r" + text };
  }
  return { from: length, to: length, insert: text };
}

/** 붙은 줄 수 — `새 줄 N개 ↓`. 줄 끝이 없는 조각도 한 줄로 센다. */
export function countNewLines(text: string): number {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code === 10) count++;
    else if (code === 13 && text.charCodeAt(i + 1) !== 10) count++;
  }
  return Math.max(1, count);
}
