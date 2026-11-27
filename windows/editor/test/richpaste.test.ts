import { test } from "node:test";
import assert from "node:assert/strict";
import { markdownLanguage } from "@codemirror/lang-markdown";
import { htmlToMarkdown, placePasted } from "../src/core/richpaste.ts";
import { parseHtml } from "./html.ts";

const paste = (html: string) => htmlToMarkdown(parseHtml(html));

/** 마디의 편집기(GFM)가 읽은 마디 이름 — 옮긴 글이 정말 그 서식으로 읽히는지 본다(`**`가 글자로 남으면 없다). */
function nodes(markdown: string): string[] {
  const names: string[] = [];
  markdownLanguage.parser.parse(markdown).iterate({ enter: (node) => void names.push(node.name) });
  return names;
}

const count = (markdown: string, name: string) => nodes(markdown).filter((node) => node === name).length;

test("서식 붙여넣기 — Google 문서: 감싼 <b style=font-weight:normal>은 굵게가 아니고, 굵게 · 기울임은 스타일로", () => {
  const html = `<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1">`
    + `<h1 dir="ltr"><span style="font-size:20pt;font-family:Arial;font-weight:400;">회의록</span></h1>`
    + `<p dir="ltr"><span style="font-family:Arial;font-weight:400;">오늘은 </span><span style="font-family:Arial;font-weight:700;">새 기능</span>`
    + `<span style="font-family:Arial;font-weight:400;">과 </span><span style="font-family:Arial;font-style:italic;">기울임</span>`
    + `<span style="font-family:Arial;"> · </span><a href="https://example.com/a b" style="text-decoration:none;">`
    + `<span style="font-family:Arial;color:#1155cc;text-decoration:underline;">링크</span></a></p><br>`
    + `<ul><li aria-level="1"><p role="presentation"><span style="font-family:Arial;">하나</span></p></li>`
    + `<ul><li aria-level="2"><p role="presentation"><span style="font-family:Arial;">하나-1</span></p></li></ul>`
    + `<li aria-level="1"><p role="presentation"><span style="font-family:Arial;">둘</span></p></li></ul>`
    + `<ul><li role="checkbox" aria-checked="true"><p><span>한 일</span></p></li></ul></b>`;
  assert.equal(paste(html), [
    "# 회의록",
    "",
    "오늘은 **새 기능**과 *기울임* · [링크](https://example.com/a%20b)",
    "",
    "- 하나",
    "  - 하나-1",
    "- 둘",
    "",
    "- [x] 한 일",
  ].join("\n"));
});

test("서식 붙여넣기 — Word: mso-list 문단은 목록(단계 · 번호 꼴), 표식 글자는 빼고, 빈 문단은 버린다", () => {
  const marker = (sign: string) => `<!--[if !supportLists]--><span style='font-family:Symbol'><span style='mso-list:Ignore'>${sign}`
    + `<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp; </span></span></span><!--[endif]-->`;
  const item = (list: string, level: number, sign: string, text: string) =>
    `<p class=MsoListParagraph style='margin-left:20.0pt;mso-list:${list} level${level} lfo1'>${marker(sign)}${text}<o:p></o:p></p>`;
  const html = `<html xmlns:o="urn:schemas-microsoft-com:office:office"><head><style>p.MsoNormal{margin:0}</style></head><body lang=KO>`
    + `<!--StartFragment--><p class=MsoTitle>보고서</p><h1><span lang=EN-US>1. 개요</span></h1>`
    + `<p class=MsoNormal><b>굵게</b> 그리고 <i>기울임</i>, <s>지움</s>, <u>밑줄</u><o:p></o:p></p>`
    + item("l0", 1, "·", "첫째") + item("l0", 2, "o", "<b>아래</b>") + item("l0", 3, "§", "더 아래") + item("l0", 1, "·", "둘째")
    + `<p class=MsoNormal><o:p>&nbsp;</o:p></p>`
    + item("l1", 1, "1.", "번호") + item("l1", 2, "가.", "하위") + item("l1", 1, "2.", "번호 둘")
    + `<p class=MsoNormal><span style='font-family:"Courier New"'>let x = 1</span>을 쓴다<o:p></o:p></p>`
    + `<!--EndFragment--></body></html>`;
  assert.equal(paste(html), [
    "# 보고서",
    "",
    "# 1. 개요",
    "",
    "**굵게** 그리고 *기울임*, ~~지움~~, 밑줄",
    "",
    "- 첫째",
    "  - **아래**",
    "    - 더 아래",
    "- 둘째",
    "",
    "1. 번호",
    "   1. 하위",
    "2. 번호 둘",
    "",
    "`let x = 1`을 쓴다",
  ].join("\n"));
});

