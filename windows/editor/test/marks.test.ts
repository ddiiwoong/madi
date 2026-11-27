import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorSelection, EditorState } from "@codemirror/state";
import { fullyParsed } from "./parsed.ts";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { caretLines, previewMarks, type PreviewMark } from "../src/core/marks.ts";
import { outline } from "../src/core/outline.ts";
import { fileKind } from "../src/core/kind.ts";
import { openingCaret } from "../src/core/blocks.ts";

function stateOf(doc: string, caret = doc.length): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(caret),
    extensions: markdown({ base: markdownLanguage }),
  });
  return fullyParsed(state);
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
    "```", "```",
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
  // 코드 블록은 블록째 — 캐럿이 블록의 어느 줄에 있든(가운데 줄이어도) 울타리가 드러난다.
  const inCode = stateOf(doc, doc.indexOf("# 코드 안"));
  assert.ok(!hidden(inCode).includes("```"), "블록 안에 캐럿 — 울타리는 원문");
  assert.ok(hidden(stateOf(doc, 0)).includes("```"), "블록 밖 — 울타리를 숨긴다");
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

// 사용자 — "프론트매터 보여주는것도 아래 --- 부분이 이상해". 앞머리를 마크다운으로 읽었다: 목록 뒤의 닫는 `---`는 구분선, `key: 값` 뒤의
// 닫는 `---`는 위 줄들을 제목으로 만드는 밑줄, `  - 항목`은 글머리 ●.
const listFront = ["---", "title: \"Dex\"", "tags:", "  - dex", "  - OIDC", "---", "", "## 본문", ""].join("\n");
const plainFront = ["---", "title: 하나", "date: 2018-07-26", "---", "", "# 본문", ""].join("\n");

test("앞머리 — 펼쳐도(캐럿이 안에) 마크다운으로 꾸미지 않는다: 구분선 · 글머리 · 제목 없음, 한 장의 상자에 `---`는 흐리게", () => {
  for (const [text, frontLines] of [[listFront, 6], [plainFront, 4]] as const) {
    const state = stateOf(text, 0);
    const all = marks(state);
    const frontEnd = state.doc.line(frontLines).to;
    const inFront = all.filter((mark) => ("at" in mark ? mark.at : mark.from) <= frontEnd);
    const styles = (line: number) => inFront.filter((mark) => mark.type === "line" && mark.at === state.doc.line(line).from)
      .map((mark) => mark.type === "line" ? mark.style : "").sort();
    assert.deepEqual(inFront.filter((mark) => mark.type !== "line"), [], "구분선 · 글머리 · 숨김이 없다");
    for (let line = 1; line <= frontLines; line++) {
      const expected = line === 1 || line === frontLines ? ["fence", "frontmatter"] : ["frontmatter"];
      assert.deepEqual(styles(line), expected, `${line}번 줄`);
    }
    // 앞머리 다음은 그대로 꾸민다.
    const heading = all.find((mark) => mark.type === "line" && mark.at > frontEnd && mark.style.startsWith("h"));
    assert.ok(heading, "본문의 제목");
  }
});

test("앞머리 — 목차에 들지 않는다(닫는 --- 가 제목 밑줄이 되지 않게)", () => {
  assert.deepEqual(outline(stateOf(plainFront)).map((heading) => heading.title), ["본문"]);
  assert.deepEqual(outline(stateOf(listFront)).map((heading) => heading.title), ["본문"]);
  // 앞머리가 없는 문서의 Setext 제목은 그대로.
  assert.deepEqual(outline(stateOf("제목\n---\n")).map((heading) => heading.title), ["제목"]);
});

test("앞머리 — 파일을 열면 캐럿은 그 다음 줄(카드로 보이게), 없으면 맨 처음", () => {
  const front = stateOf(plainFront).doc;
  assert.equal(openingCaret(front), front.line(5).from);
  assert.equal(openingCaret(stateOf("# 그냥\n").doc), 0);
  // 앞머리뿐인 문서 — 문서 끝.
  const only = stateOf("---\na: 1\n---").doc;
  assert.equal(openingCaret(only), only.length);
  // 닫지 않은 앞머리는 앞머리가 아니다.
  assert.equal(openingCaret(stateOf("---\na: 1\n\n본문\n").doc), 0);
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
