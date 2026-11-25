// 편집기의 보기 — 원본 보기 · 따라 보기 · 파일 종류에 따라 바뀌는 확장들(Compartment)과 겉모양(테마).

import { Compartment, EditorState, type Extension, type StateEffect } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { tags as t } from "@lezer/highlight";
import type { FileKind } from "../core/kind.ts";
import type { LineSeparator } from "../core/lines.ts";
import { livePreview } from "./preview.ts";
import { blockEnv, renderedBlockField, type BlockEnv } from "./blocks.ts";
import { codeLanguageFor } from "./codelang.ts";

export interface Mode {
  kind: FileKind;
  /** 원본 보기(Ctrl+E) — 쓴 그대로, 고정폭. 글 파일은 이것으로 연다. */
  source: boolean;
  /** 따라 보기(Ctrl+Alt+L) — 고칠 수 없게, 끝을 따라간다. 로그는 이것으로 연다. */
  follow: boolean;
  separator: LineSeparator;
}

const separator = new Compartment();
const language = new Compartment();
const preview = new Compartment();
const readOnly = new Compartment();
const classes = new Compartment();
/** 설정에서 오는 것 — 다크(CodeMirror의 기본 색 · Mermaid 테마), 원격 그림, 앞머리 접기. */
const environment = new Compartment();

export function environmentExtension(env: BlockEnv): Extension {
  return [blockEnv.of(env), EditorView.darkTheme.of(env.dark)];
}

export function reconfigureEnvironment(env: BlockEnv): StateEffect<unknown> {
  return environment.reconfigure(environmentExtension(env));
}

/** 글 파일을 쓴 그대로 볼 때는 창 폭을 다 쓴다(macOS판 `fitsTextToWindow`). 마크다운은 읽기 좋은 폭에서 멈춘다. */
export function fitsWindow(mode: Mode): boolean {
  return mode.kind !== "markdown" && mode.source;
}

function parts(mode: Mode) {
  // 글 파일을 원본 보기로 보면 마크다운 문법을 칠하지 않는다 — 로그의 `# `는 표식이 아니라 내용이다.
  const usesMarkdown = mode.kind === "markdown" || !mode.source;
  return {
    separator: EditorState.lineSeparator.of(mode.separator),
    // 코드 블록 안은 그 언어로 다시 읽는다(문법 색 — 꾸러미는 처음 보일 때 싣는다).
    language: usesMarkdown ? markdown({ base: markdownLanguage, codeLanguages: codeLanguageFor }) : [],
    // 블록 그림(표 · 다이어그램 · 수식 · 그림 · 앞머리)도 라이브 프리뷰의 일이다 — 원본 보기에서는 쓴 그대로.
    preview: mode.source ? [] : [livePreview, renderedBlockField],
    readOnly: [EditorState.readOnly.of(mode.follow), EditorView.editable.of(!mode.follow)],
    classes: EditorView.editorAttributes.of({
      class: [mode.source ? "md-source" : "", fitsWindow(mode) ? "md-wide" : "", mode.follow ? "md-follow" : ""]
        .filter(Boolean).join(" "),
    }),
  };
}

export function modeExtensions(mode: Mode, env: BlockEnv): Extension[] {
  const p = parts(mode);
  return [
    environment.of(environmentExtension(env)),
    separator.of(p.separator),
    language.of(p.language),
    preview.of(p.preview),
    readOnly.of(p.readOnly),
    classes.of(p.classes),
  ];
}

export function reconfigure(mode: Mode): StateEffect<unknown>[] {
  const p = parts(mode);
  return [
    language.reconfigure(p.language),
    preview.reconfigure(p.preview),
    readOnly.reconfigure(p.readOnly),
    classes.reconfigure(p.classes),
  ];
}

// 글꼴 · 글 폭 · 꾸밈. style.css에 적으면 CodeMirror의 기본 테마(클래스 둘)에 밀린다 — 0단계에서 그랬다. 테마의 규칙은 클래스가 하나 더 붙는다.
// 색 · 글꼴 · 크기 · 줄 높이 · 글 폭은 모두 설정의 CSS 변수(`theme.ts`)다. 글 폭은 macOS판과 같다: 본문 크기의 배수(보통 56배),
// 창이 넓으면 남는 자리를 양옆에 반씩. 제목 크기도 macOS판의 배율.
const v = (name: string) => `var(--md-${name})`;
const tint = `color-mix(in srgb, ${v("text")} 6%, ${v("background")})`;

/** 같은 꼴의 줄이 이어진 덩이의 첫 줄 · 끝 줄 — 코드 블록 · 알림을 한 장의 둥근 상자로 그린다(줄마다 칠하므로 CSS로 끝을 찾는다). */
const firstOf = (line: string) => `${line}:not(${line} + ${line})`;
const lastOf = (line: string) => `${line}:not(:has(+ ${line}))`;

