import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { appendSplice, countNewLines, docSplice, spliceBetween } from "../src/core/splice.ts";
import { lineSeparatorFor } from "../src/core/lines.ts";

function apply(old: string, next: string): string {
  const separator = lineSeparatorFor(old);
  const state = EditorState.create({ doc: old, extensions: EditorState.lineSeparator.of(separator) });
  const splice = docSplice(state.sliceDoc(), next, separator);
  if (!splice) return old;
  return state.update({ changes: splice }).state.sliceDoc();
}

test("바뀐 가운데만 — 앞뒤의 같은 부분은 둔다", () => {
  assert.equal(spliceBetween("같다", "같다"), null);
  assert.deepEqual(spliceBetween("하나\n둘\n셋\n", "하나\n이\n셋\n"), { from: 3, to: 4, insert: "이" });
  assert.deepEqual(spliceBetween("abc", "abXc"), { from: 2, to: 2, insert: "X" });
  assert.deepEqual(spliceBetween("abc", ""), { from: 0, to: 3, insert: "" });
});

test("이모지 반쪽 · CRLF 가운데에서 자르지 않는다 — CodeMirror를 지나도 글이 새 글과 같다", () => {
  const pairs: [string, string][] = [
    ["a😀b", "a😃b"],
    ["하나\r\n둘\r\n", "하나\r\n셋\r\n"],
    ["하나\r\n", "하나\r\r\n"],
    ["줄\r\n끝", "줄\r\n\r\n끝"],
    ["a\r\nb", "a\rX\nb"],
  ];
  for (const [old, next] of pairs) {
    const splice = spliceBetween(old, next)!;
    const cut = (text: string, at: number) =>
      (text.charCodeAt(at - 1) === 13 && text.charCodeAt(at) === 10) || (text.charCodeAt(at) >= 0xdc00 && text.charCodeAt(at) <= 0xdfff);
    assert.ok(!cut(old, splice.from) && !cut(old, splice.to), `${JSON.stringify(old)}: 자르는 자리 ${splice.from}..${splice.to}`);
    assert.equal(apply(old, next), next, JSON.stringify(next));
  }
});

test("끝에 붙이기 — `\\r\\n`을 둘로 나눠 쓴 로그도 한 줄 끝이 된다", () => {
  const separator = "\r\n";
  let state = EditorState.create({ doc: "하나\r", extensions: EditorState.lineSeparator.of(separator) });
  const splice = appendSplice(state.doc.length, state.sliceDoc(state.doc.length - 1), "\n둘\r\n", separator);
  assert.deepEqual(splice, { from: 2, to: 3, insert: "\r\n둘\r\n" });
  state = state.update({ changes: splice }).state;
  assert.equal(state.doc.lines, 3, "하나 · 둘 · 빈 줄");
  assert.equal(state.doc.line(2).text, "둘");
  assert.equal(state.sliceDoc(), "하나\r\n둘\r\n");
  assert.deepEqual(appendSplice(4, "a", "b", "\n"), { from: 4, to: 4, insert: "b" });
});

test("CRLF 문서 — CodeMirror는 줄 끝을 한 자리로 센다. 글자 수로 센 자리를 그대로 쓰면 엉뚱한 곳을 바꾼다", () => {
  const old = "하나\r\n둘\r\n셋\r\n";
  const state = EditorState.create({ doc: old, extensions: EditorState.lineSeparator.of("\r\n") });
  assert.equal(state.doc.length, old.length - 3, "줄 끝 셋이 하나씩 덜 센다");
  assert.deepEqual(spliceBetween(old, "하나\r\n둘\r\n넷\r\n"), { from: 7, to: 8, insert: "넷" });
  assert.deepEqual(docSplice(old, "하나\r\n둘\r\n넷\r\n", "\r\n"), { from: 5, to: 6, insert: "넷" });
  assert.equal(apply(old, "하나\r\n둘\r\n넷\r\n"), "하나\r\n둘\r\n넷\r\n");
});

test("붙은 줄 수", () => {
  assert.equal(countNewLines("a\nb\n"), 2);
  assert.equal(countNewLines("a\r\nb\r\n"), 2);
  assert.equal(countNewLines("끝 없는 조각"), 1);
});
