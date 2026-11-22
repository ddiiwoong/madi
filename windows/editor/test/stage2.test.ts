import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorSelection, EditorState } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { parseAlign, parseTable, splitRow } from "../src/core/table.ts";
import { parseFrontMatter } from "../src/core/frontmatter.ts";
import { fuzzyRank, fuzzyScore } from "../src/core/fuzzy.ts";
import { clampSize, cssVariables, defaultSettings, normalizeSettings } from "../src/core/settings.ts";
import { escapeHtml, inlineHtml } from "../src/core/inline.ts";
import { renderedBlocks } from "../src/core/blocks.ts";
import { alertKind, caretLines, previewMarks, taskToggle } from "../src/core/marks.ts";
import { palettes, themeIds } from "../src/core/palette.ts";
import { imageSource } from "../src/core/image.ts";
import { catalog, settingsChange } from "../src/core/catalog.ts";

function stateOf(doc: string, caret = doc.length): EditorState {
  const state = EditorState.create({ doc, selection: EditorSelection.cursor(caret), extensions: markdown({ base: markdownLanguage }) });
  ensureSyntaxTree(state, doc.length, 5000);
  return state;
}

test("표 — 칸 나누기 · 맞춤 · 열 수", () => {
  assert.deepEqual(splitRow("| a | b \\| c | `x|y` |"), ["a", "b \\| c", "`x|y`"]);
  assert.deepEqual(splitRow("a|b"), ["a", "b"]);
  assert.deepEqual(parseAlign("|:--|:-:|--:|---|"), ["left", "center", "right", null]);
  assert.equal(parseAlign("| a | b |"), null);
  const table = parseTable(["| 이름 | 값 |", "|---|--:|", "| 하나 | 1 | 넘침 |", "| 둘 |"]);
  assert.deepEqual(table, { header: ["이름", "값"], align: [null, "right"], rows: [["하나", "1"], ["둘", ""]] });
  assert.equal(parseTable(["| a |"]), null);
});

test("앞머리 — macOS판과 같은 규칙", () => {
  const front = parseFrontMatter([
    "---", "title: \"제목\"", "tags: [가, '나', ]", "authors:", "  - 하나", "  - 둘", "summary: >", "  여러 줄", "  이어서",
    "# 주석", "  들여쓴 줄은 건너뜀", "empty:", "---", "본문",
  ]);
  assert.equal(front?.closingLine, 12);
  assert.deepEqual(front?.fields, [
    { key: "title", value: { kind: "scalar", text: "제목" } },
    { key: "tags", value: { kind: "list", items: ["가", "나"] } },
    { key: "authors", value: { kind: "list", items: ["하나", "둘"] } },
    { key: "summary", value: { kind: "scalar", text: "여러 줄 이어서" } },
    { key: "empty", value: { kind: "scalar", text: "" } },
  ]);
  assert.equal(parseFrontMatter(["---", "닫히지 않음"]), null);
  assert.equal(parseFrontMatter(["# 제목", "---"]), null);
  assert.equal(parseFrontMatter(["---", "...", "본문"])?.closingLine, 1, "`...`로도 닫는다");
});

test("거르기 — 이름에 맞는 것이 먼저, 대소문자 · 분음부호 무시, 한글", () => {
  assert.equal(fuzzyScore("", "무엇이든"), 0);
  assert.equal(fuzzyScore("xyz", "abc"), null);
  assert.ok(fuzzyScore("cafe", "Café Menu")! > 0);
  // macOS판 점수 그대로: "회 사 의 견"은 낱말 첫 글자 덤을 두 번 받아 "2026 회의록"보다 높다 — 이어 맞음은 낱말 속 흩어짐을 이긴다.
  assert.ok(fuzzyScore("회의", "2026 회의록.md")! > fuzzyScore("회의", "x회y의z.md")!, "이어서 맞는 쪽이 높다");
  assert.equal(fuzzyScore("회의", "회의록.md"), 22);
  assert.equal(fuzzyScore("회의", "회 사 의 견.md"), 21);
  const items = [
    { title: "notes.md", detail: "docs/회의" },
    { title: "회의록.md", detail: "docs" },
    { title: "readme.md", detail: "회의/old" },
  ];
  // 경로에만 맞는 둘 중에선 맨 앞에서 맞는 "회의/old"(22)가 "docs/회의"(16)보다 앞.
  assert.deepEqual(fuzzyRank(items, "회의", (item) => item).map((item) => item.title), ["회의록.md", "readme.md", "notes.md"]);
  assert.deepEqual(fuzzyRank(items, "", (item) => item).map((item) => item.title), ["notes.md", "회의록.md", "readme.md"]);
});

