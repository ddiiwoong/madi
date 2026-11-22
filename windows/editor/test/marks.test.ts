import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorSelection, EditorState } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { caretLines, previewMarks, type PreviewMark } from "../src/core/marks.ts";
import { outline } from "../src/core/outline.ts";
import { fileKind } from "../src/core/kind.ts";

function stateOf(doc: string, caret = doc.length): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(caret),
    extensions: markdown({ base: markdownLanguage }),
  });
  ensureSyntaxTree(state, doc.length, 5000);
  return state;
}

function marks(state: EditorState): PreviewMark[] {
  return previewMarks(state, [{ from: 0, to: state.doc.length }], caretLines(state));
}

const hidden = (state: EditorState) =>
  marks(state).filter((mark) => mark.type === "hide").map((mark) => state.sliceDoc(mark.from, mark.to));

const doc = [
  "# 제목 #",
  "**굵게** *기울임* `코드` ~~취소~~",
  "[링크](https://a.b \"t\") <https://c.d>",
  "> 인용",
  "- 하나",
  "  - 둘",
  "---",
  "```swift",
  "# 코드 안",
  "```",
  "",
].join("\n");

test("캐럿이 없는 줄 — 표식을 숨긴다", () => {
  const state = stateOf(doc);
  assert.deepEqual(hidden(state), [
    "# ", " #",
    "**", "**", "*", "*", "`", "`", "~~", "~~",
    "[", "](https://a.b \"t\")", "<", ">",
    "> ",
  ]);
  const list = marks(state);
  assert.ok(list.some((mark) => mark.type === "line" && mark.style === "h1" && mark.at === 0));
  assert.deepEqual(
    list.filter((mark) => mark.type === "bullet").map((mark) => (mark.type === "bullet" ? mark.depth : -1)),
    [0, 1], "글머리 표 — 깊이마다",
  );
  assert.equal(list.filter((mark) => mark.type === "rule").length, 1);
  const link = list.find(
    (mark): mark is Extract<PreviewMark, { type: "inline" }> =>
      mark.type === "inline" && mark.style === "link" && mark.url === "https://a.b",
  );
  assert.ok(link && state.sliceDoc(link.from, link.to) === "링크");
  const codeLines = list.filter((mark) => mark.type === "line" && mark.style === "code").length;
  assert.equal(codeLines, 3, "펜스 둘과 그 사이 한 줄");
  assert.equal(list.filter((mark) => mark.type === "line" && mark.style === "fence").length, 2);
});

test("캐럿이 있는 줄은 원문 그대로 — 꾸밈은 남는다", () => {
  const state = stateOf(doc, doc.indexOf("굵게"));
  const shown = hidden(state);
  assert.ok(!shown.includes("**"), "둘째 줄의 ** 은 드러난다");
  assert.ok(shown.includes("# "), "다른 줄은 그대로 숨긴다");
  assert.ok(marks(state).some((mark) => mark.type === "inline" && mark.style === "strong"));
  const onBullet = stateOf(doc, doc.indexOf("- 하나") + 2);
  assert.equal(marks(onBullet).filter((mark) => mark.type === "bullet").length, 1, "캐럿 줄의 - 는 그대로");
});

test("보이는 구간이 둘이어도 겹친 마디는 한 번만", () => {
  const state = stateOf(doc);
  const one = previewMarks(state, [{ from: 0, to: state.doc.length }], caretLines(state)).length;
  const split = Math.floor(state.doc.length / 2);
  const two = previewMarks(state, [{ from: 0, to: split }, { from: split, to: state.doc.length }], caretLines(state)).length;
  assert.equal(two, one);
});

test("목차 — 코드 블록 안의 # 는 제목이 아니다", () => {
  const state = stateOf("# 하나\n\n## 둘 ##\n\n```\n# 아님\n```\n\n셋\n---\n");
  assert.deepEqual(outline(state).map((heading) => [heading.level, heading.title]), [[1, "하나"], [2, "둘"], [2, "셋"]]);
});

test("파일 종류 — 확장자로", () => {
  assert.equal(fileKind(null), "markdown");
  assert.equal(fileKind("C:\\글\\메모.MD"), "markdown");
  assert.equal(fileKind("notes.mdx"), "markdown");
  assert.equal(fileKind("D:/logs/app.log"), "log");
  assert.equal(fileKind("메모.txt"), "plainText");
  assert.equal(fileKind("README"), "plainText");
  assert.equal(fileKind(".hidden"), "plainText");
});