test("서식 붙여넣기 — Word의 번호 붙은 제목은 번호를 되살린다(번호는 표식 칸에 있다)", () => {
  const html = `<h2 style='mso-list:l2 level2 lfo3'><!--[if !supportLists]--><span><span style='mso-list:Ignore'>1.2.<span>&nbsp;</span></span></span>`
    + `<!--[endif]-->범위</h2>`;
  assert.equal(paste(html), "## 1.2. 범위");
});

test("서식 붙여넣기 — 표: 첫 줄이 머리(머리 칸의 굵게는 뺀다), 맞춤, 합친 칸은 빈 칸으로, `|`는 이스케이프", () => {
  const word = `<table class=MsoTableGrid border=1><tr><td><p class=MsoNormal><b>이름<o:p></o:p></b></p></td>`
    + `<td><p class=MsoNormal><b>값</b></p></td></tr><tr><td><p class=MsoNormal>a|b</p><p>둘째 문단</p></td>`
    + `<td><p class=MsoNormal><code>x|y</code></p></td></tr></table>`;
  assert.equal(paste(word), "| 이름 | 값 |\n| --- | --- |\n| a\\|b 둘째 문단 | `x|y` |");

  const excel = `<html><body><table border=0><!--StartFragment--><tr><td align=center>이름</td><td align=right>수</td><td>비고</td></tr>`
    + `<tr><td rowspan=2>사과</td><td align=right>3</td><td style="font-weight:700">좋음</td></tr><tr><td align=right>4</td><td></td></tr>`
    + `<tr><td colspan=2>합계</td><td>7</td></tr><!--EndFragment--></table></body></html>`;
  const table = paste(excel)!;
  assert.equal(table, [
    "| 이름 | 수 | 비고 |",
    "| :---: | ---: | --- |",
    "| 사과 | 3 | **좋음** |",
    "|  | 4 |  |",
    "| 합계 |  | 7 |",
  ].join("\n"));
  assert.equal(count(table, "Table"), 1);
  assert.equal(count(table, "TableRow"), 3);
});

test("서식 붙여넣기 — 웹 페이지: 제목 · 코드 · 코드 블록(언어) · 인용 · 할 일 · 구분선 · 그림", () => {
  const html = `<h2 style="color: rgb(31, 35, 40);">설치</h2><p><span style="font-weight: 400;">명령은 <code>npm i</code>, `
    + `파일은 *.md와 snake_case, 5 * 3, C:\\Users, 3~5개</span></p>`
    + `<div class="highlight highlight-source-shell"><pre>npm install\nnpm test\n</pre></div>`
    + `<blockquote><p>인용 <strong>굵게</strong></p><p>둘째 줄</p></blockquote>`
    + `<ul class="contains-task-list"><li class="task-list-item"><input type="checkbox" disabled checked> 끝낸 일</li>`
    + `<li class="task-list-item"><input type="checkbox" disabled> 남은 일</li></ul><hr>`
    + `<p><img src="https://example.com/a.png" alt="그림 [1]"> <img src="data:image/png;base64,AAAA" alt="x">`
    + `<img src="file:///C:/Users/me/AppData/Local/Temp/msohtmlclip1/01/clip_image001.png"></p>`;
  const markdown = paste(html)!;
  assert.equal(markdown, [
    "## 설치",
    "",
    "명령은 `npm i`, 파일은 \\*.md와 snake_case, 5 * 3, C:\\Users, 3~5개",
    "",
    "```shell",
    "npm install",
    "npm test",
    "```",
    "",
    "> 인용 **굵게**",
    ">",
    "> 둘째 줄",
    "",
    "- [x] 끝낸 일",
    "- [ ] 남은 일",
    "",
    "---",
    "",
    "![그림 \\[1\\]](https://example.com/a.png)",
  ].join("\n"));
  for (const name of ["ATXHeading2", "InlineCode", "FencedCode", "Blockquote", "Task", "HorizontalRule", "Image"]) {
    assert.equal(count(markdown, name) > 0, true, name);
  }
  // `\*.md`의 `*`는 글자다 — 기울임이 생기지 않는다.
  assert.equal(count(markdown, "Emphasis"), 0);
});