test("설정 — 모르는 값은 기본, 크기는 10~28", () => {
  assert.deepEqual(normalizeSettings(null), defaultSettings);
  const odd = normalizeSettings({ theme: "없는 테마", appearance: "dark", bodySize: 99, bodyFont: "  ", codeFont: "Consolas", loadsRemoteImages: "yes" });
  assert.equal(odd.theme, "standard");
  assert.equal(odd.appearance, "dark");
  assert.equal(odd.bodySize, 28);
  assert.equal(odd.bodyFont, null);
  assert.equal(odd.codeFont, "Consolas");
  assert.equal(odd.loadsRemoteImages, false, "참(true)만 켠다");
  assert.equal(clampSize(9.6), 10);
  assert.equal(clampSize(Number.NaN), 15);
});

test("CSS 변수 — 테마의 라이트 · 다크 색, 글꼴, 글 폭(본문 크기의 배수)", () => {
  const settings = { ...defaultSettings, theme: "github" as const, codeFont: "Consolas", bodySize: 16, documentWidth: "wide" as const };
  const light = cssVariables(settings, false);
  const dark = cssVariables(settings, true);
  assert.equal(light["--md-background"], "#FFFFFF");
  assert.equal(dark["--md-background"], "#0D1117");
  assert.equal(dark["--md-table-header-background"], "#151B23");
  assert.equal(light["--md-font-code"], '"Consolas", "IBM Plex Mono", Consolas, monospace');
  assert.equal(light["--md-font-body"], '"Pretendard", "Malgun Gothic", sans-serif');
  assert.equal(light["--md-width"], "1216px");
  assert.equal(light["--md-line-height"], "1.62");
  assert.equal(themeIds.length, 8);
  for (const id of themeIds) assert.equal(Object.keys(palettes[id]).length, 22, id);
});

test("짧은 마크다운 → HTML — 문서의 HTML은 글로, 코드 안의 * 는 꾸밈이 아니다", () => {
  assert.equal(escapeHtml(`<a href="x">&'`), "&lt;a href=&quot;x&quot;&gt;&amp;&#39;");
  assert.equal(inlineHtml("**굵게** *기울임* ~~줄~~ `a*b*c`"), "<strong>굵게</strong> <em>기울임</em> <del>줄</del> <code>a*b*c</code>");
  assert.equal(inlineHtml("<script>x</script>"), "&lt;script&gt;x&lt;/script&gt;");
  assert.equal(inlineHtml("[마디](https://a.b?x=1&y=2)"), '<a class="cm-md-link" data-url="https://a.b?x=1&amp;y=2">마디</a>');
  assert.equal(inlineHtml("a \\| b"), "a | b");
});

const doc = [
  "---", "title: 글", "---", "",
  "| a | b |", "|---|:-:|", "| 1 | 2 |", "",
  "```mermaid", "graph TD; A-->B", "```", "",
  "```math", "x^2", "```", "",
  "$$", "\\int_0^1 x\\,dx", "$$", "",
  "$$ e^{i\\pi} $$", "",
  "![그림](그림/a.png \"제목\")", "",
  "```swift", "let a = 1", "```", "",
  "$$", "", "짝 없는 $$", "",
  "- | 목록 안 | 표 |", "",
].join("\n");

