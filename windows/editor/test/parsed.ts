// 시험의 상태를 문서 끝까지 읽힌 나무로. CodeMirror는 상태를 만들 때 앞 3000자만, 그것도 20ms 안에 읽고, 그 나무를 상태에 묶어 둔다
// (`syntaxTree(state)`). `ensureSyntaxTree`가 나머지를 읽어도 이미 만든 상태의 나무는 그대로다 — 빈 바꿈 하나로 새 상태를 만들어야 다 읽힌
// 나무가 실린다. 그러지 않으면 바쁜 CI에서 문서 뒤쪽이 없는 것처럼 보였다(stage2의 블록 시험 — 표까지만 읽혔다).

import assert from "node:assert/strict";
import type { EditorState } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";

export function fullyParsed(state: EditorState): EditorState {
  assert.ok(ensureSyntaxTree(state, state.doc.length, 5000), "5초 안에 문서를 다 읽지 못했다");
  const next = state.update({}).state;
  assert.equal(syntaxTree(next).length, next.doc.length, "시험의 상태에 덜 읽힌 나무가 실렸다");
  return next;
}