function alertLines(): Record<string, Record<string, string>> {
  const styles: Record<string, Record<string, string>> = {};
  for (const kind of ["note", "tip", "important", "warning", "caution"]) {
    const line = `.cm-md-line-alert-${kind}`;
    styles[line] = {
      borderLeft: `3px solid ${v(kind)}`,
      padding: "0 16px 0 16px",
      background: `color-mix(in srgb, ${v(kind)} 7%, transparent)`,
    };
    styles[firstOf(line)] = { borderTopLeftRadius: "4px", borderTopRightRadius: "8px", paddingTop: "8px" };
    styles[lastOf(line)] = { borderBottomLeftRadius: "4px", borderBottomRightRadius: "8px", paddingBottom: "8px" };
    styles[`.cm-md-alert-${kind}`] = { color: v(kind) };
  }
  return styles;
}

/**
 * 겉모양 — 문서처럼 읽히게(사용자 — "디자인이 별로인데… loomm.ai/mark 이거 느낌"). 넉넉한 여백과 큰 제목, 둥근 코드 블록 · 표 · 알림,
 * 조용한 할 일 상자와 인용 막대. macOS판(`docs/images/live-preview.png`)과 같은 방향이다.
 */
export const look = EditorView.theme({
  "&": { height: "100%", background: v("background"), color: v("text") },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": {
    fontFamily: v("font-body"), fontSize: v("size"), lineHeight: v("line-height"), textRendering: "optimizeLegibility",
  },
  ".cm-content": { padding: `40px max(56px, calc((100% - ${v("width")}) / 2)) 35vh`, caretColor: v("text") },
  ".cm-line": { padding: "0 2px" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: v("text"), borderLeftWidth: "1.5px" },
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, & > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-content ::selection":
    { backgroundColor: v("selection") },
  ".cm-placeholder": { color: v("dim") },
  "&.md-wide .cm-content": { padding: "20px 32px 35vh" },
  "&.md-source .cm-scroller": { fontFamily: v("font-code"), fontSize: `calc(${v("size")} - 1px)` },
  // 제목 — 크게, 자간을 조금 좁혀서. 위 여백이 단락을 나눈다(빈 줄 하나 위에 더).
  ".cm-md-line-h1": { fontSize: "2em", fontWeight: "700", lineHeight: "1.25", letterSpacing: "-0.022em", padding: "0.5em 2px 0.1em" },
  ".cm-md-line-h2": { fontSize: "1.5em", fontWeight: "700", lineHeight: "1.3", letterSpacing: "-0.016em", padding: "0.75em 2px 0.05em" },
  ".cm-md-line-h3": { fontSize: "1.25em", fontWeight: "700", lineHeight: "1.35", letterSpacing: "-0.01em", padding: "0.5em 2px 0" },
  ".cm-md-line-h4": { fontSize: "1.08em", fontWeight: "700", padding: "0.3em 2px 0" },
  ".cm-md-line-h5, .cm-md-line-h6": { fontWeight: "700" },
  ".cm-md-strong": { fontWeight: "700" },
  ".cm-md-emphasis": { fontStyle: "italic" },
  ".cm-md-strike": { textDecoration: "line-through" },
  ".cm-md-done": { color: v("dim"), textDecoration: "line-through", textDecorationColor: `color-mix(in srgb, ${v("dim")} 60%, transparent)` },
  ".cm-md-code": {
    fontFamily: v("font-code"), fontSize: "0.86em", color: v("code-text"), background: v("code-background"),
    borderRadius: "5px", padding: "0.12em 0.38em",
  },
  ".cm-md-link": {
    color: v("link"), textDecoration: "underline", textUnderlineOffset: "3px", textDecorationThickness: "1px",
    textDecorationColor: `color-mix(in srgb, ${v("link")} 45%, transparent)`,
  },
  // 인용 — 둥근 끝의 굵은 막대, 글은 조금 흐리게.
  ".cm-md-line-quote": { borderLeft: `4px solid ${v("quote-bar")}`, paddingLeft: "18px", color: v("quote") },
  [firstOf(".cm-md-line-quote")]: { borderTopLeftRadius: "3px" },
  [lastOf(".cm-md-line-quote")]: { borderBottomLeftRadius: "3px" },
  ".cm-md-alert-title": { fontWeight: "700" },
  ...alertLines(),
  // 코드 블록 — 한 장의 둥근 상자. 울타리 줄(```)은 블록 밖에 캐럿이 있으면 숨고 언어 이름만 작게 남는다.
  ".cm-md-line-code": {
    fontFamily: v("font-code"), fontSize: `calc(${v("size")} - 1.5px)`, lineHeight: "1.6", color: v("code-text"),
    background: v("code-background"), padding: "0 18px",
  },
  [firstOf(".cm-md-line-code")]: { borderTopLeftRadius: "10px", borderTopRightRadius: "10px", paddingTop: "10px" },
  [lastOf(".cm-md-line-code")]: { borderBottomLeftRadius: "10px", borderBottomRightRadius: "10px", paddingBottom: "10px" },
  ".cm-md-line-fence": { color: v("dim"), fontSize: `calc(${v("size")} - 3px)`, letterSpacing: "0.02em" },
  ".cm-md-bullet": { display: "inline-block", minWidth: "0.9em", fontSize: "0.5em", verticalAlign: "0.3em", color: v("text") },
  ".cm-md-rule": { display: "inline-block", width: "100%", borderTop: `1px solid ${v("rule")}`, verticalAlign: "middle" },
  // 할 일 — 조용한 둥근 상자. 끝낸 일은 회색 체크(글은 흐리게 긋는다 — macOS판과 같은 규칙).
  ".cm-md-task": {
    display: "inline-flex", alignItems: "center", justifyContent: "center", boxSizing: "border-box",
    width: "1.1em", height: "1.1em", marginRight: "0.5em", verticalAlign: "-0.18em", cursor: "pointer",
    border: `1.5px solid color-mix(in srgb, ${v("text")} 32%, ${v("background")})`, borderRadius: "4px",
    fontSize: "0.85em", lineHeight: "1", userSelect: "none", color: v("dim"), transition: "background 120ms, border-color 120ms",
  },
  ".cm-md-task:hover": { borderColor: v("dim") },
  ".cm-md-task-done": { background: tint, borderColor: `color-mix(in srgb, ${v("text")} 24%, ${v("background")})`, fontWeight: "700" },
  // 찾기 칸 — 둥근 입력 칸 · 단추.
  ".cm-panels": { background: v("background"), color: v("text"), fontFamily: v("font-body") },
  ".cm-panels-top": { borderBottom: `1px solid ${v("rule")}` },
  ".cm-search": { padding: "8px 44px 10px 16px", fontSize: "13px", display: "flex", flexWrap: "wrap", alignItems: "center", gap: "6px 8px" },
  ".cm-search br": { display: "none" },
  ".cm-search input.cm-textfield": {
    font: `13px ${v("font-body")}`, border: `1px solid ${v("rule")}`, borderRadius: "6px", padding: "5px 9px", margin: "0",
    background: tint, color: v("text"), outline: "none", minWidth: "220px",
  },
  ".cm-search input.cm-textfield:focus": { borderColor: v("link"), background: v("background") },
  ".cm-search .cm-button": {
    backgroundImage: "none", background: "transparent", border: `1px solid ${v("rule")}`, borderRadius: "6px",
    padding: "4px 10px", margin: "0", color: v("text"), font: `12.5px ${v("font-body")}`, cursor: "pointer",
  },
  ".cm-search .cm-button:hover": { background: tint },
  ".cm-search label": { color: v("dim"), fontSize: "12.5px", display: "inline-flex", alignItems: "center", gap: "4px", margin: "0" },
  ".cm-search button[name=close]": { fontSize: "20px", color: v("dim"), top: "8px", right: "14px", padding: "0 4px", borderRadius: "6px" },
  ".cm-searchMatch": { backgroundColor: `color-mix(in srgb, ${v("warning")} 28%, transparent)`, borderRadius: "2px" },
  ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: `color-mix(in srgb, ${v("warning")} 55%, transparent)` },
});