test("그림으로 바꿀 블록 — 앞머리 · 표 · 다이어그램 · 수식(펜스 · $$ · 한 줄) · 그림", () => {
  const blocks = renderedBlocks(stateOf(doc));
  assert.deepEqual(blocks.map((block) => block.kind), ["frontmatter", "table", "mermaid", "math", "math", "math", "image"]);
  const lines = blocks.map((block) => [block.firstLine, block.lastLine]);
  assert.deepEqual(lines, [[1, 3], [5, 7], [9, 11], [13, 15], [17, 19], [21, 21], [23, 23]]);
  const sources = blocks.flatMap((block) => ("source" in block ? [block.source] : []));
  assert.deepEqual(sources, ["graph TD; A-->B", "x^2", "\\int_0^1 x\\,dx", "e^{i\\pi}"]);
  const image = blocks.find((block) => block.kind === "image");
  assert.ok(image && image.kind === "image" && image.src === "그림/a.png" && image.alt === "그림");
  const state = stateOf(doc);
  assert.equal(state.sliceDoc(blocks[0]!.from, blocks[0]!.to), "---\ntitle: 글\n---");
});

test("할 일 상자 · 알림 제목", () => {
  assert.deepEqual(taskToggle("[ ]", 10), { from: 11, to: 12, insert: "x" });
  assert.deepEqual(taskToggle("[X]", 10), { from: 11, to: 12, insert: " " });
  assert.equal(taskToggle("[?]", 0), null);
  assert.equal(alertKind("[!NOTE]"), "note");
  assert.equal(alertKind(" \\[!warning\\] "), "warning");
  assert.equal(alertKind("[!NOTE] 뒤에 글"), null);
  const text = "- [ ] 할 일\n- [x] 끝냄\n\n> [!TIP]\n> 알림 글\n\n끝";
  const state = stateOf(text);
  const marks = previewMarks(state, [{ from: 0, to: text.length }], caretLines(state));
  assert.deepEqual(marks.filter((mark) => mark.type === "task").map((mark) => (mark.type === "task" ? mark.checked : null)), [false, true]);
  assert.equal(marks.filter((mark) => mark.type === "bullet").length, 0, "할 일의 글머리는 상자로 대신한다");
  assert.ok(marks.some((mark) => mark.type === "inline" && mark.style === "done"), "끝낸 일은 흐리게");
  const hidden = marks.filter((mark) => mark.type === "hide").map((mark) => state.sliceDoc(mark.from, mark.to));
  assert.ok(hidden.includes("- "), "할 일의 글머리를 숨긴다");
  assert.ok(marks.some((mark) => mark.type === "alertTitle" && mark.kind === "tip"));
  assert.equal(marks.filter((mark) => mark.type === "line" && mark.style === "alert-tip").length, 2);
});

test("그림 경로 — 원격은 https만, 로컬은 꺾쇠 · 조각 · 질의 · 퍼센트 인코딩을 푼다", () => {
  assert.deepEqual(imageSource("https://example.com/a.png"), { kind: "remote", url: "https://example.com/a.png" });
  assert.equal(imageSource("http://example.com/a.png"), null, "평문은 켜도 받지 않는다");
  for (const raw of ["//cdn/a.png", "data:image/png;base64,AA", "javascript:alert(1)", "ftp://x/a.png", "", "   ", "#only"]) {
    assert.equal(imageSource(raw), null, raw);
  }
  assert.deepEqual(imageSource("<그림/내 그림.png>"), { kind: "local", path: "그림/내 그림.png" });
  assert.deepEqual(imageSource("my%20image.png?v=2#top"), { kind: "local", path: "my image.png" });
  assert.deepEqual(imageSource("100%.png"), { kind: "local", path: "100%.png" }, "풀 수 없는 %는 그대로");
  assert.deepEqual(imageSource("C:\\그림\\a.png"), { kind: "local", path: "C:\\그림\\a.png" });
  assert.deepEqual(imageSource("file:///C:/a%20b.png"), { kind: "local", path: "file:///C:/a%20b.png" }, "file: 주소는 껍데기가 푼다");
});