test("서식 붙여넣기 — 목록: 시작 번호, 항목 안의 문단 · 하위 목록, 할 일이 아닌 [ ]", () => {
  const html = `<ol start="3"><li><p>셋</p><p>셋의 둘째 문단</p><ul><li>아래</li></ul></li><li>[ ] 상자 아님</li></ol>`;
  const markdown = paste(html)!;
  assert.equal(markdown, "3. 셋\n\n   셋의 둘째 문단\n   - 아래\n4. \\[ ] 상자 아님");
  assert.equal(count(markdown, "OrderedList"), 1);
  assert.equal(count(markdown, "BulletList"), 1);
  assert.equal(count(markdown, "Task"), 0);
});

test("서식 붙여넣기 — 굵게 · 기울임이 겹치고 이어져도 표식은 바뀌는 자리에만, 공백은 표식 바깥에", () => {
  assert.equal(paste(`<p><b>굵게 <i>둘 다</i></b><i> 기울임만</i> 그리고 <b>a</b><b>b</b></p>`),
    "**굵게 *둘 다*** *기울임만* 그리고 **ab**");
  assert.equal(paste(`<p><b>앞 </b>뒤 <i> 기울임 </i>끝</p>`), "**앞** 뒤 *기울임* 끝");
  // 같은 스타일로 쪼개진 글(Chromium · Word는 낱말마다 <span>을 단다)은 합쳐서 이스케이프를 본다 — `5 * 3`의 `*`는 글자 그대로.
  assert.equal(paste(`<p><span>5 </span><span>* 3</span> <b>b</b></p>`), "5 * 3 **b**");
  // 기울임이 더 오래 간다 — 바깥에 둔다(닫았다 다시 열지 않게).
  const mixed = paste(`<p><i><b>둘</b>하나</i></p>`)!;
  assert.equal(mixed, "***둘**하나*");
  assert.equal(count(mixed, "StrongEmphasis"), 1);
  assert.equal(count(mixed, "Emphasis"), 1);
  // 링크 글이 굵으면 링크 안에.
  assert.equal(paste(`<p><a href="https://a.kr"><b>굵은 링크</b></a>를</p>`), "[**굵은 링크**](https://a.kr)를");
});

test("서식 붙여넣기 — 문장 부호 바로 옆의 표식(한글 조사)도 굵게로 읽힌다", () => {
  const closing = paste(`<p><b>마디(Madi)</b>는 <b>"따옴표"</b>를</p>`)!;
  assert.equal(closing, `**마디(Madi**)는 **"따옴표**"를`);
  assert.equal(count(closing, "StrongEmphasis"), 2);
  const opening = paste(`<p>이것은<b>(중요)</b>.</p>`)!;
  assert.equal(opening, "이것은(**중요)**.");
  assert.equal(count(opening, "StrongEmphasis"), 1);
  // 옮길 필요가 없으면 그대로.
  assert.equal(paste(`<p><b>마디(Madi)</b> 는</p>`), "**마디(Madi)** 는");
});

test("서식 붙여넣기 — 줄바꿈 · 줄 머리의 표식 · 코드 조각의 `", () => {
  assert.equal(paste(`<p>1. 번호처럼 <b>굵게<br>다음 줄</b><br># 샵<br>- 대시<br>&gt; 꺾쇠<br>===<br>$$x$$</p>`),
    "1\\. 번호처럼 **굵게**\n**다음 줄**\n\\# 샵\n\\- 대시\n\\> 꺾쇠\n\\===\n\\$$x$$");
  assert.equal(paste(`<p>코드 <code>a\`b</code> 와 <code>\`x</code></p>`), "코드 ``a`b`` 와 `` `x ``");
  assert.equal(paste(`<p><b>a</b> &lt;div&gt; &amp;amp; [x](y) ~~z~~</p>`), "**a** \\<div> \\&amp; [x\\](y) \\~\\~z\\~\\~");
});

