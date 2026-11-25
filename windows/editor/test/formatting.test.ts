// 서식 명령 — macOS판 `MarkdownFormattingTests`를 그대로 옮겼다. 글은 `«고른 글»`과 `‸`(캐럿)로 적는다. 앞이 편집 전, 뒤가 편집 뒤다.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  applyEdit, codeBlock, heading, link, rule, table, toggleBlock, toggleInline,
  type BlockStyle, type FormatEdit, type Span,
} from "../src/core/formatting.ts";
import { normalizeLineBreaks } from "../src/core/lines.ts";

type Rule = (text: string, selection: Span) => FormatEdit | null;

function run(marked: string, rule_: Rule): string | null {
  let text: string;
  let selection: Span;
  if (marked.includes("‸")) {
    const at = marked.indexOf("‸");
    text = marked.replace("‸", "");
    selection = { from: at, to: at };
  } else {
    const open = marked.indexOf("«");
    assert.notEqual(open, -1, "시험의 전제 — 캐럿이나 선택이 있다");
    const without = marked.replace("«", "");
    const close = without.indexOf("»");
    text = without.replace("»", "");
    selection = { from: open, to: close };
  }
  const edit = rule_(text, selection);
  if (!edit) return null;
  const result = applyEdit(text, edit);
  const { from, to } = edit.selection;
  if (from === to) return result.slice(0, from) + "‸" + result.slice(from);
  return result.slice(0, from) + "«" + result.slice(from, to) + "»" + result.slice(to);
}

const bold: Rule = (s, r) => toggleInline("bold", s, r);
const italic: Rule = (s, r) => toggleInline("italic", s, r);
const level = (n: number): Rule => (s, r) => heading(n, s, r);
const block = (kind: BlockStyle): Rule => (s, r) => toggleBlock(kind, s, r);

test("굵게 — 감싸고 푼다", () => {
  assert.equal(run("앞 «글» 뒤", bold), "앞 **«글»** 뒤");
  assert.equal(run("앞 **«글»** 뒤", bold), "앞 «글» 뒤", "표식이 고른 글 바로 밖에 있으면 푼다");
  assert.equal(run("앞 «**글**» 뒤", bold), "앞 «글» 뒤", "고른 글의 양 끝이 표식이어도 푼다");
});

test("빈 선택 — 표식 한 쌍을 넣고, 빈 쌍은 지운다", () => {
  assert.equal(run("앞 ‸뒤", bold), "앞 **‸**뒤");
  assert.equal(run("앞 **‸**뒤", bold), "앞 ‸뒤");
  assert.equal(run("앞 **‸**뒤", italic), "앞 ***‸***뒤", "굵게의 빈 쌍은 기울임의 빈 쌍이 아니다");
});

test("기울임 · 굵게가 `*`를 함께 써도 헷갈리지 않는다", () => {
  assert.equal(run("«**글**»", italic), "*«**글**»*", "굵은 글을 기울이면 ***");
  assert.equal(run("***«글»***", italic), "**«글»**", "*** 에서 기울임만 뺀다");
  assert.equal(run("***«글»***", bold), "*«글»*", "*** 에서 굵게만 뺀다");
  assert.equal(run("*«글»*", bold), "***«글»***");
});

test("앞뒤 공백과 줄 앞의 블록 표식은 감싸지 않는다", () => {
  assert.equal(run("앞« 글 »뒤", bold), "앞 **«글»** 뒤");
  assert.equal(run("«# 제목»", bold), "# **«제목»**");
  assert.equal(run("«- [ ] 할 일»", bold), "- [ ] **«할 일»**");
  assert.equal(run("앞«   »뒤", bold), null, "공백만 고르면 할 것이 없다");
  assert.equal(run("«**»글**", bold), "**«**»**글**", "표식만 고른 것은 꾸민 글이 아니다 — 지우지 않는다");
});

test("여러 줄은 줄마다", () => {
  assert.equal(run("«첫 줄\n둘째 줄»", bold), "**«첫 줄**\n**둘째 줄»**");
  assert.equal(run("**«첫 줄**\n**둘째 줄»**", bold), "«첫 줄\n둘째 줄»", "모든 줄이 굵으면 모두 푼다");
  assert.equal(run("«**첫 줄**\n둘째 줄»", bold), "**«첫 줄**\n**둘째 줄»**", "안 굵은 줄만 감싼다");
  assert.equal(run("«가\n\n나»", bold), "**«가**\n\n**나»**", "빈 줄은 건너뛴다");
});

test("취소선 · 인라인 코드", () => {
  assert.equal(run("«글»", (s, r) => toggleInline("strikethrough", s, r)), "~~«글»~~");
  assert.equal(run("«let x»", (s, r) => toggleInline("code", s, r)), "`«let x»`");
  assert.equal(run("`«let x»`", (s, r) => toggleInline("code", s, r)), "«let x»");
});

test("제목 — 정하고 바꾸고 다시 누르면 본문", () => {
  assert.equal(run("‸제목", level(2)), "## ‸제목");
  assert.equal(run("## ‸제목", level(2)), "‸제목", "같은 단계를 다시 누르면 본문");
  assert.equal(run("### 제‸목", level(1)), "# 제‸목");
  assert.equal(run("## 제목‸", level(0)), "제목‸", "본문");
  assert.equal(run("##‸ 제목", level(4)), "#### ‸제목", "지운 표식 안의 캐럿은 새 표식 뒤로");
  assert.equal(run("제목‸", level(0)), null, "이미 본문");
});