/**
 * 문법 색 — 테마의 색(코드 블록의 낱말 · 형 · 문자열 · 주석 · 수). 제목에는 밑줄이 없다(macOS판처럼 — 1단계 CI 화면에서 기본 색의
 * 밑줄이 보였다). 마크다운의 표식(`#` `**` `>`)은 흐리게.
 */
export const highlighting = syntaxHighlighting(HighlightStyle.define([
  { tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.operatorKeyword, t.definitionKeyword, t.modifier], color: v("keyword") },
  { tag: [t.typeName, t.className, t.namespace, t.standard(t.name)], color: v("type") },
  { tag: [t.string, t.special(t.string), t.regexp, t.character], color: v("string") },
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: v("comment"), fontStyle: "italic" },
  { tag: [t.number, t.bool, t.null, t.atom], color: v("number") },
  { tag: [t.processingInstruction, t.meta, t.labelName], color: v("dim") },
  { tag: t.heading, fontWeight: "700" },
  { tag: t.url, color: v("link") },
  { tag: t.link, color: v("link") },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: t.quote, color: v("quote") },
  { tag: t.monospace, fontFamily: v("font-code") },
  { tag: t.invalid, color: v("caution") },
]));

/** CodeMirror 찾기 · 바꾸기 칸의 한국어. */
export const koreanPhrases = EditorState.phrases.of({
  "Find": "찾기",
  "Replace": "바꿀 말",
  "next": "다음",
  "previous": "이전",
  "all": "모두",
  "match case": "대소문자 구분",
  "regexp": "정규식",
  "by word": "낱말 단위",
  "replace": "바꾸기",
  "replace all": "모두 바꾸기",
  "close": "닫기",
  "current match": "지금 찾은 것",
  "replaced $ matches": "$개를 바꿨습니다",
  "replaced match on line $": "$번째 줄을 바꿨습니다",
  "on line": "줄",
  "Go to line": "줄로 가기",
  "go": "가기",
});