test("명령 목록 — 설정에 ✓, 설정 명령은 값을 바꾸고 범위를 지킨다", () => {
  const context = { settings: { ...defaultSettings, theme: "paper" as const }, source: true, follow: false, outline: false };
  const entries = catalog(context);
  assert.deepEqual(entries.filter((entry) => entry.id === "setTheme" && entry.checked).map((entry) => entry.title), ["종이"]);
  assert.equal(entries.find((entry) => entry.id === "toggleSource")?.checked, true);
  assert.equal(new Set(entries.map((entry) => `${entry.id}:${entry.arg ?? ""}`)).size, entries.length, "같은 명령이 둘 없다");
  assert.equal(fuzzyRank(entries, "githb", (entry) => ({ title: entry.title, detail: entry.menu }))[0]?.title, "GitHub");
  const big = { ...defaultSettings, bodySize: 28 };
  assert.equal(settingsChange(big, "textBigger")?.bodySize, 28, "28에서 멈춘다");
  assert.equal(settingsChange({ ...defaultSettings, bodySize: 10 }, "textSmaller")?.bodySize, 10);
  assert.equal(settingsChange(big, "textStandard")?.bodySize, 15);
  assert.equal(settingsChange(defaultSettings, "setTheme", "없는 테마")?.theme, "standard", "모르는 값은 그대로");
  assert.equal(settingsChange(defaultSettings, "setAppearance", "dark")?.appearance, "dark");
  assert.equal(settingsChange(defaultSettings, "setBodyFont", "  ")?.bodyFont, null);
  assert.equal(settingsChange(defaultSettings, "setCodeFont", "Cascadia Mono")?.codeFont, "Cascadia Mono");
  assert.equal(settingsChange(defaultSettings, "toggleRemoteImages")?.loadsRemoteImages, true);
  assert.equal(settingsChange(defaultSettings, "save"), null, "설정 명령이 아니다");
});

test("블록 장식 — 캐럿이 닿은 블록만 원문, 앞머리 접기는 설정을 따르고 머리 줄로 바뀐다", async () => {
  const { blockEnv, renderedBlockField, setFrontMatterCollapsed } = await import("../src/editor/blocks.ts");
  const env = { dark: false, loadsRemoteImages: false, collapsesFrontMatter: true };
  const make = (caret: number) => {
    const state = EditorState.create({
      doc, selection: EditorSelection.cursor(caret),
      extensions: [markdown({ base: markdownLanguage }), blockEnv.of(env), renderedBlockField],
    });
    ensureSyntaxTree(state, doc.length, 5000);
    // 트리가 다 읽힌 뒤의 상태 — 빈 바꿈 하나로 필드를 다시 계산하게 한다.
    return state.update({}).state;
  };
  const widgets = (state: EditorState) => {
    const found: { from: number; to: number; name: string }[] = [];
    state.field(renderedBlockField).decorations.between(0, state.doc.length, (from, to, value) => {
      found.push({ from, to, name: (value.spec.widget as object).constructor.name });
    });
    return found;
  };
  const atEnd = make(doc.length);
  assert.deepEqual(widgets(atEnd).map((widget) => widget.name),
    ["FrontMatterWidget", "TableWidget", "DiagramWidget", "DiagramWidget", "DiagramWidget", "DiagramWidget", "ImageWidget"]);
  assert.equal(atEnd.field(renderedBlockField).collapsed, true, "설정이 접기면 접어서 연다");
  const table = renderedBlocks(atEnd)[1]!;
  const inTable = atEnd.update({ selection: EditorSelection.cursor(table.to) }).state;
  assert.equal(widgets(inTable).length, 6, "캐럿이 표의 끝 줄 끝에 있어도 표는 원문");
  assert.ok(!widgets(inTable).some((widget) => widget.from === table.from));
  const below = atEnd.update({ selection: EditorSelection.cursor(table.to + 1) }).state;
  assert.equal(widgets(below).length, 7, "다음 줄로 나가면 다시 그림");
  const opened = atEnd.update({ effects: setFrontMatterCollapsed.of(false) }).state;
  assert.equal(opened.field(renderedBlockField).collapsed, false);
  const typed = opened.update({ changes: { from: doc.length, insert: "x" } }).state;
  assert.equal(typed.field(renderedBlockField).collapsed, false, "사람이 편 것은 고쳐도 남는다");
});
