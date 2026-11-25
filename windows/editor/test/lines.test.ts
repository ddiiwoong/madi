import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { lineSeparatorFor, type LineSeparator } from "../src/core/lines.ts";

const samples: [string, string, LineSeparator][] = [
  ["LF", "하나\n둘\n", "\n"],
  ["CRLF", "하나\r\n둘\r\n", "\r\n"],
  ["CR", "하나\r둘\r", "\r"],
  ["LF와 CRLF가 섞임", "하나\r\n둘\n셋", "\n"],
  ["CR과 LF가 섞임", "하나\r둘\n", "\n"],
  ["줄 끝 없음", "한 줄", "\n"],
  ["빈 글", "", "\n"],
  ["빈 줄만 CRLF", "\r\n\r\n", "\r\n"],
];

test("줄 끝 고르기", () => {
  for (const [name, text, expected] of samples) {
    assert.equal(lineSeparatorFor(text), expected, name);
  }
});

test("고른 줄 끝이면 CodeMirror를 지나도 글이 그대로다", () => {
  for (const [name, text] of samples) {
    const state = EditorState.create({ doc: text, extensions: EditorState.lineSeparator.of(lineSeparatorFor(text)) });
    assert.equal(state.sliceDoc(), text, name);
  }
});

test("정하지 않으면 CodeMirror가 CRLF를 LF로 바꾼다 — 그래서 고른다", () => {
  const state = EditorState.create({ doc: "하나\r\n둘\r\n" });
  assert.equal(state.sliceDoc(), "하나\n둘\n");
  // `doc.toString()`은 정한 줄 끝과 상관없이 늘 LF로 잇는다 — 글을 꺼낼 때는 `sliceDoc()`을 쓴다.
  const kept = EditorState.create({ doc: "하나\r\n둘", extensions: EditorState.lineSeparator.of("\r\n") });
  assert.equal(kept.doc.toString(), "하나\n둘");
  assert.equal(kept.sliceDoc(), "하나\r\n둘");
});