test("빈 줄에서는 제목 · 목록 · 인용을 시작한다", () => {
  assert.equal(run("앞\n‸\n뒤", level(2)), "앞\n## ‸\n뒤");
  assert.equal(run("앞\n‸\n뒤", level(0)), null, "본문은 할 것이 없다");
  assert.equal(run("‸", block("bullet")), "- ‸");
  assert.equal(run("‸", block("numbered")), "1. ‸");
  assert.equal(run("‸", block("task")), "- [ ] ‸");
  assert.equal(run("앞\n‸", block("quote")), "앞\n> ‸");
});

test("띄어 쓰지 않은 #은 제목이 아니다 · 여러 줄 · 빈 줄은 건너뜀", () => {
  assert.equal(run("#해시‸", level(1)), "# #해시‸");
  assert.equal(run("«가\n\n나»", level(3)), "### «가\n\n### 나»");
  assert.equal(run("«# 가\n## 나»", level(2)), "«## 가\n## 나»", "단계가 섞이면 모두 그 단계로");
});

test("목록 — 글머리 · 번호(들여쓰기마다 다시 센다) · 할 일(체크한 것은 그대로)", () => {
  assert.equal(run("«가\n나»", block("bullet")), "- «가\n- 나»");
  assert.equal(run("- «가\n- 나»", block("bullet")), "«가\n나»");
  assert.equal(run("«1. 가\n2. 나»", block("bullet")), "«- 가\n- 나»", "번호 목록을 글머리로");
  assert.equal(run("«가\n  나\n  다\n라»", block("numbered")), "1. «가\n  1. 나\n  2. 다\n2. 라»");
  assert.equal(run("«가\n  나\n다\n  라»", block("numbered")), "1. «가\n  1. 나\n2. 다\n  1. 라»", "바깥 항목 뒤의 안쪽은 1부터 다시");
  assert.equal(run("«- 가\n- 나»", block("numbered")), "«1. 가\n2. 나»");
  assert.equal(run("«1. 가\n2. 나»", block("numbered")), "«가\n나»");
  assert.equal(run("‸할 일", block("task")), "- [ ] ‸할 일");
  assert.equal(run("«- [x] 끝\n남음»", block("task")), "«- [x] 끝\n- [ ] 남음»", "체크한 것은 그대로");
  assert.equal(run("- [x] 끝‸", block("task")), "끝‸");
});

test("인용은 사이의 빈 줄도 `>`로 이어 한 덩이로", () => {
  assert.equal(run("«가\n\n나»", block("quote")), "> «가\n>\n> 나»");
  assert.equal(run("> «가\n>\n> 나»", block("quote")), "«가\n\n나»");
});

test("링크 — 이어 쓸 자리에 캐럿", () => {
  assert.equal(run("‸", link), "[‸]()");
  assert.equal(run("«마디»", link), "[마디](‸)", "글을 고르면 주소를 쓸 자리로");
  assert.equal(run("«https://example.com»", link), "[‸](https://example.com)", "주소를 고르면 글을 쓸 자리로");
  assert.equal(run("«가\n나»", link), null, "여러 줄은 링크가 될 수 없다");
});

test("코드 블록 · 표 · 구분선", () => {
  assert.equal(run("‸", codeBlock), "```\n‸\n```");
  assert.equal(run("«let x = 1»", codeBlock), "```‸\nlet x = 1\n```", "캐럿은 언어 이름을 쓸 자리");
  assert.equal(run("«```\nlet x = 1\n```»", codeBlock), "«let x = 1»");
  assert.equal(run("앞\n«a\nb»\n뒤", codeBlock), "앞\n```‸\na\nb\n```\n뒤");
  const table_: Rule = (s, r) => table(s, r);
  assert.equal(run("‸", table_), "| «열 1» | 열 2 |\n| --- | --- |\n|  |  |");
  assert.equal(run("글‸", table_), "글\n\n| «열 1» | 열 2 |\n| --- | --- |\n|  |  |");
  // 글 바로 아래의 `---`는 제목 2가 된다 — 빈 줄을 둔다.
  assert.equal(run("글‸\n다음", rule), "글\n\n---‸\n\n다음");
  assert.equal(run("글\n‸\n다음", rule), "글\n\n---‸\n\n다음");
  assert.equal(run("글\n\n‸\n\n다음", rule), "글\n\n---‸\n\n다음");
});

test("편집은 고친 줄만 바꾼다 — 실행 취소가 그 범위만 되돌린다", () => {
  const text = "머리\n\n가\n나\n\n꼬리";
  const from = text.indexOf("가");
  const edit = toggleBlock("bullet", text, { from, to: from + "가\n나".length })!;
  assert.deepEqual([edit.from, edit.to], [from, from + "가\n".length], "첫 줄 앞부터 마지막 고친 자리까지");
  assert.equal(applyEdit(text, edit), "머리\n\n- 가\n- 나\n\n꼬리");
});

test("붙여 넣는 글의 줄 끝 — 문서의 줄 끝 하나로(CRLF 문서에 LF가, LF 문서에 CR이 섞이지 않게)", () => {
  assert.equal(normalizeLineBreaks("가\r\n나\n다\r라", "\r\n"), "가\r\n나\r\n다\r\n라");
  assert.equal(normalizeLineBreaks("가\r\n나\r\n", "\n"), "가\n나\n");
  assert.equal(normalizeLineBreaks("줄 끝 없음", "\r\n"), "줄 끝 없음");
});
