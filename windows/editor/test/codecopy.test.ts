import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { fullyParsed } from "./parsed.ts";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { codeBlockAt, codeText } from "../src/core/codecopy.ts";

function stateOf(doc: string): EditorState {
  const state = EditorState.create({ doc, extensions: markdown({ base: markdownLanguage }) });
  return fullyParsed(state);
}

/** `line`번 줄에서 찾은 블록과 그 블록이 베끼는 글. */
function copied(doc: string, line: number) {
  const state = stateOf(doc);
  const block = codeBlockAt(state, state.doc.line(line).from);
  return { block, text: block ? codeText(state.doc, block) : null };
}

test("코드 복사 — 펜스는 빼고 코드만, 블록의 어느 줄에서든 같은 블록", () => {
  const doc = "앞\n\n```swift\nlet 인사 = \"안녕\"\nprint(인사)\n```\n\n뒤\n";
  for (const line of [3, 4, 5, 6]) {
    const { block, text } = copied(doc, line);
    assert.deepEqual(block && { first: block.firstLine, last: block.lastLine, closed: block.closed, language: block.language },
      { first: 3, last: 6, closed: true, language: "swift" }, `${line}번 줄`);
    assert.equal(text, "let 인사 = \"안녕\"\nprint(인사)");
  }
  // 블록 밖의 줄 — 바로 앞 · 바로 뒤도.
  for (const line of [1, 2, 7, 8]) assert.equal(copied(doc, line).block, null, `${line}번 줄`);
});

test("코드 복사 — 목록 안의 블록은 펜스의 들여쓰기만큼 뺀다(그보다 깊은 들여쓰기는 남는다)", () => {
  const { block, text } = copied("- 목록\n  ```bash\n  ls\n    -la\n  ```\n", 3);
  assert.equal(block?.indent, 2);
  assert.equal(block?.language, "bash");
  assert.equal(text, "ls\n  -la");
  // 들여 쓴 펜스(맨 위 단계)의 줄이 펜스보다 덜 들여 써 있으면 있는 만큼만 뺀다. (목록 안에서는 그런 줄이 목록을 끝낸다 — 블록이 아니다.)
  assert.equal(copied("  ```\n  a\n b\nc\n  ```\n", 2).text, "a\nb\nc");
});

test("코드 복사 — 닫지 않은 블록은 마지막 줄까지(문서 끝의 빈 줄은 베끼지 않는다)", () => {
  assert.equal(copied("```py\nopen\nstill\n", 2).text, "open\nstill");
  assert.equal(copied("```py\nopen", 2).text, "open");
  assert.equal(copied("```py\nopen\nstill\n", 2).block?.closed, false);
  // 끝의 빈 줄도 상자로 칠해진다(`previewMarks`) — 그 줄에 마우스가 있어도 단추가 남는다.
  const tail = copied("```py\nopen\nstill\n", 4);
  assert.deepEqual(tail.block && [tail.block.firstLine, tail.block.lastLine], [1, 4]);
  assert.equal(tail.text, "open\nstill");
});

test("코드 복사 — 탭으로 들여 쓴 펜스(목록 안)는 탭 하나만큼 뺀다", () => {
  assert.equal(copied("- a\n\n\t```sh\n\tx\n\t\ty\n\t```\n", 4).text, "x\n\ty");
});

test("코드 복사 — 빈 블록 · ~~~ 펜스 · 정보 문자열의 첫 낱말", () => {
  assert.equal(copied("```\n```\n", 1).text, "");
  const tilde = copied("~~~ js title=\"a b\"\nx\n~~~\n", 2);
  assert.equal(tilde.block?.language, "js");
  assert.equal(tilde.text, "x");
  assert.equal(copied("```\nx\n```\n", 2).block?.language, null);
});

test("코드 복사 — 인용 안의 블록에는 단추가 없다(줄마다 붙은 > 를 베끼지 않게)", () => {
  assert.equal(copied("> ```\n> q\n> ```\n", 2).block, null);
});

test("코드 복사 — 블록이 둘이면 각각", () => {
  const doc = "```a\n1\n```\n```b\n2\n```\n";
  assert.equal(copied(doc, 2).text, "1");
  assert.equal(copied(doc, 5).text, "2");
  assert.equal(copied(doc, 4).block?.language, "b");
});