test("서식 붙여넣기 — 코드 블록: ChatGPT처럼 <pre> 안에 단추가 있으면 <code>만, 펜스는 코드의 ` 보다 길게", () => {
  const html = `<pre><div><div>python</div><div>Copy code</div></div><div><code class="!whitespace-pre hljs language-python">`
    + "print(\"hi\")\nx = ```a```</code></div></pre><p>본문</p>";
  assert.equal(paste(html), "````python\nprint(\"hi\")\nx = ```a```\n````\n\n본문");
  // 줄을 <div>로 그리는 사이트
  assert.equal(paste(`<h3>예</h3><pre class="lang-js"><div>let a</div><div>let b</div></pre>`), "### 예\n\n```js\nlet a\nlet b\n```");
});

test("서식 붙여넣기 — 옮기지 않는다: 코드 편집기 · <pre> 하나 · 서식 없는 글 · Excel 한 칸 · 빈 것", () => {
  const vscode = `<meta charset='utf-8'><div style="color: #cccccc;background-color: #1f1f1f;font-family: Consolas, 'Courier New', monospace;`
    + `font-weight: normal;font-size: 14px;line-height: 19px;white-space: pre;"><div><span style="color: #569cd6;">const</span> a = 1;</div></div>`;
  assert.equal(paste(vscode), null);
  assert.equal(paste(`<pre style="font-family:'JetBrains Mono',monospace;"><span>fun main()</span></pre>`), null);
  assert.equal(paste(`<span style="font-family: Arial; color: red; text-decoration: underline">그냥 글 *별표* 와 snake_case</span>`), null);
  assert.equal(paste(`<p>문단 하나</p><p>문단 둘</p>`), null);
  assert.equal(paste(`<table><tr><td>하나</td></tr></table>`), null);
  assert.equal(paste(`<table><tr><td>한 줄</td><td>두 칸</td></tr></table>`), null);
  assert.equal(paste(``), null);
  assert.equal(paste(`<p><b> </b></p>`), null);
});

test("서식 붙여넣기 — 안전: 스크립트 링크는 글만, 숨긴 글 · 스타일 · 스크립트는 버린다", () => {
  assert.equal(paste(`<p><a href="javascript:alert(1)">누름</a> <a href=" data:text/html,x">데이터</a> <b>굵게</b></p>`),
    "누름 데이터 **굵게**");
  assert.equal(paste(`<style>p{color:red}</style><script>alert(1)</script><p><b>보임</b><span style="display:none">숨김</span>`
    + `<span hidden>숨김</span><span style="mso-hide:all">숨김</span></p>`), "**보임**");
});

test("서식 붙여넣기 — 레이아웃 표(메일)는 풀어서 글로", () => {
  const html = `<table role="presentation"><tr><td><h2>안내</h2></td></tr><tr><td><p><b>날짜</b>: 내일</p></td></tr></table>`;
  assert.equal(paste(html), "## 안내\n\n**날짜**: 내일");
  const nested = `<table><tr><td><table><tr><td><b>안</b></td><td>표</td></tr></table></td></tr></table>`;
  assert.equal(paste(nested), "**안**\n\n표");
});

test("서식 붙여넣기 — 놓는 자리: 블록은 제 줄에(앞뒤에 글이 있으면 빈 줄), 한 줄 글은 그 자리에", () => {
  assert.equal(placePasted("**굵게**", "앞 ", " 뒤"), "**굵게**");
  assert.equal(placePasted("# 제목", "앞 글", ""), "\n\n# 제목");
  assert.equal(placePasted("- a\n- b", "", "뒤 글"), "- a\n- b\n\n");
  assert.equal(placePasted("| a |\n| --- |", "  ", "  "), "| a |\n| --- |");
});
