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
    language: usesMarkdown ? markdown({ base: markdownLanguage }) : [],
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

function alertLines(): Record<string, Record<string, string>> {
  const styles: Record<string, Record<string, string>> = {};
  for (const kind of ["note", "tip", "important", "warning", "caution"]) {
    styles[`.cm-md-line-alert-${kind}`] = {
      borderLeft: `3px solid ${v(kind)}`,
      paddingLeft: "12px",
      background: `color-mix(in srgb, ${v(kind)} 7%, transparent)`,
    };
    styles[`.cm-md-alert-${kind}`] = { color: v(kind) };
  }
  return styles;
}

export const look = EditorView.theme({
  "&": { height: "100%", background: v("background"), color: v("text") },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: v("font-body"), fontSize: v("size"), lineHeight: v("line-height") },
  ".cm-content": { padding: `24px max(28px, calc((100% - ${v("width")}) / 2))`, caretColor: v("text") },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: v("text") },
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, & > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-content ::selection":
    { backgroundColor: v("selection") },
  ".cm-placeholder": { color: v("dim") },
  "&.md-wide .cm-content": { padding: "16px 28px" },
  "&.md-source .cm-scroller": { fontFamily: v("font-code"), fontSize: `calc(${v("size")} - 1px)` },
  ".cm-md-line-h1": { fontSize: "1.85em", fontWeight: "700", lineHeight: "1.3", paddingTop: "0.4em" },
  ".cm-md-line-h2": { fontSize: "1.45em", fontWeight: "700", lineHeight: "1.35", paddingTop: "0.3em" },
  ".cm-md-line-h3": { fontSize: "1.22em", fontWeight: "700" },
  ".cm-md-line-h4": { fontSize: "1.08em", fontWeight: "700" },
  ".cm-md-line-h5, .cm-md-line-h6": { fontWeight: "700" },
  ".cm-md-strong": { fontWeight: "700" },
  ".cm-md-emphasis": { fontStyle: "italic" },
  ".cm-md-strike": { textDecoration: "line-through" },
  ".cm-md-done": { color: v("dim"), textDecoration: "line-through" },
  ".cm-md-code": {
    fontFamily: v("font-code"), fontSize: "0.92em", color: v("code-text"), background: v("code-background"),
    borderRadius: "3px", padding: "0 2px",
  },
  ".cm-md-link": { color: v("link"), textDecoration: "underline", textUnderlineOffset: "2px" },
  ".cm-md-line-quote": { borderLeft: `3px solid ${v("quote-bar")}`, paddingLeft: "12px", color: v("quote") },
  ".cm-md-alert-title": { fontWeight: "700" },
  ...alertLines(),
  ".cm-md-line-code": { fontFamily: v("font-code"), fontSize: `calc(${v("size")} - 1px)`, color: v("code-text"), background: v("code-background") },
  ".cm-md-line-fence": { color: v("dim") },
  ".cm-md-bullet": { display: "inline-block", minWidth: "0.8em", fontSize: "0.7em", verticalAlign: "0.15em" },
  ".cm-md-rule": { display: "inline-block", width: "100%", borderTop: `1px solid ${v("rule")}`, verticalAlign: "middle" },
  ".cm-md-task": {
    display: "inline-flex", alignItems: "center", justifyContent: "center", boxSizing: "border-box",
    width: "1.05em", height: "1.05em", marginRight: "0.4em", verticalAlign: "-0.15em", cursor: "pointer",
    border: `1.5px solid ${v("dim")}`, borderRadius: "3px", fontSize: "0.8em", lineHeight: "1", userSelect: "none",
  },
  ".cm-md-task-done": { background: v("link"), borderColor: v("link"), color: v("background"), fontWeight: "700" },
  ".cm-panels": { background: v("background"), color: v("text") },
  ".cm-panels-top": { borderBottom: `1px solid ${tint}` },
  ".cm-searchMatch": { backgroundColor: `color-mix(in srgb, ${v("warning")} 30%, transparent)` },
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
